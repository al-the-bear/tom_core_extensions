// Worker-death + per-request deadline guard for cross-isolate
// request/response protocols.
//
// The problem this solves: a request/response isolate host (e.g. the
// brain-memory boundary) typically registers a host-side `Completer`
// for each outbound request and `await`s it until the matching
// response arrives. If the worker isolate *dies* (is killed, or
// crashes fatally) the response never arrives and the registered
// `Completer` is never completed — so the awaiting call hangs
// forever. A per-request deadline alone does not fix this cleanly
// either: it converts every death into a slow timeout, and forces a
// timeout to be configured even where one is unwanted.
//
// [IsolateRequestGuard] is the generic, transport-agnostic answer. It
// races each guarded request against two host-side signals:
//
//   * a one-shot worker-death signal ([markWorkerDead]) the host
//     raises from its isolate-exit listener — this fails *every*
//     in-flight guarded request immediately with
//     [IsolateRequestFailureReason.workerDeath]; and
//   * an optional per-request deadline — a hanging request fails with
//     [IsolateRequestFailureReason.timeout] once the deadline elapses.
//
// It is deliberately ignorant of the concrete message catalogue and
// of `dart:isolate`: the host owns the `Isolate` and feeds the guard
// the death signal; the guard owns only the race. That keeps it in
// `tom_core_agentic` (tom_basics-only) and reusable by any isolate
// adapter, not just brain-memory.

import 'dart:async';

import 'isolate_cancellation.dart' show IsolateCancellationToken;

/// Why a request crossing an isolate boundary could not complete.
enum IsolateRequestFailureReason {
  /// The worker isolate died (was killed, or crashed fatally) before
  /// the response arrived. Raised for *every* in-flight request the
  /// moment [IsolateRequestGuard.markWorkerDead] is called.
  workerDeath,

  /// The request exceeded its per-request deadline without the worker
  /// having died — the worker is presumed alive but unresponsive (or
  /// the work is simply taking longer than the caller allowed).
  timeout,
}

/// Typed failure raised in place of an indefinite hang when a guarded
/// isolate request cannot complete.
///
/// A host re-raises this to the caller directly (it is already a
/// boundary-level failure, not a wrapped domain exception). Consumers
/// switch on [reason] to distinguish a dead worker from a slow one.
final class IsolateRequestFailure implements Exception {
  /// The boundary failure mode.
  final IsolateRequestFailureReason reason;

  /// Human-readable diagnostic naming the operation and the cause.
  final String message;

  const IsolateRequestFailure(this.reason, this.message);

  @override
  String toString() => 'IsolateRequestFailure(${reason.name}): $message';
}

/// Bounds each request crossing an isolate boundary so it fails with a
/// typed [IsolateRequestFailure] instead of hanging forever.
///
/// One guard per isolate host. The host:
///
///   1. constructs the guard, optionally with a [defaultTimeout];
///   2. wires its `Isolate`'s exit listener to call [markWorkerDead];
///   3. wraps every outbound request future in [guard].
///
/// The guard is purely host-side state — it never crosses the
/// boundary. It does not (and cannot) unblock the underlying
/// `Completer` the kernel worker leaks on a dead isolate; it bounds
/// the *caller's* await so the host stays responsive.
///
/// **A timeout can cancel what it abandons.** Without help, a timed-out
/// request keeps running on the worker and its eventual result is dropped —
/// the worker does the whole of the work for no one, at the moment it is
/// already too loaded to answer in time. So [guard] takes an optional
/// [IsolateCancellationToken] and a `cancel` callback: on a timeout it calls
/// `cancel(token)`, and the host sends the cancel envelope of its own
/// protocol. The guard stays transport-agnostic — it owns no port and knows
/// no message catalogue — and an adapter with no cancellation protocol passes
/// neither and is unaffected. A worker *death* never calls `cancel`: there is
/// nobody left to receive it.
///
/// `final` because the guard is varied by *configuration*, not by
/// subtyping: [defaultTimeout] and [guard]'s per-call `timeout` are the
/// designed adjustment points, and the death signal arrives through
/// [markWorkerDead] rather than through an overridable hook. A subclass
/// would have nothing to override that is not already a parameter.
final class IsolateRequestGuard {
  /// Default per-request deadline applied when [guard] is called
  /// without an explicit `timeout`. `null` (the default) means no
  /// deadline — worker-death protection still applies, but a request
  /// to a live-but-slow worker waits indefinitely.
  final Duration? defaultTimeout;

  bool _workerDead = false;
  String? _deathDetail;
  final Set<_GuardEntry> _pending = <_GuardEntry>{};

  IsolateRequestGuard({this.defaultTimeout});

  /// Whether the worker has been declared dead. Once `true`, every
  /// subsequent [guard] call fails fast with [IsolateRequestFailureReason.workerDeath].
  bool get isWorkerDead => _workerDead;

  /// Number of currently in-flight guarded requests. Visible for
  /// tests and operational introspection.
  int get inFlightCount => _pending.length;

  /// Declares the worker dead, failing every in-flight guarded request
  /// now and every future guarded request immediately.
  ///
  /// Called by the host from its isolate-exit / error listener.
  /// Idempotent — the first call wins and records [detail]; later
  /// calls are no-ops.
  ///
  /// **Terminal.** There is no revive: once a guard has been told its worker
  /// died it fails every future request for the rest of its life. A host that
  /// respawns its worker builds a new guard, which is the honest arrangement —
  /// the requests in flight at the death are gone either way, and a guard that
  /// could be reset would have to decide what it owed them.
  void markWorkerDead([String? detail]) {
    if (_workerDead) return;
    _workerDead = true;
    _deathDetail = detail;
    // Iterate a snapshot: each failed entry removes itself from
    // `_pending` asynchronously via its `whenComplete` cleanup.
    for (final entry in _pending.toList()) {
      entry.fail(
        IsolateRequestFailure(
          IsolateRequestFailureReason.workerDeath,
          _deathMessage(entry.label),
        ),
      );
    }
  }

  /// Wraps [request] so it completes with a typed [IsolateRequestFailure]
  /// instead of hanging when the worker dies or the deadline elapses.
  ///
  /// [timeout] overrides [defaultTimeout] for this call (pass it when a
  /// specific request needs a tighter or looser bound). [operation]
  /// names the request in failure messages (e.g. the envelope's
  /// runtime type).
  ///
  /// The request's own errors propagate unchanged — the guard only
  /// injects the two boundary failures, it never rewrites a domain
  /// exception the worker legitimately returned.
  ///
  /// [cancellation] and [cancel] come together or not at all. When the
  /// deadline elapses first, the caller's future fails with the timeout and
  /// then `cancel(cancellation)` is called, once, so the host can tell the
  /// worker to stop the work nobody is waiting for any more. It is not
  /// called when the request completes first or the worker dies. An error
  /// thrown by `cancel` is not the caller's — it has already been answered —
  /// and goes to the current zone's error handler.
  Future<T> guard<T>(
    Future<T> request, {
    Duration? timeout,
    String? operation,
    IsolateCancellationToken? cancellation,
    void Function(IsolateCancellationToken token)? cancel,
  }) {
    if ((cancellation == null) != (cancel == null)) {
      // A programmer error: a token with nothing to
      // send it, or a callback with nothing to send.
      throw ArgumentError(
        'IsolateRequestGuard.guard: cancellation and cancel must be given '
        'together — a token with no way to send it cancels nothing, and a '
        'callback with no token has nothing to cancel.',
      );
    }
    final label = operation ?? 'isolate request';
    if (_workerDead) {
      return Future<T>.error(
        IsolateRequestFailure(
          IsolateRequestFailureReason.workerDeath,
          _deathMessage(label),
        ),
      );
    }

    final completer = Completer<T>();
    Timer? timer;
    final entry = _GuardEntry(label, (failure) {
      if (!completer.isCompleted) completer.completeError(failure);
    });
    _pending.add(entry);

    final effective = timeout ?? defaultTimeout;
    if (effective != null) {
      timer = Timer(effective, () {
        if (!completer.isCompleted) {
          completer.completeError(
            IsolateRequestFailure(
              IsolateRequestFailureReason.timeout,
              '$label exceeded its ${effective.inMilliseconds}ms deadline',
            ),
          );
          if (cancel != null) cancel(cancellation!);
        }
      });
    }

    // The result is forwarded into `completer`; the `then` future
    // itself is intentionally not awaited (the race is owned by
    // `completer`).
    unawaited(
      request.then(
        (value) {
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      ),
    );

    return completer.future.whenComplete(() {
      timer?.cancel();
      _pending.remove(entry);
    });
  }

  String _deathMessage(String label) => _deathDetail == null
      ? '$label failed: worker isolate is no longer alive'
      : '$label failed: worker isolate is no longer alive ($_deathDetail)';
}

/// Per-request bookkeeping entry: its operation label and a closure
/// that fails the (typed) host-side completer with a boundary failure.
///
/// The closure captures the request's `Completer<T>` so the guard's
/// untyped `Set<_GuardEntry>` can fail any request without itself
/// being generic.
///
/// Carries no class modifier, unlike the public types in this module. A
/// modifier restricts subtyping from *outside* the declaring library, and a
/// private class is not visible there — `final` here would read as a decision
/// while permitting exactly what its absence permits.
class _GuardEntry {
  final String label;
  final void Function(IsolateRequestFailure failure) fail;

  _GuardEntry(this.label, this.fail);
}

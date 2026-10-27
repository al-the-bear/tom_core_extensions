// Cancellation family for cross-isolate streaming protocols.
//
// This is the generic, transport-agnostic core of the cancellation
// protocol used by isolate adapters (e.g. the brain-memory isolate
// boundary). It carries no knowledge of any concrete message catalogue:
// the request/response *envelopes* that ferry a token across the
// boundary belong to the adapter that owns the message protocol; this
// module only owns the token, its allocator, the in-isolate registry,
// the per-request handle, and the typed cancellation exception.
//
// Why an `Isolate`-prefixed family (and not the cooperative
// `TomCancellationToken` from `tom_basics`):
//
//   The cooperative `TomCancellationToken` is a *behavioural* token —
//   consumers `await whenCancelled` and check `isCancelled` to abort
//   in-process work. This family is a *protocol* token: an opaque,
//   sendable integer id that names a cancellable request crossing an
//   isolate boundary. The state lives in an in-isolate
//   `IsolateCancellationRegistry`; the token itself carries no state.
//   An adapter holds both: it takes the caller's `TomCancellationToken`
//   and, when that fires, sends a cancel envelope for its own
//   `IsolateCancellationToken`. The protocol family is named distinctly
//   to keep call sites unambiguous.
//
// Sendability:
//
//   [IsolateCancellationToken] is a single-integer value type, so it
//   crosses isolate boundaries trivially. The registry and handle live
//   only inside the executor's isolate; they never cross.
//
// Lifecycle:
//
//   1. The host allocates a token
//      ([IsolateCancellationTokenAllocator.next]) and includes it in a
//      cancellable request envelope owned by the adapter.
//   2. The in-isolate executor registers the token
//      ([IsolateCancellationRegistry.register]) before invoking the
//      cancellable operation.
//   3. If a cancel envelope arrives, the executor flips the registry's
//      cancelled-flag for that token ([IsolateCancellationRegistry.cancel]).
//   4. The executor checks the flag at well-defined checkpoints
//      (pre-call, between stream chunks, post-call); on cancellation it
//      raises [IsolateCancellationException].
//   5. The executor disposes the handle after the response is sent.
//
// Cancellation can be observed before, during, or after the call, up to
// the point the handle is disposed — the registry honours whichever
// order it sees within that window (see the late-cancel note on
// [IsolateCancellationRegistry]).

import 'dart:async';

/// Opaque identifier for a cancellable request, sendable across an
/// isolate boundary.
///
/// Allocated by the host ([IsolateCancellationTokenAllocator]) and
/// included in the request envelope. The in-isolate
/// [IsolateCancellationRegistry] keys off the integer value; tokens are
/// unique per host instance and not recycled within a host lifetime.
///
/// The token is `int`-shaped (boxed) rather than a raw `int` so that
/// signatures stay readable (`recall(query, cancellation: token)` vs.
/// `recall(query, cancellation: 42)`) and so the host-side allocator
/// has a typed return value.
final class IsolateCancellationToken {
  /// Monotonic integer assigned by the host.
  final int id;

  const IsolateCancellationToken(this.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IsolateCancellationToken && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'IsolateCancellationToken($id)';
}

/// Host-side counter that hands out unique [IsolateCancellationToken]s.
///
/// One allocator per isolate host. Not thread-safe in the cross-isolate
/// sense (the allocator lives on the host side; each allocation is on
/// the host's isolate which is single-threaded by definition).
final class IsolateCancellationTokenAllocator {
  int _next = 1;

  /// Returns a fresh [IsolateCancellationToken] and advances the counter.
  IsolateCancellationToken next() => IsolateCancellationToken(_next++);

  /// Visible for tests — returns the next id without advancing.
  int get peekNext => _next;
}

/// In-isolate registry of cancellation state per token.
///
/// One registry per executor. Tokens are registered on envelope arrival,
/// the cancelled-flag is flipped on cancel-envelope arrival, and the
/// token is unregistered when the response is sent. Unknown tokens
/// (`register` not called, or already unregistered) are silently no-op
/// for `cancel(token)` — the protocol allows the cancel to arrive
/// *before* the open envelope or *after* the close, and we treat both as
/// benign (the future request will see the cancel; a past request had
/// nothing to cancel anyway).
///
/// **Late-cancel semantics**: when a `cancel(token)` arrives for a token
/// that has not yet been registered, the registry remembers the
/// cancellation in `_pendingCancellations` so the subsequent
/// `register(token)` sees the flag already raised. This handles the
/// natural race where the host sends a cancel immediately after the open
/// envelope, but the cancel arrives first because the open envelope is
/// still mid-dispatch.
///
/// **Pre-open vs. post-close discriminator**: an unknown-token
/// `cancel` is ambiguous — it is either a *pre-open* cancel (the open
/// envelope is still in flight) that must be remembered, or a *post-close*
/// cancel (the request already registered, disposed, and unregistered)
/// that must be dropped. Remembering the latter leaks: ids are never
/// recycled, so a post-close cancel would sit in `_pendingCancellations`
/// forever, never consumed by any future `register`. The two cases are
/// distinguished by a monotonic high-water mark [_highestSeenId]: tokens
/// are allocated with strictly increasing ids by a single host allocator,
/// and the ordered host→executor transport delivers open envelopes in id
/// order, so every id that has *ever* been registered is `<=` the highest
/// seen. An unknown-token cancel whose id is `<= _highestSeenId` therefore
/// belongs to a request that already passed through the registry (now
/// closed) and is dropped; an id `> _highestSeenId` is a genuine pre-open
/// cancel and is remembered. This keeps `_pendingCancellations` bounded by
/// the number of genuinely in-flight-but-unopened requests.
///
/// That precondition is **asserted** in [register], because breaking it is
/// silent: a genuine pre-open cancel for an id below the mark is read as
/// post-close and dropped, so the request runs to completion having been
/// cancelled and nothing reports it. The assert fires at the out-of-order
/// `register` — the first moment the violation is observable from inside the
/// registry — and names both ways to cause it.
final class IsolateCancellationRegistry {
  final Map<int, _RegistryEntry> _entries = <int, _RegistryEntry>{};
  final Set<int> _pendingCancellations = <int>{};

  /// Highest token id ever registered. Drives the pre-open vs. post-close
  /// discriminator for unknown-token cancels.
  int _highestSeenId = 0;

  /// Registers [token] as in-flight. The returned [IsolateCancellationHandle]
  /// is the handle the executor uses to read [IsolateCancellationHandle.isCancelled]
  /// and to complete the registration.
  ///
  /// If the token has a pending cancel (a cancel arrived before
  /// `register`), the returned handle is already cancelled.
  IsolateCancellationHandle register(IsolateCancellationToken token) {
    // The precondition the discriminator above rests on, checked at the one
    // moment it becomes observable. Ids arrive strictly increasing when — and
    // only when — a single host allocator issues them and the transport
    // delivers open envelopes in order. Break either half and a *genuine*
    // pre-open cancel for a low id is read as a post-close one and dropped:
    // the request then runs to completion having been cancelled, and nothing
    // anywhere reports it. That silence is why this is an assert rather than a
    // comment.
    //
    // An `assert` rather than a throw because the violation is a protocol
    // error in the adapter, not a condition this module can recover from, and
    // because the worst case in production is one cancel ignored — which does
    // not warrant taking a worker isolate down. It fails loudly everywhere a
    // test or a debug build runs, which is where an adapter is written.
    assert(
      token.id > _highestSeenId,
      'IsolateCancellationRegistry.register(${token.id}) after id '
      '$_highestSeenId: token ids must arrive strictly increasing. Either two '
      'allocators are issuing ids into one registry, or the host→executor '
      'transport reordered the open envelopes. Until that is fixed, a pre-open '
      'cancel for an id below the high-water mark is dropped as though the '
      'request had already closed.',
    );
    if (token.id > _highestSeenId) _highestSeenId = token.id;
    final wasPending = _pendingCancellations.remove(token.id);
    final entry = _RegistryEntry(cancelled: wasPending);
    _entries[token.id] = entry;
    return IsolateCancellationHandle._(token, entry, this);
  }

  /// Flips the cancelled-flag for [token].
  ///
  /// If the token is registered, its flag is raised immediately. If it is
  /// not, the cancel is either remembered (pre-open, so the eventual
  /// `register(token)` returns an already-cancelled handle) or dropped
  /// (post-close), distinguished by the [_highestSeenId] high-water mark:
  /// an id that has already been seen by `register` belongs to a closed
  /// request and is dropped to keep `_pendingCancellations` bounded.
  void cancel(IsolateCancellationToken token) {
    final entry = _entries[token.id];
    if (entry != null) {
      entry.markCancelled();
    } else if (token.id > _highestSeenId) {
      _pendingCancellations.add(token.id);
    }
    // else: post-close cancel for an already-seen id — dropped.
  }

  /// Whether [token] is cancelled, **while the registry still holds it**:
  /// between [register] and [IsolateCancellationHandle.dispose], or before
  /// [register] while a pre-open cancel is remembered for it.
  ///
  /// Outside that window the answer is `false` — including for a request
  /// that genuinely *was* cancelled and has since been disposed. The
  /// registry is in-flight state, and deliberately keeps no record of
  /// cancelled-and-closed ids: ids are never recycled, so such a record
  /// could only grow for the executor's whole lifetime. That is the same
  /// leak the post-close cancel drop above exists to avoid.
  ///
  /// [IsolateCancellationHandle.isCancelled] does **not** narrow this way.
  /// A handle holds its own reference to the entry, so it still answers
  /// `true` after `dispose`. Prefer the handle wherever one is in scope —
  /// it is the durable answer for one request. This method answers "is
  /// this id cancelled *right now*", which is what a dispatcher holding an
  /// arbitrary id, and no handle, can ask.
  bool isCancelled(IsolateCancellationToken token) {
    final entry = _entries[token.id];
    if (entry != null) return entry._cancelled;
    return _pendingCancellations.contains(token.id);
  }

  /// Number of currently registered (in-flight) tokens. Visible for
  /// tests.
  int get inFlightCount => _entries.length;

  /// Number of remembered pending cancellations. Visible for tests.
  int get pendingCancelCount => _pendingCancellations.length;

  void _unregister(int id) {
    _entries.remove(id);
  }
}

/// Per-token state: the cancelled flag and the future that fires with it.
///
/// Carries no class modifier, unlike the public types in this module. A
/// modifier restricts subtyping from *outside* the declaring library, and a
/// private class is not visible there — `final` here would read as a decision
/// while permitting exactly what its absence permits.
class _RegistryEntry {
  bool _cancelled;

  /// Completes the first time the entry is cancelled. Lets a producer
  /// `await` cancellation instead of polling the flag.
  final Completer<void> _cancelSignal = Completer<void>();

  _RegistryEntry({required bool cancelled}) : _cancelled = cancelled {
    if (cancelled) _cancelSignal.complete();
  }

  /// Idempotently raises the cancelled-flag and fires [_cancelSignal].
  void markCancelled() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }
}

/// Per-request cancellation handle returned by
/// [IsolateCancellationRegistry.register].
///
/// The executor reads [isCancelled] at the well-defined checkpoints
/// (before the call, between chunks for streams, after the call).
/// Calling [dispose] removes the registration; idempotent.
final class IsolateCancellationHandle {
  final IsolateCancellationToken token;
  final _RegistryEntry _entry;
  final IsolateCancellationRegistry _owner;
  bool _disposed = false;

  IsolateCancellationHandle._(this.token, this._entry, this._owner);

  /// Whether the request has been cancelled (either pre- or post-call).
  ///
  /// Survives [dispose]: the handle holds the entry directly, so it keeps
  /// answering for its own request after the registry has dropped it. That
  /// is the divergence noted on [IsolateCancellationRegistry.isCancelled],
  /// and this is the side to trust for a single request.
  bool get isCancelled => _entry._cancelled;

  /// Completes the first time the request is cancelled. Lets a stream
  /// producer `await` cancellation alongside its source completion and
  /// close signal instead of polling the flag on a timer. Never
  /// completes if the request is not cancelled.
  Future<void> get cancelled => _entry._cancelSignal.future;

  /// Throws [IsolateCancellationException] when cancelled. Convenience
  /// for pre-call and post-call checkpoints.
  void throwIfCancelled() {
    if (_entry._cancelled) {
      throw IsolateCancellationException(token);
    }
  }

  /// Unregister this handle. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner._unregister(token.id);
  }
}

/// Thrown by the executor when a cancellable request is cancelled at (or
/// after) a checkpoint. An isolate host typically re-raises this across
/// the boundary as a generic boundary exception whose `exceptionType` is
/// `'IsolateCancellationException'`, which the client translates back to
/// this typed class for the caller.
final class IsolateCancellationException implements Exception {
  /// The token that was cancelled.
  final IsolateCancellationToken token;

  IsolateCancellationException(this.token);

  @override
  String toString() => 'IsolateCancellationException(token=${token.id})';
}

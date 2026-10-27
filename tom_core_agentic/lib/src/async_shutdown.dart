// Async shutdown coordination — signal → awaited teardown → terminate.
//
// A running process needs to turn a termination trigger (an OS signal, a
// supervisor message, a test stimulus) into an *async* teardown that runs
// to completion before the process exits. The synchronous fire-and-forget
// handler models common in runtimes cannot await a drain, so they race the
// exit and drop in-flight work. This coordinator awaits the teardown first.
//
// It is generic over the trigger type [S] and takes its trigger streams,
// its teardown action, and its process terminator as injectable seams, so a
// test drives the whole sequence with no real signal and no real `exit`.
// The teardown action itself (what "drain" means) is the caller's — this
// owns only the first-trigger-wins gating, the await, and the terminate.

import 'dart:async';

import 'package:tom_basics/tom_basics.dart';

/// The async teardown an [AsyncShutdownCoordinator] runs on the first
/// trigger. Returns when teardown is complete; may throw, in which case the
/// process still terminates but with [shutdownExitError].
typedef ShutdownAction = Future<void> Function();

/// Terminates the process with [code]. Production passes `dart:io`'s `exit`
/// (wrapped to the plain `void Function(int)` shape); a test injects a
/// recorder so the process survives the assertion.
typedef ProcessTerminator = void Function(int code);

/// Exit code for a clean shutdown (the teardown completed without throwing).
const int shutdownExitOk = 0;

/// Exit code when the teardown threw (`EX_SOFTWARE`, the conventional
/// "internal software error" code). The process still exits — a failed
/// drain must not hold it open — but the non-zero code surfaces the failure
/// to a supervisor.
const int shutdownExitError = 70;

/// Watches trigger streams and runs an async teardown to completion before
/// terminating the process.
///
/// Construct via [AsyncShutdownCoordinator.install], which subscribes to the
/// trigger streams immediately. The *first* trigger wins: it flips
/// [isTriggered], runs the [ShutdownAction] to completion (logging start and
/// finish through `tomLog` under [label]), then calls the
/// [ProcessTerminator]. Any further trigger that arrives while the teardown
/// is in flight is logged and ignored. [completed] resolves with the chosen
/// exit code once the teardown has run, so a test can await the whole
/// sequence without a real terminate.
final class AsyncShutdownCoordinator<S> {
  final String _label;
  final ShutdownAction _onShutdown;
  final ProcessTerminator _terminate;
  final List<StreamSubscription<S>> _subscriptions = <StreamSubscription<S>>[];
  final Completer<int> _completed = Completer<int>();
  bool _triggered = false;

  AsyncShutdownCoordinator._(this._label, this._onShutdown, this._terminate);

  /// Whether a trigger has already begun the shutdown sequence. Once
  /// `true`, further triggers are ignored.
  bool get isTriggered => _triggered;

  /// Resolves with the exit code once the teardown has run (after the first
  /// trigger): [shutdownExitOk] on a clean teardown, [shutdownExitError] if
  /// the [ShutdownAction] threw. Never resolves if no trigger arrives.
  Future<int> get completed => _completed.future;

  /// Installs a coordinator and starts listening on [signals].
  ///
  /// [label] tags the lifecycle log lines (e.g.
  /// `'tom_brain.access.shutdown'`). [onShutdown] is the async teardown run
  /// on the first trigger. [terminate] defaults to a no-op-free required
  /// seam — the caller supplies the real process exit (or a test recorder).
  static AsyncShutdownCoordinator<S> install<S>({
    required String label,
    required ShutdownAction onShutdown,
    required List<Stream<S>> signals,
    required ProcessTerminator terminate,
  }) {
    final coordinator = AsyncShutdownCoordinator<S>._(
      label,
      onShutdown,
      terminate,
    );
    for (final stream in signals) {
      coordinator._subscriptions.add(stream.listen(coordinator._onSignal));
    }
    return coordinator;
  }

  /// First trigger wins: begin the async teardown. A trigger that arrives
  /// while the teardown is already in flight is logged and ignored.
  void _onSignal(S signal) {
    if (_triggered) {
      tomLog.status(
        '[$_label] $signal received while already shutting '
        'down — ignored',
      );
      return;
    }
    _triggered = true;
    // Fire-and-forget the async teardown; `_runShutdown` owns its own errors
    // and resolves `completed`. The handler stays synchronous so a burst of
    // triggers all hit the `_triggered` guard.
    unawaited(_runShutdown(signal));
  }

  /// Runs the teardown to completion, then terminates. Stops listening for
  /// further triggers first, awaits [_onShutdown], resolves [completed] with
  /// the exit code, and calls the [ProcessTerminator] last.
  Future<void> _runShutdown(S signal) async {
    tomLog.status('[$_label] $signal received — running shutdown teardown');
    await _cancelSubscriptions();
    var code = shutdownExitOk;
    try {
      await _onShutdown();
      tomLog.status('[$_label] shutdown complete');
    } catch (error, stackTrace) {
      code = shutdownExitError;
      tomLog.severe('[$_label] shutdown action failed: $error\n$stackTrace');
    }
    if (!_completed.isCompleted) {
      _completed.complete(code);
    }
    _terminate(code);
  }

  /// Cancels and clears the trigger subscriptions. Idempotent.
  Future<void> _cancelSubscriptions() async {
    final subscriptions = List<StreamSubscription<S>>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Stops listening without triggering a shutdown. For a test teardown or
  /// an embedding context that manages its own lifecycle. Idempotent and
  /// safe in a `finally`.
  Future<void> dispose() => _cancelSubscriptions();
}

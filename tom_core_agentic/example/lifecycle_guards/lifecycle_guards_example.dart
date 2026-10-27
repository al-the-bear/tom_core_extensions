// Runnable demo of the lifecycle & guards primitives.
//
// Walks the five reusable building blocks exported from the public barrel that
// have no other example: the `requireNonEmpty` argument guard, the
// `AsyncShutdownCoordinator` signal->drain->terminate wiring, the
// `TomCancellationSource` / `TomCancellationToken` cooperative-cancellation
// channel, the `CloseGuard` use-after-close mixin, and the `Deadline`
// wall-clock budget. Every seam that would otherwise be non-deterministic — the
// shutdown signal stream and process terminator, and the deadline clock — is
// injected, so the demo runs the same way every time and never touches a real
// OS signal, `exit`, or wall clock.
//
// Run with:
//   dart run --enable-asserts example/lifecycle_guards/lifecycle_guards_example.dart

import 'dart:async';

import 'package:tom_basics/utilities.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../require_asserts.dart';

Future<void> main() async {
  requireAsserts();
  _demoArgumentGuard();
  await _demoAsyncShutdown();
  await _demoCancellation();
  _demoCloseGuard();
  _demoDeadline();

  print('\nlifecycle_guards demo completed.');
}

// ---------------------------------------------------------------------------
// requireNonEmpty: a one-line constructor-boundary guard for required strings.
// ---------------------------------------------------------------------------
void _demoArgumentGuard() {
  print('== argument guard ==');

  // The happy path returns the value unchanged, so it reads naturally in a
  // field initializer: `id = requireNonEmpty(id, 'id')`.
  final id = requireNonEmpty('agent-7', 'id');
  print('  accepted: $id');
  assert(id == 'agent-7');

  // An empty required string is rejected with a uniform message naming the arg.
  try {
    requireNonEmpty('', 'id');
  } on ArgumentError catch (e) {
    print('  rejected empty: ${e.name} -> ${e.message}');
    assert(e.name == 'id');
    assert(e.message == 'must be non-empty');
  }
}

// ---------------------------------------------------------------------------
// AsyncShutdownCoordinator: first trigger wins, teardown is awaited to
// completion, THEN the process terminator runs. Both the signal source and the
// terminator are injected so the demo drives the whole sequence with no real
// signal and no real exit.
// ---------------------------------------------------------------------------
Future<void> _demoAsyncShutdown() async {
  print('== async shutdown ==');

  // The "signal" is just a stream we control; the "terminator" records the
  // exit code instead of ending the process.
  final signals = StreamController<String>();
  final exitCodes = <int>[];
  var drained = false;

  final coordinator = AsyncShutdownCoordinator.install<String>(
    label: 'demo.shutdown',
    onShutdown: () async {
      // Stand-in for an awaited drain (flush buffers, close sockets, ...).
      await Future<void>.delayed(const Duration(milliseconds: 1));
      drained = true;
    },
    signals: [signals.stream],
    terminate: exitCodes.add,
  );

  assert(!coordinator.isTriggered);

  // Fire two triggers in a burst — only the first starts a teardown.
  signals.add('SIGTERM');
  signals.add('SIGTERM'); // ignored: shutdown already in flight
  final code = await coordinator.completed;

  print(
    '  triggered: ${coordinator.isTriggered}, drained: $drained, '
    'exit code: $code',
  );
  assert(coordinator.isTriggered);
  assert(drained); // teardown completed BEFORE terminate ran
  assert(code == shutdownExitOk);
  assert(exitCodes.length == 1); // the duplicate trigger was ignored
  assert(exitCodes.single == shutdownExitOk);

  await signals.close();

  // A teardown that throws still terminates the process, but with the error
  // exit code so a supervisor sees the failed drain.
  final failSignals = StreamController<String>();
  final failExitCodes = <int>[];
  final failing = AsyncShutdownCoordinator.install<String>(
    label: 'demo.shutdown.failing',
    onShutdown: () async => throw StateError('drain blew up'),
    signals: [failSignals.stream],
    terminate: failExitCodes.add,
  );
  failSignals.add('SIGINT');
  final failCode = await failing.completed;
  print('  failed teardown exit code: $failCode');
  assert(failCode == shutdownExitError);
  assert(failExitCodes.single == shutdownExitError);
  await failSignals.close();
}

// ---------------------------------------------------------------------------
// TomCancellationSource / TomCancellationToken: the owner cancels; downstream
// work either polls isCancelled or races whenCancelled against its operation.
// ---------------------------------------------------------------------------
Future<void> _demoCancellation() async {
  print('== cancellation ==');

  final source = TomCancellationSource();
  final token = source.token;
  assert(!token.isCancelled);

  // A long operation that loses the race to cancellation. We start a slow piece
  // of work and cancel before it can finish; racing whenCancelled lets the
  // caller abandon the result and surface TomOperationCancelled.
  final slowWork = Future<String>.delayed(
    const Duration(seconds: 10),
    () => 'work result',
  );

  Future<void>.delayed(const Duration(milliseconds: 1), source.cancel);

  String outcome;
  try {
    outcome = await _runCancellable(slowWork, token, 'slowWork');
  } on TomOperationCancelled catch (e) {
    outcome = e.toString();
  }
  print('  $outcome');
  assert(outcome == 'TomOperationCancelled(slowWork)');
  assert(token.isCancelled);
  assert(source.isCancelled);

  // cancel() is idempotent — a second call is a no-op.
  source.cancel();
  assert(source.isCancelled);

  // The fast-check path: poll isCancelled at the top of a critical section.
  final fresh = TomCancellationSource();
  var ran = 0;
  for (var i = 0; i < 3; i++) {
    if (fresh.token.isCancelled) break;
    ran++;
    if (i == 1) fresh.cancel(); // stop before the 3rd iteration
  }
  print('  fast-check ran $ran of 3 iterations');
  assert(ran == 2);

  // TomCancellationToken.none is a permanent no-cancel default.
  assert(!TomCancellationToken.none.isCancelled);
}

/// Awaits [work], but abandons it and throws [TomOperationCancelled] if [token]
/// signals first. The underlying future keeps running — this models the
/// "no per-request abort handle" reality and just stops *awaiting* the result.
Future<T> _runCancellable<T>(
  Future<T> work,
  TomCancellationToken token,
  String operation,
) async {
  final cancelled = token.whenCancelled.then((_) => null);
  final winner = await Future.any<Object?>([work, cancelled]);
  if (token.isCancelled) {
    throw TomOperationCancelled(operation);
  }
  return winner as T;
}

// ---------------------------------------------------------------------------
// CloseGuard: a mixin that owns the closed flag, the use-after-close guard, and
// idempotent close transition, so a resource holder keeps only its own release
// logic.
// ---------------------------------------------------------------------------
void _demoCloseGuard() {
  print('== close guard ==');

  final client = _DemoClient();
  final reply = client.send('ping');
  print('  $reply');
  assert(reply == 'sent: ping');
  assert(!client.isClosed);

  // First close transitions and releases; a second close is a no-op.
  assert(client.close()); // performed the transition
  assert(client.isClosed);
  assert(client.releaseCount == 1);
  assert(!client.close()); // already closed
  assert(client.releaseCount == 1); // release ran exactly once

  // Use after close throws a StateError naming the operation.
  try {
    client.send('late');
  } on StateError catch (e) {
    print('  use-after-close: ${e.message}');
    assert(e.message == '_DemoClient.send called after close()');
  }
}

/// A minimal resource holder built on [CloseGuard]: the mixin owns the flag and
/// the two operations; this class owns only `send` and the release.
final class _DemoClient with CloseGuard {
  int releaseCount = 0;

  String send(String message) {
    ensureOpen('_DemoClient.send');
    return 'sent: $message';
  }

  /// Idempotent: releases the resource only on the first close.
  bool close() {
    if (!markClosed()) return false;
    releaseCount++;
    return true;
  }
}

// ---------------------------------------------------------------------------
// Deadline: a wall-clock budget read against an injectable clock, so a timed
// loop is deterministic in tests/examples. We drive a mutable fake clock.
// ---------------------------------------------------------------------------
void _demoDeadline() {
  print('== deadline ==');

  // A controllable clock — advancing `now` simulates wall-clock passage.
  var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
  DateTime clock() => now;

  final deadline = Deadline.startingNow(
    const Duration(seconds: 30),
    clock: clock,
  );
  assert(!deadline.isExpired);
  print('  remaining at start: ${deadline.remaining.inSeconds}s');
  assert(deadline.remaining == const Duration(seconds: 30));

  // A bounded loop that respects the budget: each iteration advances the clock
  // and bails once the deadline is reached.
  var iterations = 0;
  while (!deadline.isExpired) {
    iterations++;
    now = now.add(const Duration(seconds: 10));
  }
  print('  loop ran $iterations iterations before the budget elapsed');
  assert(iterations == 3); // 0->10->20->30s: third check sees expiry
  assert(deadline.isExpired);
  assert(deadline.remaining == Duration.zero); // clamped, never negative

  // The throw-on-expiry guard for a caller that wants a hard stop.
  try {
    deadline.throwIfExpired();
  } on DeadlineExceeded catch (e) {
    print('  throwIfExpired -> $e');
    assert(e.expiresAt == DateTime.utc(2026, 1, 1, 12, 0, 30));
  }
}

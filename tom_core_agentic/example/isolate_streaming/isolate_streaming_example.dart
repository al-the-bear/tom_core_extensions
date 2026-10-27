// Runnable demo of the isolate_streaming primitives. It walks each of the five
// building blocks in turn — cancellation, the per-stream close signal, the
// backpressure ledger, the request guard, and the exception registry.
//
// The cancellation demo spawns a *real* isolate; the other four do not. That
// asymmetry is deliberate. Cancellation is the one primitive whose whole point
// is which side owns what, and a demo that fakes the boundary cannot show it —
// every call compiles and runs wherever you put it, so an inverted arrangement
// looks exactly as convincing as the correct one. Over a real port it does not:
// only the token can make the trip. The remaining four are single-sided ledgers
// with nothing to send, and a boundary would be scenery.
//
// The sendability split this demo relies on is pinned by the
// `sendability across an isolate boundary` group in
// `test/isolate_streaming_test.dart` — nothing runs this file automatically.
//
// Run with:
//   dart run --enable-asserts example/isolate_streaming/isolate_streaming_example.dart

import 'dart:async';
import 'dart:isolate';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../require_asserts.dart';

Future<void> main() async {
  requireAsserts();
  await _demoCancellation();
  await _demoCloseSignal();
  await _demoBackpressure();
  await _demoRequestGuard();
  _demoExceptionRegistry();

  print('\nAll isolate_streaming demos completed.');
}

// ---------------------------------------------------------------------------
// Cancellation: only the token crosses. The host allocates it and sends its
// *id* in a request envelope; the worker isolate owns the registry, registers
// the token when that envelope lands, and turns a later cancel envelope into
// `registry.cancel`. Cancelling is a message, not a call into the worker.
// ---------------------------------------------------------------------------
Future<void> _demoCancellation() async {
  print('== cancellation ==');

  // The allocator is host-side: ids are unique per host and never recycled.
  final allocator = IsolateCancellationTokenAllocator();

  final fromWorker = ReceivePort();
  final ready = Completer<SendPort>();
  final replies = <int, Completer<String>>{};
  fromWorker.listen((Object? message) {
    if (message is SendPort) {
      ready.complete(message);
      return;
    }
    final reply = (message as Map).cast<String, Object?>();
    replies[reply['cancellation'] as int]!.complete(reply['status'] as String);
  });

  await Isolate.spawn(_cancellationWorker, fromWorker.sendPort);
  final toWorker = await ready.future;

  // Request, then abort it while it is in flight.
  final token = allocator.next();
  replies[token.id] = Completer<String>();
  toWorker.send(<String, Object?>{'op': 'work', 'cancellation': token.id});
  toWorker.send(<String, Object?>{'op': 'cancel', 'cancellation': token.id});
  print('  in-flight: ${await replies[token.id]!.future}');

  // Late-cancel race. Sending the cancel first is the real shape of the race
  // the registry exists for: the worker's registry remembers it, so the
  // register that follows hands back an already-cancelled handle.
  final lateToken = allocator.next();
  replies[lateToken.id] = Completer<String>();
  final lateId = lateToken.id;
  toWorker.send(<String, Object?>{'op': 'cancel', 'cancellation': lateId});
  toWorker.send(<String, Object?>{'op': 'work', 'cancellation': lateId});
  print('  late cancel: ${await replies[lateToken.id]!.future}');

  // Why the registry stays put: a handle holds a Completer, so the boundary
  // rejects it. This is the error a caller gets for trying to register on the
  // host and ship the result across.
  final handle = IsolateCancellationRegistry().register(allocator.next());
  try {
    toWorker.send(handle);
    print('  BUG: the handle crossed the boundary');
  } on ArgumentError {
    print('  shipping a handle -> ArgumentError: object is unsendable');
  }

  // What the `finally` in `_serveRequest` buys. Both requests above ended —
  // one cancelled in flight, one cancelled before it began — and the worker's
  // registry is empty again, because each handle was disposed. Skip that call
  // and the entry stays for the life of the executor: nothing fails, nothing
  // is logged, and `inFlightCount` is the number that would have told you.
  final ledger = Completer<String>();
  replies[-1] = ledger;
  toWorker.send(<String, Object?>{'op': 'stats'});
  final inFlight = int.parse(await ledger.future);
  print('  registry after both requests: $inFlight in flight');
  assert(inFlight == 0);

  toWorker.send(<String, Object?>{'op': 'stop'});
  fromWorker.close();
}

/// Entry point of the worker isolate. The registry is created *here* and never
/// leaves; only token ids arrive over the port.
void _cancellationWorker(SendPort toHost) {
  final registry = IsolateCancellationRegistry();
  final inbox = ReceivePort();
  toHost.send(inbox.sendPort);

  inbox.listen((Object? message) {
    final envelope = (message as Map).cast<String, Object?>();
    switch (envelope['op'] as String) {
      case 'stop':
        inbox.close();
      case 'stats':
        // The registry's own view of what it still holds. Reported rather than
        // asserted here because the host is the side with the assertions, and
        // this is the one fact about the worker's state it cannot see.
        toHost.send(<String, Object?>{
          'cancellation': -1,
          'status': '${registry.inFlightCount}',
        });
      case 'cancel':
        // The executor is what flips the flag — the host only sent a message.
        registry.cancel(
          IsolateCancellationToken(envelope['cancellation'] as int),
        );
      case 'work':
        // Not awaited: the request has to run *alongside* the message loop, or
        // the cancel envelope it is waiting for could never be delivered.
        unawaited(
          _serveRequest(
            registry,
            IsolateCancellationToken(envelope['cancellation'] as int),
            toHost,
          ),
        );
    }
  });
}

/// One cancellable request, executor-side: register, wait at a checkpoint,
/// report, dispose.
Future<void> _serveRequest(
  IsolateCancellationRegistry registry,
  IsolateCancellationToken token,
  SendPort toHost,
) async {
  final handle = registry.register(token);
  // Already cancelled at registration means the cancel envelope overtook the
  // request envelope — the late-cancel case the registry remembers.
  final overtaken = handle.isCancelled;
  try {
    // A real producer races this against its source; here cancellation is the
    // only outcome the demo drives.
    await handle.cancelled;
    handle.throwIfCancelled();
    toHost.send(<String, Object?>{
      'cancellation': token.id,
      'status': 'completed',
    });
  } on IsolateCancellationException catch (e) {
    toHost.send(<String, Object?>{
      'cancellation': token.id,
      'status': overtaken ? 'cancelled before it began ($e)' : 'cancelled ($e)',
    });
  } finally {
    handle.dispose();
  }
}

// ---------------------------------------------------------------------------
// Close signal: worker-side, one per open stream. A close request arriving
// from the host calls requestClose, which both raises a flag (polled by a
// backpressured producer) and fires a future (awaited by an unbounded one).
// ---------------------------------------------------------------------------
Future<void> _demoCloseSignal() async {
  print('== close signal ==');
  final signal = IsolateStreamCloseSignal();
  assert(!signal.closeRequested);

  final awaited = signal.closeSignal.future.then((_) => 'producer stopped');
  signal.requestClose();
  signal.requestClose(); // idempotent

  assert(signal.closeRequested);
  print('  ${await awaited}');
}

// ---------------------------------------------------------------------------
// Backpressure: the consumer grants credits, the producer awaits/consumes.
// ---------------------------------------------------------------------------
Future<void> _demoBackpressure() async {
  print('== backpressure ==');
  // Start with no credits so the producer must wait for the consumer.
  final bp = BackpressureTracker(initialCredits: 0);

  // Producer blocks until a credit is granted, then consumes it to emit.
  final firstEmit = bp.awaitCredit().then((_) {
    bp.consume();
    return 'emitted item #1';
  });
  assert(bp.waiterCount == 1);

  bp.grant(1); // consumer signals room
  print('  ${await firstEmit}');
  assert(bp.credits == 0);

  // A waiter parked at close fails with StateError so the producer can unwind.
  final unwind = bp.awaitCredit().then(
    (_) => 'unexpected credit',
    onError: (Object e) => 'producer unwound after close ($e)',
  );
  bp.close();
  print('  ${await unwind}');
  assert(bp.isClosed);
}

// ---------------------------------------------------------------------------
// Request guard: a request fails fast on worker death (or a deadline).
// ---------------------------------------------------------------------------
Future<void> _demoRequestGuard() async {
  print('== request guard ==');
  final guard = IsolateRequestGuard(defaultTimeout: const Duration(seconds: 5));

  // A request the worker never answers.
  final pending = Completer<Never>();
  final guarded = guard.guard(pending.future, operation: 'embed');
  assert(guard.inFlightCount == 1);

  // The worker dies before replying.
  guard.markWorkerDead('isolate exited with code 70');

  try {
    await guarded;
  } on IsolateRequestFailure catch (e) {
    assert(e.reason == IsolateRequestFailureReason.workerDeath);
    print('  guarded request failed: $e');
  }
  assert(guard.isWorkerDead);
}

// ---------------------------------------------------------------------------
// Exception registry: rebuild typed errors from the data that crosses the wire.
// ---------------------------------------------------------------------------
void _demoExceptionRegistry() {
  print('== exception registry ==');
  final registry = IsolateExceptionRegistry()
    ..register(
      'NotFound',
      (message, details) =>
          _NotFoundError(message, id: details['id'] as String?),
    );

  assert(registry.isRegistered('NotFound'));
  final restored = registry.reconstruct('NotFound', 'missing record', {
    'id': 'x-7',
  });
  print('  reconstructed: $restored');
  assert(restored is _NotFoundError);

  // An unregistered tag yields null; the caller falls back to a generic error.
  final unknown = registry.reconstruct('Mystery', 'huh', const {});
  assert(unknown == null);
  print('  unregistered tag -> $unknown');
}

class _NotFoundError implements Exception {
  _NotFoundError(this.message, {this.id});
  final String message;
  final String? id;
  @override
  String toString() => 'NotFound($message, id=$id)';
}

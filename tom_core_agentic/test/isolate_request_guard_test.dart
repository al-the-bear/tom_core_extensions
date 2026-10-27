// IsolateRequestGuard — generic worker-death + per-request deadline
// guard for cross-isolate request/response protocols.
//
// What this file locks:
//
//   1. A guarded request that completes normally returns its value and
//      the guard's bookkeeping drains (no leaked in-flight entry, the
//      deadline timer is cancelled).
//   2. A guarded request that fails with its own error propagates that
//      error unchanged (the guard does not rewrite domain failures).
//   3. `markWorkerDead()` fails every in-flight guarded request now with
//      a typed `IsolateRequestFailure(workerDeath)` instead of hanging,
//      and is idempotent.
//   4. A request guarded *after* the worker is already dead fails fast
//      with `workerDeath` (no send is attempted into a dead worker).
//   5. A per-request deadline fails a hanging request with
//      `IsolateRequestFailure(timeout)`; an explicit per-call timeout
//      overrides the guard's default; worker-death pre-empts a pending
//      deadline (it does not wait for the timer).
//   6. A timeout calls the caller's `cancel(token)` once, after failing the
//      caller, so the abandoned work can be stopped; a completed request and
//      a worker death never call it; a token and a callback come together.
//
// No real isolate is spawned here: the guard is a pure host-side
// race over a `Future` plus a death signal plus a timer, so it is
// tested with hand-driven `Completer`s. The real isolate-exit wiring
// is exercised by `tom_brain_memory`'s kill-worker-mid-call test.

import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('IsolateRequestGuard — happy path', () {
    test(
      'a completing request returns its value and drains bookkeeping',
      () async {
        final guard = IsolateRequestGuard();
        final source = Completer<int>();
        final guarded = guard.guard(source.future, operation: 'recall');
        expect(guard.inFlightCount, equals(1));
        source.complete(42);
        expect(await guarded, equals(42));
        // The entry removes itself once the request settles.
        expect(guard.inFlightCount, equals(0));
        expect(guard.isWorkerDead, isFalse);
      },
    );

    test('a request that throws propagates its own error unchanged', () async {
      final guard = IsolateRequestGuard();
      final source = Completer<int>();
      final guarded = guard.guard(source.future, operation: 'open');
      source.completeError(const FormatException('bad envelope'));
      await expectLater(guarded, throwsA(isA<FormatException>()));
      expect(guard.inFlightCount, equals(0));
    });
  });

  group('IsolateRequestGuard — worker death', () {
    test(
      'markWorkerDead fails an in-flight request with workerDeath',
      () async {
        final guard = IsolateRequestGuard();
        final neverCompletes = Completer<int>();
        final guarded = guard.guard(neverCompletes.future, operation: 'stats');
        guard.markWorkerDead('isolate exited');
        await expectLater(
          guarded,
          throwsA(
            isA<IsolateRequestFailure>()
                .having(
                  (f) => f.reason,
                  'reason',
                  IsolateRequestFailureReason.workerDeath,
                )
                .having((f) => f.message, 'message', contains('stats'))
                .having(
                  (f) => f.message,
                  'message',
                  contains('isolate exited'),
                ),
          ),
        );
        expect(guard.isWorkerDead, isTrue);
        expect(guard.inFlightCount, equals(0));
      },
    );

    test('markWorkerDead fails every in-flight request at once', () async {
      final guard = IsolateRequestGuard();
      final a = guard.guard(Completer<int>().future, operation: 'a');
      final b = guard.guard(Completer<int>().future, operation: 'b');
      final c = guard.guard(Completer<int>().future, operation: 'c');
      expect(guard.inFlightCount, equals(3));
      guard.markWorkerDead();
      await expectLater(a, throwsA(isA<IsolateRequestFailure>()));
      await expectLater(b, throwsA(isA<IsolateRequestFailure>()));
      await expectLater(c, throwsA(isA<IsolateRequestFailure>()));
      expect(guard.inFlightCount, equals(0));
    });

    test('a request guarded after death fails fast with workerDeath', () async {
      final guard = IsolateRequestGuard();
      guard.markWorkerDead();
      final guarded = guard.guard(Completer<int>().future, operation: 'late');
      await expectLater(
        guarded,
        throwsA(
          isA<IsolateRequestFailure>().having(
            (f) => f.reason,
            'reason',
            IsolateRequestFailureReason.workerDeath,
          ),
        ),
      );
    });

    test('markWorkerDead is idempotent', () async {
      final guard = IsolateRequestGuard();
      guard.markWorkerDead('first');
      guard.markWorkerDead('second');
      expect(guard.isWorkerDead, isTrue);
      final guarded = guard.guard(Completer<int>().future);
      await expectLater(
        guarded,
        throwsA(
          isA<IsolateRequestFailure>().having(
            (f) => f.message,
            'message',
            contains('first'),
          ),
        ),
      );
    });

    test(
      'a request that already completed is unaffected by a later death',
      () async {
        final guard = IsolateRequestGuard();
        final source = Completer<int>();
        final guarded = guard.guard(source.future);
        source.complete(7);
        expect(await guarded, equals(7));
        // No throw, no state corruption.
        guard.markWorkerDead();
        expect(guard.isWorkerDead, isTrue);
      },
    );
  });

  group('IsolateRequestGuard — per-request deadline', () {
    test('a hanging request fails with timeout after the deadline', () async {
      final guard = IsolateRequestGuard(
        defaultTimeout: const Duration(milliseconds: 30),
      );
      final guarded = guard.guard(Completer<int>().future, operation: 'recall');
      await expectLater(
        guarded,
        throwsA(
          isA<IsolateRequestFailure>()
              .having(
                (f) => f.reason,
                'reason',
                IsolateRequestFailureReason.timeout,
              )
              .having((f) => f.message, 'message', contains('recall')),
        ),
      );
      expect(guard.inFlightCount, equals(0));
    });

    test(
      'a fast request under the deadline resolves and cancels the timer',
      () async {
        final guard = IsolateRequestGuard(
          defaultTimeout: const Duration(milliseconds: 200),
        );
        final source = Completer<int>();
        final guarded = guard.guard(source.future);
        source.complete(1);
        expect(await guarded, equals(1));
        // Wait past the deadline to prove no late timeout error fires.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(guard.inFlightCount, equals(0));
      },
    );

    test('an explicit per-call timeout overrides the default', () async {
      final guard = IsolateRequestGuard(
        defaultTimeout: const Duration(seconds: 10),
      );
      final guarded = guard.guard(
        Completer<int>().future,
        timeout: const Duration(milliseconds: 20),
        operation: 'fast-bound',
      );
      await expectLater(
        guarded,
        throwsA(
          isA<IsolateRequestFailure>().having(
            (f) => f.reason,
            'reason',
            IsolateRequestFailureReason.timeout,
          ),
        ),
      );
    });

    test(
      'worker death pre-empts a pending deadline (no wait for the timer)',
      () async {
        final guard = IsolateRequestGuard(
          defaultTimeout: const Duration(seconds: 30),
        );
        final guarded = guard.guard(Completer<int>().future);
        final sw = Stopwatch()..start();
        guard.markWorkerDead();
        await expectLater(
          guarded,
          throwsA(
            isA<IsolateRequestFailure>().having(
              (f) => f.reason,
              'reason',
              IsolateRequestFailureReason.workerDeath,
            ),
          ),
        );
        sw.stop();
        // Must fail promptly, not after the 30s deadline.
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      },
    );
  });

  group('IsolateRequestGuard — cancelling what a timeout abandons', () {
    const token = IsolateCancellationToken(7);

    test('a timeout calls cancel with the token, once', () async {
      final guard = IsolateRequestGuard();
      final source = Completer<int>();
      final cancelled = <IsolateCancellationToken>[];
      final guarded = guard.guard(
        source.future,
        timeout: const Duration(milliseconds: 10),
        cancellation: token,
        cancel: (t) {
          cancelled.add(t);
        },
      );
      await expectLater(
        guarded,
        throwsA(
          isA<IsolateRequestFailure>().having(
            (f) => f.reason,
            'reason',
            IsolateRequestFailureReason.timeout,
          ),
        ),
      );
      expect(cancelled, [token]);
      // A late answer changes nothing: the caller was answered, and cancel is
      // not called a second time.
      source.complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, [token]);
      expect(guard.inFlightCount, 0);
    });

    test('a request that completes in time is not cancelled', () async {
      final guard = IsolateRequestGuard();
      final cancelled = <IsolateCancellationToken>[];
      final result = await guard.guard(
        Future.value(3),
        timeout: const Duration(milliseconds: 50),
        cancellation: token,
        cancel: cancelled.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(result, 3);
      expect(cancelled, isEmpty);
    });

    test(
      'a worker death does not cancel: nobody is left to receive it',
      () async {
        final guard = IsolateRequestGuard();
        final cancelled = <IsolateCancellationToken>[];
        final guarded = guard.guard(
          Completer<int>().future,
          timeout: const Duration(milliseconds: 20),
          cancellation: token,
          cancel: cancelled.add,
        );
        guard.markWorkerDead('killed');
        await expectLater(guarded, throwsA(isA<IsolateRequestFailure>()));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(cancelled, isEmpty);
      },
    );

    test('a token without a cancel callback, or the reverse, is refused', () {
      final guard = IsolateRequestGuard();
      expect(
        () => guard.guard(Future.value(1), cancellation: token),
        throwsArgumentError,
      );
      expect(
        () => guard.guard(Future.value(1), cancel: (_) {}),
        throwsArgumentError,
      );
    });
  });

  group('IsolateRequestFailure — value semantics', () {
    test('toString carries the reason tag and the message', () {
      const failure = IsolateRequestFailure(
        IsolateRequestFailureReason.timeout,
        'recall exceeded its 5000ms deadline',
      );
      expect(failure.toString(), contains('timeout'));
      expect(failure.toString(), contains('recall exceeded'));
    });

    test('reason enum has exactly the two boundary failure modes', () {
      expect(IsolateRequestFailureReason.values, hasLength(2));
      expect(
        IsolateRequestFailureReason.values,
        containsAll(<IsolateRequestFailureReason>[
          IsolateRequestFailureReason.workerDeath,
          IsolateRequestFailureReason.timeout,
        ]),
      );
    });
  });
}

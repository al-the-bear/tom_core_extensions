// Unit tests for the generic isolate-streaming machinery promoted from
// tom_brain_memory's isolate adapter.
//
// These exercise the mechanisms in isolation; the brain-memory isolate
// boundary round-trips that consume them live in
// `tom_brain_memory/test/a81_message_protocol_test.dart`.

import 'dart:async';
import 'dart:isolate';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('IsolateCancellationRegistry', () {
    test('register then cancel flips the flag', () {
      final reg = IsolateCancellationRegistry();
      final tok = const IsolateCancellationToken(1);
      final h = reg.register(tok);
      expect(h.isCancelled, isFalse);
      reg.cancel(tok);
      expect(h.isCancelled, isTrue);
      expect(reg.isCancelled(tok), isTrue);
    });

    test('cancel-before-register is remembered (late-cancel race)', () {
      final reg = IsolateCancellationRegistry();
      final tok = const IsolateCancellationToken(2);
      reg.cancel(tok);
      expect(reg.pendingCancelCount, equals(1));
      final h = reg.register(tok);
      expect(
        h.isCancelled,
        isTrue,
        reason: 'register must consume the pending cancel',
      );
      expect(reg.pendingCancelCount, equals(0));
    });

    test(
      'throwIfCancelled raises IsolateCancellationException with the token',
      () {
        final reg = IsolateCancellationRegistry();
        final tok = const IsolateCancellationToken(3);
        final h = reg.register(tok);
        h.throwIfCancelled(); // does nothing
        reg.cancel(tok);
        expect(
          h.throwIfCancelled,
          throwsA(
            isA<IsolateCancellationException>().having(
              (e) => e.token.id,
              'token.id',
              3,
            ),
          ),
        );
      },
    );

    test('cancelled future completes when the request is cancelled', () async {
      final reg = IsolateCancellationRegistry();
      final tok = const IsolateCancellationToken(99);
      final h = reg.register(tok);
      var fired = false;
      unawaited(h.cancelled.then((_) => fired = true));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(fired, isFalse);
      reg.cancel(tok);
      await h.cancelled;
      expect(fired, isTrue);
    });

    test('dispose is idempotent and unregisters', () {
      final reg = IsolateCancellationRegistry();
      final tok = const IsolateCancellationToken(4);
      final h = reg.register(tok);
      expect(reg.inFlightCount, equals(1));
      h.dispose();
      expect(reg.inFlightCount, equals(0));
      h.dispose(); // idempotent
      expect(reg.inFlightCount, equals(0));
    });

    test('cancel on unknown then register elsewhere does not leak', () {
      final reg = IsolateCancellationRegistry();
      reg.cancel(const IsolateCancellationToken(10));
      reg.cancel(const IsolateCancellationToken(11));
      expect(reg.pendingCancelCount, equals(2));
      reg.register(const IsolateCancellationToken(10));
      expect(reg.pendingCancelCount, equals(1));
    });

    // A cancel that arrives *after* the request closed (register → dispose →
    // cancel) reaches the same "unknown token" branch as a pre-open cancel, and
    // a registry that treats the branch as one case remembers it in
    // _pendingCancellations forever — a token is never recycled, so that entry
    // can never be consumed by a later register. The post-close cancel must be
    // dropped instead of leaking.
    test('cancel after dispose is dropped, not leaked', () {
      final reg = IsolateCancellationRegistry();
      final tok = const IsolateCancellationToken(1);
      final h = reg.register(tok);
      h.dispose();
      expect(reg.inFlightCount, equals(0));
      reg.cancel(tok); // late, post-close cancel for a completed request
      expect(
        reg.pendingCancelCount,
        equals(0),
        reason: 'a post-close cancel must not accumulate in pending',
      );
      // False here is a *consequence* of the narrowed registry contract,
      // not an independent intention: the registry answers only for tokens
      // it currently holds, and this one was disposed. See the pair of
      // scope tests below for the contract itself.
      expect(reg.isCancelled(tok), isFalse);
    });

    // What the discriminator rests on, and what happens when it does not hold.
    //
    // The high-water mark can tell a pre-open cancel from a post-close one
    // only while ids reach `register` strictly increasing — which is true of a
    // single host allocator over an ordered transport, and of nothing else.
    // Break it and a genuine pre-open cancel for a low id is read as
    // post-close and dropped: the request then runs to completion having been
    // cancelled, with no error anywhere. The two tests above both stay inside
    // the precondition, so neither would notice.
    group('the discriminator precondition', () {
      test('an out-of-order register is refused, not silently mis-read', () {
        final reg = IsolateCancellationRegistry();
        reg.register(const IsolateCancellationToken(5));

        expect(
          () => reg.register(const IsolateCancellationToken(3)),
          throwsA(isA<AssertionError>()),
          reason:
              'id 3 after id 5 means two allocators or a reordering '
              'transport, and the registry cannot discriminate under either',
        );
      });

      test('two allocators into one registry are refused', () {
        // The shape the module's own header invites: it offers itself as the
        // generic core for "any isolate adapter", and nothing stops an adapter
        // from constructing a second allocator. Both hand out 1, 2, 3 …
        final reg = IsolateCancellationRegistry();
        final first = IsolateCancellationTokenAllocator();
        final second = IsolateCancellationTokenAllocator();

        reg.register(first.next()); // id 1
        reg.register(first.next()); // id 2
        expect(
          () => reg.register(second.next()), // id 1 again
          throwsA(isA<AssertionError>()),
        );
      });

      test('the silent mis-read is what the refusal replaces', () {
        // The failure the assert exists for, demonstrated on the branch that
        // does *not* go through `register`: a genuine pre-open cancel for an
        // id below the mark is dropped, because from the registry's side it is
        // indistinguishable from a cancel for a request that already closed.
        // Nothing here throws — that is the point.
        final reg = IsolateCancellationRegistry();
        reg.register(const IsolateCancellationToken(5));

        reg.cancel(const IsolateCancellationToken(3));

        expect(
          reg.pendingCancelCount,
          equals(0),
          reason:
              'the cancel was dropped as post-close, so the register that '
              'follows would hand back an uncancelled handle',
        );
      });

      test('the ordinary in-order sequence is unaffected', () {
        // The control. An assert that also refused the normal path would be
        // worse than none, and this is the path every adapter takes.
        final reg = IsolateCancellationRegistry();
        final allocator = IsolateCancellationTokenAllocator();
        final tokens = [for (var i = 0; i < 5; i++) allocator.next()];

        for (final token in tokens) {
          reg.register(token).dispose();
        }
        expect(reg.inFlightCount, equals(0));

        // Including the pre-open cancel it is all for: a cancel above the mark
        // is remembered and consumed by the register that follows it.
        final next = allocator.next();
        reg.cancel(next);
        expect(reg.register(next).isCancelled, isTrue);
      });
    });

    // The registry's isCancelled is scoped to what it currently holds: the
    // in-flight entries plus the remembered pre-open cancels. It is *not* a
    // durable record of "was this ever cancelled" — keeping one would mean
    // accumulating cancelled-and-closed ids for the executor's whole life,
    // since ids are never recycled, which is the same leak the post-close
    // drop above exists to avoid. The handle is the durable side.
    test('registry isCancelled is scoped to the registration window', () {
      final reg = IsolateCancellationRegistry();
      final tok = const IsolateCancellationToken(5);

      final h = reg.register(tok);
      reg.cancel(tok);
      expect(h.isCancelled, isTrue);
      expect(
        reg.isCancelled(tok),
        isTrue,
        reason: 'inside the window the two sides agree',
      );

      h.dispose();
      expect(
        reg.isCancelled(tok),
        isFalse,
        reason: 'the registry holds in-flight state only',
      );
      expect(
        h.isCancelled,
        isTrue,
        reason: 'the handle keeps the answer for its own request',
      );
      expect(
        h.throwIfCancelled,
        throwsA(isA<IsolateCancellationException>()),
        reason: 'so a post-dispose checkpoint still refuses to proceed',
      );
    });

    test('a remembered pre-open cancel is inside the window', () {
      final reg = IsolateCancellationRegistry();
      final tok = const IsolateCancellationToken(6);
      reg.cancel(tok);
      expect(
        reg.isCancelled(tok),
        isTrue,
        reason: 'pending cancels count as held, so register can consume it',
      );
    });

    test('a pre-open cancel is still remembered after an earlier request closed'
        ' (the high-water discriminator)', () {
      // Earlier request (id 1) completes; a genuine pre-open cancel for a newer
      // token (id 2, never registered) must still be remembered — the drop only
      // applies to ids that already passed through the registry.
      final reg = IsolateCancellationRegistry();
      reg.register(const IsolateCancellationToken(1)).dispose();
      reg.cancel(const IsolateCancellationToken(2));
      expect(reg.pendingCancelCount, equals(1));
      final h = reg.register(const IsolateCancellationToken(2));
      expect(h.isCancelled, isTrue);
      expect(reg.pendingCancelCount, equals(0));
    });
  });

  group('IsolateCancellationToken / allocator', () {
    test('value equality keys off the id', () {
      expect(
        const IsolateCancellationToken(7),
        equals(const IsolateCancellationToken(7)),
      );
      expect(
        const IsolateCancellationToken(7),
        isNot(equals(const IsolateCancellationToken(8))),
      );
      expect(
        const IsolateCancellationToken(7).hashCode,
        equals(const IsolateCancellationToken(7).hashCode),
      );
    });

    test('allocator hands out monotonic ids', () {
      final a = IsolateCancellationTokenAllocator();
      expect(a.next().id, equals(1));
      expect(a.next().id, equals(2));
      expect(a.peekNext, equals(3));
    });
  });

  // Which members of the family may cross an isolate boundary is the load-
  // bearing fact of this module's design: the token is an id precisely so the
  // state can stay in the executor's isolate. It was asserted nowhere, and the
  // module guide and example consequently described the opposite arrangement
  // for some time — registry on the host, handle shipped to the worker — which
  // reads plausibly and throws on the first send. These tests make the split a
  // checked property rather than a claim in prose.
  group('sendability across an isolate boundary', () {
    late ReceivePort port;

    setUp(() => port = ReceivePort());
    tearDown(() => port.close());

    test('a token crosses — it is a single-integer value type', () {
      expect(
        () => port.sendPort.send(const IsolateCancellationToken(1)),
        returnsNormally,
      );
    });

    test('a handle does not cross — it holds a Completer', () {
      final handle = IsolateCancellationRegistry().register(
        const IsolateCancellationToken(1),
      );
      expect(() => port.sendPort.send(handle), throwsArgumentError);
    });

    test('a registry does not cross — its entries hold Completers', () {
      final registry = IsolateCancellationRegistry()
        ..register(const IsolateCancellationToken(1));
      expect(() => port.sendPort.send(registry), throwsArgumentError);
    });

    test('a close signal does not cross — it holds a Completer', () {
      expect(
        () => port.sendPort.send(IsolateStreamCloseSignal()),
        throwsArgumentError,
      );
    });
  });

  group('BackpressureTracker', () {
    test('rejects negative initial credits', () {
      expect(
        () => BackpressureTracker(initialCredits: -1),
        throwsArgumentError,
      );
    });

    test('awaitCredit returns immediately when credits > 0', () async {
      final t = BackpressureTracker(initialCredits: 3);
      await t.awaitCredit();
      expect(t.credits, equals(3));
      t.consume();
      expect(t.credits, equals(2));
    });

    test('awaitCredit parks at zero and unblocks on grant', () async {
      final t = BackpressureTracker(initialCredits: 1);
      t.consume();
      expect(t.credits, equals(0));
      var unblocked = false;
      final f = t.awaitCredit().then((_) => unblocked = true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(unblocked, isFalse);
      expect(t.waiterCount, equals(1));
      t.grant(1);
      await f;
      expect(unblocked, isTrue);
      expect(t.waiterCount, equals(0));
    });

    test('grant wakes parked waiters in FIFO order', () async {
      final t = BackpressureTracker(initialCredits: 0);
      final order = <int>[];
      final f1 = t.awaitCredit().then((_) => order.add(1));
      final f2 = t.awaitCredit().then((_) => order.add(2));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(t.waiterCount, equals(2));
      t.grant(2);
      await Future.wait([f1, f2]);
      expect(order, equals(<int>[1, 2]));
      expect(t.waiterCount, equals(0));
    });

    // grant(n) must release at most n waiters, and the loop condition that
    // looks right does not enforce it: `while (waiters.isNotEmpty && _credits >
    // 0)` with no per-wake decrement. Waking does not itself consume a credit
    // (the producer consumes after pushing), so a single grant wakes *every*
    // parked waiter; n+1 producers then push against only n credits and
    // consume() cascades StateErrors.
    test('grant(1) wakes exactly one of three parked waiters', () async {
      final t = BackpressureTracker(initialCredits: 0);
      var woken = 0;
      final f1 = t.awaitCredit().then((_) => woken++);
      final f2 = t.awaitCredit().then((_) => woken++);
      final f3 = t.awaitCredit().then((_) => woken++);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(t.waiterCount, equals(3));
      t.grant(1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // Exactly one waiter wakes; the other two stay parked.
      expect(woken, equals(1));
      expect(t.waiterCount, equals(2));
      // The leftover credit is one, claimable by the woken producer.
      expect(t.credits, equals(1));
      // Draining the rest so no future completes after the test ends.
      t.grant(2);
      await Future.wait([f1, f2, f3]);
    });

    test('consume rejects negative and over-consume', () {
      final t = BackpressureTracker(initialCredits: 1);
      expect(() => t.consume(-1), throwsArgumentError);
      expect(() => t.consume(2), throwsStateError);
    });

    test('grant rejects non-positive', () {
      final t = BackpressureTracker(initialCredits: 1);
      expect(() => t.grant(0), throwsArgumentError);
      expect(() => t.grant(-1), throwsArgumentError);
    });

    test('close fails parked waiters and rejects later awaitCredit', () async {
      final t = BackpressureTracker(initialCredits: 0);
      final f = t.awaitCredit();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      t.close();
      expect(t.isClosed, isTrue);
      await expectLater(f, throwsStateError);
      await expectLater(t.awaitCredit(), throwsStateError);
    });

    // Closing stops the ledger accounting, it does not stop the ledger
    // checking its arguments. Returning on the closed flag *before*
    // validating is the natural shape and the wrong one: grant(0) then
    // throws while open and passes in silence once closed — the same call,
    // two answers, decided by state the caller may not know. A nonsensical
    // n is a caller bug either way.
    test('argument validation survives close', () {
      final t = BackpressureTracker(initialCredits: 1)..close();
      expect(() => t.grant(0), throwsArgumentError);
      expect(() => t.grant(-1), throwsArgumentError);
      expect(() => t.consume(-1), throwsArgumentError);
    });

    // The other half: state-dependent effects *are* skipped once closed,
    // and both mutators must skip them the same way. A consume with no closed
    // check keeps drawing down a ledger nobody is keeping.
    test('grant and consume are no-ops once closed', () {
      final t = BackpressureTracker(initialCredits: 3)..close();
      t.grant(5);
      expect(t.credits, equals(3), reason: 'a closed ledger takes no credit');
      t.consume(2);
      expect(t.credits, equals(3), reason: 'and spends none');
    });

    // Why consume no-ops rather than throwing: a producer is routinely
    // mid-iteration when the close lands — past awaitCredit, chunk already
    // pushed, consume not yet called. Throwing there would raise from the
    // loop body rather than at awaitCredit, which is the one place callers
    // handle the unwind. (tom_brain_memory's producer catches StateError
    // around awaitCredit only; a throwing consume would land in its generic
    // catch and report a clean close to the host as a stream error.)
    test('a closed over-consume does not throw', () {
      final t = BackpressureTracker(initialCredits: 0)..close();
      expect(
        () => t.consume(2),
        returnsNormally,
        reason: 'the over-consume guard describes a live balance',
      );
    });

    test('the unwind still arrives at the next awaitCredit', () async {
      final t = BackpressureTracker(initialCredits: 1);
      await t.awaitCredit();
      t.close(); // as if a close envelope landed before the chunk settled
      t.consume(); // trailing bookkeeping: silent
      await expectLater(
        t.awaitCredit(),
        throwsStateError,
        reason: 'the producer unwinds at its control-flow point, not here',
      );
    });
  });

  group('IsolateStreamCloseSignal', () {
    test('requestClose raises the flag and fires the signal', () async {
      final s = IsolateStreamCloseSignal();
      expect(s.closeRequested, isFalse);
      expect(s.closeSignal.isCompleted, isFalse);
      s.requestClose();
      expect(s.closeRequested, isTrue);
      await s.closeSignal.future; // completes
      expect(s.closeSignal.isCompleted, isTrue);
    });

    test('requestClose is idempotent', () {
      final s = IsolateStreamCloseSignal();
      s.requestClose();
      s.requestClose(); // must not throw on the already-completed signal
      expect(s.closeRequested, isTrue);
      expect(s.closeSignal.isCompleted, isTrue);
    });
  });
}

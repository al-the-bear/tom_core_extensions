// Domain-free wall-clock deadline (G-C3).
//
// `Deadline` is the wall-clock-budget primitive an agent's creation loop uses
// to bound each iteration: an iteration that outlives its budget is aborted
// rather than left to run, so a loop that will not converge costs a bounded
// amount of time instead of an unbounded one. It is domain-free and driven by
// an injectable clock so the loop, and any other timed agent runtime, can share
// one expiry rule under deterministic tests.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('Deadline', () {
    DateTime t(int ms) =>
        DateTime.utc(2026, 1, 1).add(Duration(milliseconds: ms));

    test('startingNow sets expiry to now + budget', () {
      var nowMs = 0;
      final d = Deadline.startingNow(
        const Duration(milliseconds: 500),
        clock: () => t(nowMs),
      );
      expect(d.expiresAt, t(500));
    });

    test('is not expired before the budget elapses', () {
      var nowMs = 0;
      final d = Deadline.startingNow(
        const Duration(milliseconds: 500),
        clock: () => t(nowMs),
      );
      nowMs = 499;
      expect(d.isExpired, isFalse);
      expect(d.remaining, const Duration(milliseconds: 1));
    });

    test('is expired exactly at the deadline instant', () {
      var nowMs = 0;
      final d = Deadline.startingNow(
        const Duration(milliseconds: 500),
        clock: () => t(nowMs),
      );
      nowMs = 500;
      expect(d.isExpired, isTrue);
      expect(d.remaining, Duration.zero);
    });

    test('clamps remaining to zero after expiry', () {
      var nowMs = 0;
      final d = Deadline.startingNow(
        const Duration(milliseconds: 100),
        clock: () => t(nowMs),
      );
      nowMs = 999;
      expect(d.remaining, Duration.zero);
    });

    test('throwIfExpired stays silent before expiry and throws after', () {
      var nowMs = 0;
      final d = Deadline.startingNow(
        const Duration(milliseconds: 100),
        clock: () => t(nowMs),
      );
      expect(d.throwIfExpired, returnsNormally);
      nowMs = 100;
      expect(d.throwIfExpired, throwsA(isA<DeadlineExceeded>()));
    });

    test('Deadline.at accepts a pre-computed expiry', () {
      var nowMs = 0;
      final d = Deadline.at(t(200), clock: () => t(nowMs));
      expect(d.isExpired, isFalse);
      nowMs = 200;
      expect(d.isExpired, isTrue);
    });
  });
}

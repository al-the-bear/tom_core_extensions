import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('TokenBucketPolicy', () {
    test('rejects a capacity below 1', () {
      expect(
        () => TokenBucketPolicy(
          capacity: 0,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a non-positive refill rate', () {
      expect(
        () => TokenBucketPolicy(
          capacity: 1,
          refillTokens: 0,
          refillPeriod: const Duration(seconds: 1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a non-positive refill period', () {
      expect(
        () => TokenBucketPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: Duration.zero,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('TokenBucket', () {
    late DateTime now;
    TokenBucket bucketWith(TokenBucketPolicy policy) =>
        TokenBucket(policy: policy, clock: () => now);

    setUp(() => now = DateTime.utc(2026, 1, 1));

    test('a fresh bucket starts full at capacity', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 3,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
      );
      expect(bucket.tryTake('p'), isNull);
      expect(bucket.tryTake('p'), isNull);
      expect(bucket.tryTake('p'), isNull);
      // Fourth take exhausts the bucket.
      expect(bucket.tryTake('p'), isNotNull);
    });

    test('returns the wait until one token refills when empty', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 10),
        ),
      );
      expect(bucket.tryTake('p'), isNull);
      final wait = bucket.tryTake('p');
      expect(wait, const Duration(seconds: 10));
    });

    test('refills continuously over elapsed wall-clock time', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 2,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
      );
      expect(bucket.tryTake('p'), isNull);
      expect(bucket.tryTake('p'), isNull);
      expect(bucket.tryTake('p'), isNotNull); // empty
      now = now.add(const Duration(seconds: 1)); // one token refilled
      expect(bucket.tryTake('p'), isNull);
    });

    test('a rejected take does not push the retry window further out', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 4),
        ),
      );
      expect(bucket.tryTake('p'), isNull);
      final first = bucket.tryTake('p')!;
      final second = bucket.tryTake('p')!;
      expect(second, lessThanOrEqualTo(first));
    });

    test('keys are independent', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
      );
      expect(bucket.tryTake('a'), isNull);
      expect(bucket.tryTake('b'), isNull); // b has its own full bucket
      expect(bucket.keyCount, 2);
    });

    test('rejects an empty key', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
      );
      expect(() => bucket.tryTake(''), throwsA(isA<ArgumentError>()));
    });

    test('clear resets every bucket to full', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
      );
      expect(bucket.tryTake('p'), isNull);
      expect(bucket.tryTake('p'), isNotNull);
      bucket.clear();
      expect(bucket.keyCount, 0);
      expect(bucket.tryTake('p'), isNull);
    });

    test('a backwards clock does not credit the bucket', () {
      final bucket = bucketWith(
        TokenBucketPolicy(
          capacity: 2,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
      );
      expect(bucket.tryTake('p'), isNull);
      expect(bucket.tryTake('p'), isNull); // empty
      now = now.subtract(const Duration(seconds: 100)); // clock jumps back
      expect(bucket.tryTake('p'), isNotNull); // still empty, no future credit
    });
  });

  group('TokenBucket snapshot/restore', () {
    late DateTime now;
    TokenBucket bucketWith(TokenBucketPolicy policy) =>
        TokenBucket(policy: policy, clock: () => now);
    TokenBucketPolicy policy() => TokenBucketPolicy(
      capacity: 3,
      refillTokens: 1,
      refillPeriod: const Duration(seconds: 1),
    );

    setUp(() => now = DateTime.utc(2026, 1, 1));

    test('snapshot() is empty for an untouched bucket', () {
      expect(bucketWith(policy()).snapshot(), isEmpty);
    });

    test('snapshot() captures the current count and last-refill per key', () {
      final bucket = bucketWith(policy());
      bucket.tryTake('a'); // a: 2 tokens left
      bucket.tryTake('a'); // a: 1 token left
      bucket.tryTake('b'); // b: 2 tokens left

      final snap = bucket.snapshot();
      expect(snap.keys.toSet(), {'a', 'b'});
      expect(snap['a']!.tokens, 1.0);
      expect(snap['a']!.lastRefill, now);
      expect(snap['b']!.tokens, 2.0);
    });

    test('snapshotOf() returns one key, or null when unseen', () {
      final bucket = bucketWith(policy());
      bucket.tryTake('a');
      expect(bucket.snapshotOf('a')!.tokens, 2.0);
      expect(bucket.snapshotOf('missing'), isNull);
    });

    test('restore() seeds state a fresh bucket resumes from', () {
      final source = bucketWith(policy());
      source.tryTake('p'); // 2 left
      source.tryTake('p'); // 1 left
      source.tryTake('p'); // 0 left — empty
      final snap = source.snapshot();

      // A brand-new bucket (as after a restart) restored from the snapshot.
      final restored = bucketWith(policy());
      restored.restore(snap);
      // At the same instant the restored bucket is empty, not fresh-full.
      expect(restored.tryTake('p'), isNotNull);
    });

    test('restore() lets elapsed downtime refill the bucket lazily', () {
      final source = bucketWith(policy());
      source.tryTake('p');
      source.tryTake('p');
      source.tryTake('p'); // empty at t0
      final snap = source.snapshot();

      final restored = bucketWith(policy());
      restored.restore(snap);
      // Two seconds of "downtime" pass before the next take: two tokens refill.
      now = now.add(const Duration(seconds: 2));
      expect(restored.tryTake('p'), isNull);
      expect(restored.tryTake('p'), isNull);
      expect(restored.tryTake('p'), isNotNull); // only two had refilled
    });

    test('restore() clamps tokens to the current capacity', () {
      final restored = bucketWith(policy()); // capacity 3
      restored.restore({'p': TokenBucketSnapshot(tokens: 99, lastRefill: now)});
      // Capacity is 3, so at most three immediate takes despite the bloated
      // snapshot.
      expect(restored.tryTake('p'), isNull);
      expect(restored.tryTake('p'), isNull);
      expect(restored.tryTake('p'), isNull);
      expect(restored.tryTake('p'), isNotNull);
    });

    test('restore() rejects an empty key', () {
      final bucket = bucketWith(policy());
      expect(
        () => bucket.restore({
          '': TokenBucketSnapshot(tokens: 1, lastRefill: now),
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TokenBucketSnapshot value equality is by moment, not zone', () {
      final utc = DateTime.utc(2026, 1, 1, 12);
      final a = TokenBucketSnapshot(tokens: 1.5, lastRefill: utc);
      final b = TokenBucketSnapshot(tokens: 1.5, lastRefill: utc.toLocal());
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('nearestRankPercentile (int millis)', () {
    final List<int> tenAscending = <int>[
      for (int ms = 10; ms <= 100; ms += 10) ms,
    ];

    test('p50 of 10 ascending samples is the 5th (nearest-rank)', () {
      expect(nearestRankPercentile(tenAscending, 0.50), 50);
    });

    test('p95 of 10 ascending samples is the 10th (nearest-rank)', () {
      expect(nearestRankPercentile(tenAscending, 0.95), 100);
    });

    test('single sample returns itself for any quantile', () {
      expect(nearestRankPercentile(<int>[7], 0.50), 7);
      expect(nearestRankPercentile(<int>[7], 0.95), 7);
    });

    test('q = 0 returns the smallest sample', () {
      expect(nearestRankPercentile(tenAscending, 0), 10);
    });

    test('empty list throws ArgumentError', () {
      expect(() => nearestRankPercentile(<int>[], 0.5), throwsArgumentError);
    });

    test('out-of-range quantile throws ArgumentError', () {
      expect(
        () => nearestRankPercentile(tenAscending, 1.5),
        throwsArgumentError,
      );
    });
  });

  group('percentileDuration (nearest-rank)', () {
    // Ten samples, 10 ms … 100 ms, already ascending.
    final List<Duration> tenAscending = <Duration>[
      for (int ms = 10; ms <= 100; ms += 10) Duration(milliseconds: ms),
    ];

    test('p50 of 10 ascending samples is the 5th (nearest-rank)', () {
      // rank = ceil(0.50 · 10) = 5 ⇒ index 4 ⇒ 50 ms.
      expect(
        percentileDuration(tenAscending, 0.50),
        const Duration(milliseconds: 50),
      );
    });

    test('p95 of 10 ascending samples is the 10th (nearest-rank)', () {
      // rank = ceil(0.95 · 10) = 10 ⇒ index 9 ⇒ 100 ms.
      expect(
        percentileDuration(tenAscending, 0.95),
        const Duration(milliseconds: 100),
      );
    });

    test('p0 clamps to the smallest, p100 to the largest', () {
      expect(
        percentileDuration(tenAscending, 0.0),
        const Duration(milliseconds: 10),
      );
      expect(
        percentileDuration(tenAscending, 1.0),
        const Duration(milliseconds: 100),
      );
    });

    test('a single-sample list returns that sample for any quantile', () {
      final List<Duration> one = <Duration>[const Duration(milliseconds: 7)];
      expect(percentileDuration(one, 0.0), const Duration(milliseconds: 7));
      expect(percentileDuration(one, 0.5), const Duration(milliseconds: 7));
      expect(percentileDuration(one, 0.95), const Duration(milliseconds: 7));
    });

    test('an empty list is a programming error', () {
      expect(
        () => percentileDuration(<Duration>[], 0.5),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a quantile outside [0, 1] is rejected', () {
      expect(
        () => percentileDuration(tenAscending, 1.5),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => percentileDuration(tenAscending, -0.1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('LatencySummary.fromSamples', () {
    test(
      'computes count/min/max/p50/p95 and leaves the caller list unsorted',
      () {
        // Deliberately unsorted on input.
        final List<Duration> samples = <Duration>[
          const Duration(milliseconds: 30),
          const Duration(milliseconds: 10),
          const Duration(milliseconds: 50),
          const Duration(milliseconds: 20),
          const Duration(milliseconds: 40),
        ];
        final List<Duration> original = List<Duration>.of(samples);

        final LatencySummary summary = LatencySummary.fromSamples(samples);

        expect(summary.sampleCount, 5);
        expect(summary.min, const Duration(milliseconds: 10));
        expect(summary.max, const Duration(milliseconds: 50));
        // rank = ceil(0.50 · 5) = 3 ⇒ index 2 ⇒ 30 ms (sorted).
        expect(summary.p50, const Duration(milliseconds: 30));
        // rank = ceil(0.95 · 5) = 5 ⇒ index 4 ⇒ 50 ms.
        expect(summary.p95, const Duration(milliseconds: 50));
        // The caller's list is untouched (a copy was sorted).
        expect(samples, original);
      },
    );

    test('an empty sample set is rejected', () {
      expect(
        () => LatencySummary.fromSamples(<Duration>[]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('meetsTarget gates on p95 against the supplied target', () {
      const LatencySummary within = LatencySummary(
        sampleCount: 3,
        min: Duration(milliseconds: 5),
        max: Duration(milliseconds: 200),
        p50: Duration(milliseconds: 50),
        p95: Duration(milliseconds: 200),
      );
      const LatencySummary over = LatencySummary(
        sampleCount: 3,
        min: Duration(milliseconds: 5),
        max: Duration(milliseconds: 300),
        p50: Duration(milliseconds: 50),
        p95: Duration(milliseconds: 300),
      );
      expect(within.meetsTarget(const Duration(milliseconds: 250)), isTrue);
      expect(over.meetsTarget(const Duration(milliseconds: 250)), isFalse);
      // The threshold is the caller's, not the type's.
      expect(within.meetsTarget(const Duration(milliseconds: 100)), isFalse);
    });
  });
}

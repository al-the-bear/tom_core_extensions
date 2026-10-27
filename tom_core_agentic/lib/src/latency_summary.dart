// Nearest-rank percentile maths and an immutable latency summary.
//
// Any latency bench, recall-latency tracker, or histogram in the workspace
// needs the same two operations: take a quantile of a sorted sample set, and
// fold a raw sample list into a count/min/max/p50/p95 summary. This is that,
// with exactly one definition — domain-free over `Duration` samples, so the
// brain's process bench and any future agent bench share it rather than
// re-deriving the maths (and drifting on the off-by-one that nearest-rank
// invites).

/// The nearest-rank percentile of [sorted] (which MUST already be ascending),
/// for a quantile [q] in `[0, 1]`.
///
/// Uses the nearest-rank method: `rank = ceil(q · n)` (at least 1), the sample
/// at index `rank − 1`, clamped into range. For `n = 50`, `q = 0.95` ⇒ rank 48
/// ⇒ the 48th-smallest sample. `q = 0` returns the smallest sample, `q = 1` the
/// largest. An empty list is a programming error (a sample set with no members
/// has nothing to summarise) and throws [ArgumentError]; a [q] outside `[0, 1]`
/// is likewise rejected.
Duration percentileDuration(List<Duration> sorted, double q) {
  if (sorted.isEmpty) {
    throw ArgumentError.value(sorted, 'sorted', 'must be non-empty');
  }
  if (q < 0 || q > 1) {
    throw ArgumentError.value(q, 'q', 'must be within [0, 1]');
  }
  final int n = sorted.length;
  // rank = ceil(q · n), at least 1; index = rank − 1, clamped to the last slot.
  final int rank = (q * n).ceil();
  final int index = (rank < 1 ? 1 : rank) - 1;
  final int clamped = index < 0
      ? 0
      : index > n - 1
      ? n - 1
      : index;
  return sorted[clamped];
}

/// The nearest-rank percentile of [sortedAsc] (which MUST already be
/// ascending) for a quantile [q] in `[0, 1]`, over integer samples.
///
/// The integer-millisecond counterpart of [percentileDuration]: trackers
/// that buffer raw millisecond counts (rather than [Duration]s) share the
/// same nearest-rank maths without boxing every sample into a [Duration].
/// Same contract: `rank = ceil(q · n)` (at least 1), sample at index
/// `rank − 1` clamped into range. An empty list throws [ArgumentError];
/// a [q] outside `[0, 1]` is rejected.
int nearestRankPercentile(List<int> sortedAsc, double q) {
  if (sortedAsc.isEmpty) {
    throw ArgumentError.value(sortedAsc, 'sortedAsc', 'must be non-empty');
  }
  if (q < 0 || q > 1) {
    throw ArgumentError.value(q, 'q', 'must be within [0, 1]');
  }
  final int n = sortedAsc.length;
  final int rank = (q * n).ceil();
  final int index = (rank < 1 ? 1 : rank) - 1;
  final int clamped = index < 0
      ? 0
      : index > n - 1
      ? n - 1
      : index;
  return sortedAsc[clamped];
}

/// An immutable summary of a set of latency samples — count, min/max, p50, p95.
///
/// Built from raw samples via [LatencySummary.fromSamples], which sorts a copy
/// (the caller's list is left untouched) and computes the percentiles with
/// [percentileDuration]. Domain-free: it carries no notion of a pass threshold;
/// callers supply their own target to [meetsTarget].
final class LatencySummary {
  /// Number of samples the summary was computed from.
  final int sampleCount;

  /// The smallest sample.
  final Duration min;

  /// The largest sample.
  final Duration max;

  /// The 50th-percentile (median) sample.
  final Duration p50;

  /// The 95th-percentile sample.
  final Duration p95;

  const LatencySummary({
    required this.sampleCount,
    required this.min,
    required this.max,
    required this.p50,
    required this.p95,
  });

  /// Summarises [samples]. The list MUST be non-empty; a copy is sorted so the
  /// caller's list is left in its original order.
  factory LatencySummary.fromSamples(List<Duration> samples) {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'must be non-empty');
    }
    final List<Duration> sorted = List<Duration>.of(samples)..sort();
    return LatencySummary(
      sampleCount: sorted.length,
      min: sorted.first,
      max: sorted.last,
      p50: percentileDuration(sorted, 0.50),
      p95: percentileDuration(sorted, 0.95),
    );
  }

  /// Whether the p95 sample is within [target] — the caller's pass condition.
  ///
  /// The target is required: this type is domain-free and has no default
  /// threshold of its own. A bench that gates on a fixed figure passes its own
  /// constant here.
  bool meetsTarget(Duration target) => p95 <= target;
}

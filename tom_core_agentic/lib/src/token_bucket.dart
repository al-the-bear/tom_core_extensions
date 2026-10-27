// Continuous-refill token bucket — a domain-free throttle primitive.
//
// A textbook fractional token bucket keyed by an arbitrary string. Each
// key owns a bucket of [TokenBucketPolicy.capacity] tokens (the burst
// allowance); one [TokenBucket.tryTake] consumes one token. Tokens refill
// continuously at [TokenBucketPolicy.refillTokens] per
// [TokenBucketPolicy.refillPeriod], capped at [capacity]. The refill is
// computed lazily from wall-clock elapsed since the bucket was last
// touched — there is no background timer, so an idle key costs nothing and
// a long-unseen bucket is simply full again on its next use.
//
// This is the mechanism only. It returns *how long* a rejected caller must
// wait rather than throwing a domain exception, so a rate limiter, a quota,
// or any other throttle can wrap it and map the wait onto its own failure
// shape. Time is read through an injectable clock for deterministic tests.

import 'argument_guards.dart';
import 'system_clock.dart';

/// Immutable configuration of a [TokenBucket].
///
/// A bucket holds at most [capacity] tokens (the burst allowance) and
/// refills [refillTokens] tokens every [refillPeriod]. One take costs one
/// token, so the sustained rate is `refillTokens / refillPeriod` takes and
/// the instantaneous burst is [capacity] takes.
final class TokenBucketPolicy {
  /// Maximum number of tokens a bucket can hold — the burst allowance. A
  /// fresh bucket starts full at [capacity]. Must be `>= 1`.
  final int capacity;

  /// Number of tokens added to a bucket every [refillPeriod]. Must be `> 0`
  /// so a bucket always eventually refills (a non-refilling bucket would
  /// make the wait until a token undefined).
  final double refillTokens;

  /// The wall-clock window over which [refillTokens] are added. Must be a
  /// strictly positive duration.
  final Duration refillPeriod;

  /// Builds a policy. [capacity] must be `>= 1`, [refillTokens] must be
  /// `> 0`, and [refillPeriod] must be strictly positive.
  TokenBucketPolicy({
    required this.capacity,
    required this.refillTokens,
    required this.refillPeriod,
  }) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be >= 1');
    }
    if (refillTokens <= 0) {
      throw ArgumentError.value(refillTokens, 'refillTokens', 'must be > 0');
    }
    if (refillPeriod <= Duration.zero) {
      throw ArgumentError.value(
        refillPeriod,
        'refillPeriod',
        'must be a strictly positive duration',
      );
    }
  }

  /// Tokens replenished per microsecond — the continuous refill rate used
  /// by the lazy refill computation. Derived once from [refillTokens] and
  /// [refillPeriod].
  double get tokensPerMicrosecond => refillTokens / refillPeriod.inMicroseconds;
}

/// Mutable per-key bucket state: the current (fractional) token count and
/// the wall-clock instant it was last refilled.
class _BucketState {
  double tokens;
  DateTime lastRefill;

  _BucketState(this.tokens, this.lastRefill);
}

/// Immutable snapshot of one key's bucket state — the persistable form.
///
/// Captures exactly what the lazy refill needs to resume a bucket after a
/// process restart: the (fractional) [tokens] it held and the [lastRefill]
/// instant they were computed at. Because refill is computed lazily from the
/// wall-clock elapsed since [lastRefill], a snapshot restored after downtime
/// naturally credits the idle time on its next take — there is no separate
/// "catch-up" step. A caller persists these (via [TokenBucket.snapshot] /
/// [TokenBucket.snapshotOf]) and seeds them back with [TokenBucket.restore].
final class TokenBucketSnapshot {
  /// The fractional token count the bucket held at [lastRefill].
  final double tokens;

  /// The wall-clock instant [tokens] was last computed at.
  final DateTime lastRefill;

  /// Builds a snapshot of [tokens] held at [lastRefill].
  const TokenBucketSnapshot({required this.tokens, required this.lastRefill});

  @override
  bool operator ==(Object other) =>
      other is TokenBucketSnapshot &&
      other.tokens == tokens &&
      other.lastRefill.isAtSameMomentAs(lastRefill);

  @override
  int get hashCode => Object.hash(tokens, lastRefill.microsecondsSinceEpoch);

  @override
  String toString() =>
      'TokenBucketSnapshot(tokens: $tokens, lastRefill: $lastRefill)';
}

/// A keyed continuous-refill token bucket.
///
/// One bucket per key, created full on first sight and held for the
/// instance's lifetime. Call [tryTake] once per event: it returns `null`
/// when the bucket could afford the token (and consumes it), or the
/// [Duration] until one token will have refilled when it could not (and
/// charges nothing, so a rejected caller does not push its own retry
/// window further out).
///
/// Stateful (it owns the bucket map) but otherwise self-contained: no
/// timer, no I/O. Buckets are created lazily and not evicted; a caller
/// that needs idle eviction can read [keyCount] and call [clear] (or evict
/// externally). The key space is the caller's responsibility — key on a
/// bounded, non-secret identifier.
final class TokenBucket {
  /// The policy applied to every key.
  final TokenBucketPolicy policy;

  /// Time source. Defaults to [systemClock]; tests pass a controllable
  /// clock for deterministic refill.
  final DateTime Function() clock;

  final Map<String, _BucketState> _buckets = {};

  /// Builds a bucket set over [policy]. [clock] defaults to [systemClock].
  TokenBucket({required this.policy, DateTime Function()? clock})
    : clock = clock ?? systemClock;

  /// Number of keys with live bucket state — for observability and as the
  /// seam an external eviction policy reads.
  int get keyCount => _buckets.length;

  /// Drops all bucket state. Every key is full again on its next [tryTake].
  void clear() => _buckets.clear();

  /// Snapshot of every live bucket, keyed by the same key — the durable form.
  ///
  /// A caller persists these and restores them with [restore] after a process
  /// restart, so a long-horizon throttle layered on the bucket survives the
  /// restart. An empty map when no key has been seen.
  Map<String, TokenBucketSnapshot> snapshot() => <String, TokenBucketSnapshot>{
    for (final entry in _buckets.entries)
      entry.key: TokenBucketSnapshot(
        tokens: entry.value.tokens,
        lastRefill: entry.value.lastRefill,
      ),
  };

  /// Snapshot of a single [key]'s bucket, or `null` when it has no live state.
  ///
  /// The single-key form a caller uses to persist incrementally — after one
  /// [tryTake] for [key], write just that key's row rather than the whole map.
  TokenBucketSnapshot? snapshotOf(String key) {
    final bucket = _buckets[key];
    if (bucket == null) return null;
    return TokenBucketSnapshot(
      tokens: bucket.tokens,
      lastRefill: bucket.lastRefill,
    );
  }

  /// Seeds bucket state from a previously taken [snapshot] (e.g. read from
  /// durable storage at boot).
  ///
  /// Each key in [snapshot] overwrites any existing bucket for that key; keys
  /// absent from [snapshot] are left untouched. A restored token count is
  /// clamped to `[0, capacity]` so a snapshot taken under a larger capacity (a
  /// since-shrunk policy) cannot seed an over-full bucket. Each key must be
  /// non-empty (the same invariant [tryTake] enforces).
  void restore(Map<String, TokenBucketSnapshot> snapshot) {
    snapshot.forEach((key, state) {
      requireNonEmpty(key, 'key');
      _buckets[key] = _BucketState(
        state.tokens.clamp(0.0, policy.capacity.toDouble()),
        state.lastRefill,
      );
    });
  }

  /// Attempts to take one token for [key].
  ///
  /// Refills [key]'s bucket from the elapsed wall-clock time, then either
  /// consumes one token and returns `null` (success), or — when fewer than
  /// one token is available — returns the [Duration] until one token will
  /// have refilled without charging the bucket. [key] must be non-empty
  /// (an empty key would collapse every caller into one shared bucket).
  Duration? tryTake(String key) {
    requireNonEmpty(key, 'key');

    final now = clock();
    final bucket = _buckets.putIfAbsent(
      key,
      () => _BucketState(policy.capacity.toDouble(), now),
    );

    _refill(bucket, now);

    if (bucket.tokens >= 1.0) {
      bucket.tokens -= 1.0;
      return null;
    }

    // Not enough for a whole token: compute the wait until the deficit
    // (1 - tokens) has refilled. refillTokens > 0 guarantees this is finite.
    final deficit = 1.0 - bucket.tokens;
    final microseconds = (deficit / policy.tokensPerMicrosecond).ceil();
    return Duration(microseconds: microseconds);
  }

  /// Refills [bucket] for the time elapsed since its last refill, capped at
  /// [TokenBucketPolicy.capacity]. A backwards or stalled clock pins
  /// `lastRefill` forward without draining or crediting the bucket.
  void _refill(_BucketState bucket, DateTime now) {
    final elapsedMicros = now.difference(bucket.lastRefill).inMicroseconds;
    if (elapsedMicros <= 0) {
      bucket.lastRefill = now;
      return;
    }
    final refilled = elapsedMicros * policy.tokensPerMicrosecond;
    bucket.tokens = (bucket.tokens + refilled).clamp(
      0.0,
      policy.capacity.toDouble(),
    );
    bucket.lastRefill = now;
  }
}

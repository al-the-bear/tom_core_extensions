// Absolute-TTL cache with lazy sweep and an optional size ceiling.
//
// A domain-free memoisation store keyed by an arbitrary key. Each entry
// expires a fixed [TtlCache.ttl] after it was *written* (absolute expiry,
// not a sliding window): a much-read entry still ages out, so a cached
// value cannot drift arbitrarily stale. Expired entries are swept lazily
// on each access — there is no background timer.
//
// The optional [TtlCache.maxEntries] ceiling bounds memory when the key
// space is large or attacker-influenced (e.g. keyed by inbound text):
// once the ceiling is reached a write evicts the least-recently-used live
// entry. Without a ceiling the map is bounded only by TTL, which is fine
// for a small bounded key set but a memory-exhaustion vector for an
// unbounded one — pass [maxEntries] when the keys are not bounded.
//
// Storage and recency only. The cache stores resolved values; orchestration
// (async compute, in-flight de-duplication, failure handling) belongs to the
// caller, which reads with [get] and writes with [set].

import 'dart:collection';

import 'system_clock.dart';

/// A stored value plus the wall-clock instant it was written.
class _Entry<V> {
  _Entry(this.value, this.writtenAt);

  final V value;
  final DateTime writtenAt;
}

/// An absolute-TTL cache from [K] to [V] with lazy expiry sweeping and an
/// optional least-recently-used size ceiling.
///
/// Construct with the entry [ttl] and, when the key space is unbounded,
/// a [maxEntries] ceiling. [get] returns the live value for a key (and
/// marks it most-recently-used) or `null` when the key is absent or
/// expired; [set] writes a value, evicting the least-recently-used live
/// entry if the write would exceed [maxEntries]. Time is read through an
/// injectable [clock] for deterministic tests.
final class TtlCache<K, V> {
  /// Entry lifetime, measured from write time. Must be strictly positive.
  final Duration ttl;

  /// Maximum number of live entries, or `null` for no ceiling. When set,
  /// a write that would exceed it evicts the least-recently-used entry.
  /// Must be `>= 1` when provided.
  final int? maxEntries;

  /// Time source. Defaults to [systemClock]; tests pass a controllable
  /// clock so expiry is deterministic.
  final DateTime Function() clock;

  // LinkedHashMap preserves insertion order; re-inserting on read moves a
  // key to the end, so `keys.first` is always the least-recently-used.
  final LinkedHashMap<K, _Entry<V>> _entries = LinkedHashMap<K, _Entry<V>>();

  /// Builds a cache with entry lifetime [ttl] and optional [maxEntries]
  /// ceiling. [ttl] must be strictly positive; [maxEntries], when given,
  /// must be `>= 1`. [clock] defaults to [systemClock].
  TtlCache({required this.ttl, this.maxEntries, DateTime Function()? clock})
    : clock = clock ?? systemClock {
    if (ttl <= Duration.zero) {
      throw ArgumentError.value(ttl, 'ttl', 'must be strictly positive');
    }
    if (maxEntries != null && maxEntries! < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be >= 1');
    }
  }

  /// The live value for [key], or `null` when it is absent or expired.
  ///
  /// Sweeps expired entries first, then — on a live hit — marks [key]
  /// most-recently-used so it is the last candidate for size eviction.
  V? get(K key) {
    final now = clock();
    _sweepExpired(now);

    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_isExpired(entry, now)) return null;

    // Re-insert to move the key to the most-recently-used end.
    _entries[key] = entry;
    return entry.value;
  }

  /// Writes [value] for [key], stamped with the current clock time.
  ///
  /// Sweeps expired entries first, then — if the write would exceed
  /// [maxEntries] — evicts least-recently-used entries until the cache is
  /// within the ceiling. A re-write of an existing key refreshes both its
  /// value and its TTL.
  void set(K key, V value) {
    final now = clock();
    _sweepExpired(now);

    _entries.remove(key);
    _entries[key] = _Entry<V>(value, now);
    _evictToCeiling();
  }

  /// The number of live (post-sweep) entries.
  int get length {
    _sweepExpired(clock());
    return _entries.length;
  }

  /// Drops all entries.
  void clear() => _entries.clear();

  bool _isExpired(_Entry<V> entry, DateTime now) =>
      now.difference(entry.writtenAt) >= ttl;

  /// Removes every entry older than [ttl]. O(n) over the map.
  void _sweepExpired(DateTime now) {
    _entries.removeWhere((_, entry) => _isExpired(entry, now));
  }

  /// Evicts least-recently-used entries until the cache is within
  /// [maxEntries]. A no-op when there is no ceiling.
  void _evictToCeiling() {
    final ceiling = maxEntries;
    if (ceiling == null) return;
    while (_entries.length > ceiling) {
      _entries.remove(_entries.keys.first);
    }
  }
}

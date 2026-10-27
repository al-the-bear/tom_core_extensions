import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  TtlCache<String, int> cacheWith({int? maxEntries, Duration? ttl}) =>
      TtlCache<String, int>(
        ttl: ttl ?? const Duration(minutes: 5),
        maxEntries: maxEntries,
        clock: () => now,
      );

  setUp(() => now = DateTime.utc(2026, 1, 1));

  group('TtlCache construction', () {
    test('rejects a non-positive ttl', () {
      expect(
        () => TtlCache<String, int>(ttl: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a maxEntries below 1', () {
      expect(
        () => TtlCache<String, int>(
          ttl: const Duration(minutes: 1),
          maxEntries: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('TtlCache get/set', () {
    test('returns a stored value before it expires', () {
      final cache = cacheWith();
      cache.set('a', 1);
      expect(cache.get('a'), 1);
    });

    test('returns null for an absent key', () {
      expect(cacheWith().get('missing'), isNull);
    });

    test('expires entries by absolute write time', () {
      final cache = cacheWith(ttl: const Duration(minutes: 5));
      cache.set('a', 1);
      now = now.add(const Duration(minutes: 5));
      expect(cache.get('a'), isNull);
    });

    test('a re-write refreshes the TTL', () {
      final cache = cacheWith(ttl: const Duration(minutes: 5));
      cache.set('a', 1);
      now = now.add(const Duration(minutes: 4));
      cache.set('a', 2);
      now = now.add(const Duration(minutes: 4)); // 8 min from first write
      expect(cache.get('a'), 2);
    });

    test('length reflects only live entries', () {
      final cache = cacheWith(ttl: const Duration(minutes: 1));
      cache.set('a', 1);
      cache.set('b', 2);
      expect(cache.length, 2);
      now = now.add(const Duration(minutes: 1));
      expect(cache.length, 0);
    });
  });

  group('TtlCache size ceiling', () {
    test('evicts the least-recently-used entry past the ceiling', () {
      final cache = cacheWith(maxEntries: 2);
      cache.set('a', 1);
      cache.set('b', 2);
      cache.set('c', 3); // evicts 'a' (LRU)
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), 2);
      expect(cache.get('c'), 3);
    });

    test('a read marks an entry most-recently-used', () {
      final cache = cacheWith(maxEntries: 2);
      cache.set('a', 1);
      cache.set('b', 2);
      cache.get('a'); // 'a' now most-recently-used; 'b' is LRU
      cache.set('c', 3); // evicts 'b'
      expect(cache.get('a'), 1);
      expect(cache.get('b'), isNull);
      expect(cache.get('c'), 3);
    });

    test('an unbounded cache never evicts by size', () {
      final cache = cacheWith();
      for (var i = 0; i < 1000; i++) {
        cache.set('k$i', i);
      }
      expect(cache.length, 1000);
    });
  });

  test('clear drops every entry', () {
    final cache = cacheWith();
    cache.set('a', 1);
    cache.clear();
    expect(cache.get('a'), isNull);
    expect(cache.length, 0);
  });
}

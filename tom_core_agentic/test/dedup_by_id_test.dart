import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

class _Item {
  final String id;
  final int value;
  const _Item(this.id, this.value);
}

void main() {
  group('buildUniqueById', () {
    test('keys items by their extracted id', () {
      final map = buildUniqueById<_Item>(const [
        _Item('a', 1),
        _Item('b', 2),
      ], (i) => i.id);
      expect(map.keys, unorderedEquals(['a', 'b']));
      expect(map['a']!.value, 1);
      expect(map['b']!.value, 2);
    });

    test('returns an unmodifiable map', () {
      final map = buildUniqueById<_Item>(const [_Item('a', 1)], (i) => i.id);
      expect(() => map['b'] = const _Item('b', 2), throwsUnsupportedError);
    });

    test('rejects a duplicate id with the default message', () {
      expect(
        () => buildUniqueById<_Item>(
          const [_Item('a', 1), _Item('a', 2)],
          (i) => i.id,
          itemLabel: 'role',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'duplicate role id "a"',
          ),
        ),
      );
    });

    test('uses a caller-supplied duplicate message when given', () {
      expect(
        () => buildUniqueById<_Item>(
          const [_Item('a', 1), _Item('a', 2)],
          (i) => i.id,
          onDuplicate: (id) => 'provider "$id" already registered',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'provider "a" already registered',
          ),
        ),
      );
    });

    test('empty input yields an empty map', () {
      expect(buildUniqueById<_Item>(const [], (i) => i.id), isEmpty);
    });
  });
}

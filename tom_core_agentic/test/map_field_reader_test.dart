import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

/// Domain exception stand-in: proves the [MapFieldReader.errorFactory]
/// seam keeps the thrown type caller-specific.
class _ReadException implements Exception {
  final String message;
  const _ReadException(this.message);
  @override
  String toString() => 'ReadException: $message';
}

const MapFieldReader _reader = MapFieldReader(_ReadException.new);

void main() {
  group('MapFieldReader keyed accessors', () {
    test('optionalString returns the value', () {
      expect(_reader.optionalString({'a': 'hi'}, 'a', 'root.a'), 'hi');
    });

    test('optionalString returns null when absent', () {
      expect(_reader.optionalString({'b': 'x'}, 'a', 'root.a'), isNull);
    });

    test('optionalString throws with path + runtimeType on mismatch', () {
      expect(
        () => _reader.optionalString({'a': 7}, 'a', 'root.a'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            contains('root.a must be a string (got'),
          ),
        ),
      );
    });

    test('requireString returns the value', () {
      expect(_reader.requireString({'a': 'hi'}, 'a', 'root.a'), 'hi');
    });

    test('requireString throws when missing', () {
      expect(
        () => _reader.requireString({'b': 'x'}, 'a', 'root.a'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            'Missing required field: root.a',
          ),
        ),
      );
    });

    test('optionalNum accepts int and double, null when absent', () {
      expect(_reader.optionalNum({'a': 7}, 'a', 'root.a'), 7);
      expect(_reader.optionalNum({'a': 1.5}, 'a', 'root.a'), 1.5);
      expect(_reader.optionalNum({'b': 1}, 'a', 'root.a'), isNull);
    });

    test('optionalNum throws on non-numeric', () {
      expect(
        () => _reader.optionalNum({'a': 'x'}, 'a', 'root.a'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            contains('root.a must be a number (got'),
          ),
        ),
      );
    });

    test('optionalBool returns value / null / throws', () {
      expect(_reader.optionalBool({'a': true}, 'a', 'root.a'), isTrue);
      expect(_reader.optionalBool({'b': true}, 'a', 'root.a'), isNull);
      expect(
        () => _reader.optionalBool({'a': 'x'}, 'a', 'root.a'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            contains('root.a must be a boolean (got'),
          ),
        ),
      );
    });

    test('optionalMap returns value / null / throws', () {
      expect(
        _reader.optionalMap(
          {
            'a': const {'k': 1},
          },
          'a',
          'root.a',
        ),
        <Object?, Object?>{'k': 1},
      );
      expect(_reader.optionalMap({'b': const {}}, 'a', 'root.a'), isNull);
      expect(
        () => _reader.optionalMap({'a': 'x'}, 'a', 'root.a'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            contains('root.a must be a map (got'),
          ),
        ),
      );
    });

    test('optionalList returns value / null / throws', () {
      expect(
        _reader.optionalList(
          {
            'a': const [1, 2],
          },
          'a',
          'root.a',
        ),
        <Object?>[1, 2],
      );
      expect(_reader.optionalList({'b': const []}, 'a', 'root.a'), isNull);
      expect(
        () => _reader.optionalList({'a': 'x'}, 'a', 'root.a'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            contains('root.a must be a list (got'),
          ),
        ),
      );
    });
  });

  group('MapFieldReader value accessors', () {
    test('stringValue validates a value in hand', () {
      expect(_reader.stringValue('hi', 'root.a[0]'), 'hi');
      expect(
        () => _reader.stringValue(7, 'root.a[0]'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            contains('root.a[0] must be a string (got'),
          ),
        ),
      );
    });

    test('stringValue allowNull passes a null through', () {
      expect(_reader.stringValue(null, 'root.a', allowNull: true), isNull);
      expect(
        () => _reader.stringValue(null, 'root.a'),
        throwsA(isA<_ReadException>()),
      );
    });

    test('mapValue validates a value in hand', () {
      expect(_reader.mapValue(const {'k': 1}, 'root.a'), <Object?, Object?>{
        'k': 1,
      });
      expect(
        () => _reader.mapValue(7, 'root.a'),
        throwsA(
          isA<_ReadException>().having(
            (e) => e.message,
            'message',
            contains('root.a must be a map (got'),
          ),
        ),
      );
    });
  });
}

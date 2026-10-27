import 'dart:typed_data';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('sqlPlaceholders', () {
    test('builds a comma-separated run', () {
      expect(sqlPlaceholders(3), '?,?,?');
    });

    test('count of one yields a single placeholder', () {
      expect(sqlPlaceholders(1), '?');
    });

    test('count of zero yields the empty string', () {
      expect(sqlPlaceholders(0), '');
    });

    test('honours a custom separator', () {
      expect(sqlPlaceholders(3, separator: ', '), '?, ?, ?');
    });

    test('rejects negative count', () {
      expect(() => sqlPlaceholders(-1), throwsArgumentError);
    });
  });

  group('fnv1a32', () {
    test('is stable for a given input', () {
      expect(fnv1a32('gemma3:27b'), fnv1a32('gemma3:27b'));
    });

    test('fits in 32 bits', () {
      expect(
        fnv1a32('a-very-long-model-identifier-string') & 0xffffffff,
        fnv1a32('a-very-long-model-identifier-string'),
      );
      expect(fnv1a32('x') <= 0xffffffff, isTrue);
    });

    test('differs for different inputs', () {
      expect(fnv1a32('alpha') == fnv1a32('beta'), isFalse);
    });

    test('empty string hashes to the FNV offset basis', () {
      expect(fnv1a32(''), 0x811c9dc5);
    });
  });

  group('sqlSafeIdentifier', () {
    test('lowercases and replaces non-alnum with underscore', () {
      expect(sqlSafeIdentifier('Gemma3:27B'), 'gemma3_27b');
    });

    test('preserves underscores and digits', () {
      expect(sqlSafeIdentifier('a_1_b'), 'a_1_b');
    });

    test('caps at maxLength', () {
      expect(sqlSafeIdentifier('abcdefghij', maxLength: 4), 'abcd');
    });

    test('rejects negative maxLength', () {
      expect(() => sqlSafeIdentifier('x', maxLength: -1), throwsArgumentError);
    });
  });

  group('blobFromColumnOrNull', () {
    test('passes a Uint8List through unchanged', () {
      final bytes = Uint8List.fromList(<int>[1, 2, 3]);
      expect(identical(blobFromColumnOrNull(bytes), bytes), isTrue);
    });

    test('copies a List<int> into a Uint8List', () {
      final result = blobFromColumnOrNull(<int>[4, 5, 6]);
      expect(result, isA<Uint8List>());
      expect(result, <int>[4, 5, 6]);
    });

    test('returns null for a non-blob value', () {
      expect(blobFromColumnOrNull('not a blob'), isNull);
      expect(blobFromColumnOrNull(null), isNull);
    });
  });

  group('blobFromColumn', () {
    test('returns the blob for a valid column', () {
      final result = blobFromColumn(<int>[7, 8], context: 't.col');
      expect(result, <int>[7, 8]);
    });

    test('throws a context-tagged StateError for a non-blob', () {
      expect(
        () => blobFromColumn(42, context: 'pending.payload_blob'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('pending.payload_blob'), contains('expected BLOB')),
          ),
        ),
      );
    });
  });
}

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('decodeJsonObject', () {
    test('null returns the empty map', () {
      expect(decodeJsonObject(null, context: 'attrs_json'), isEmpty);
    });

    test('decodes a JSON object into a String-keyed map', () {
      final result = decodeJsonObject('{"a":1,"b":"x"}', context: 'attrs_json');
      expect(result, <String, Object?>{'a': 1, 'b': 'x'});
    });

    test('empty object decodes to an empty map', () {
      expect(decodeJsonObject('{}', context: 'attrs_json'), isEmpty);
    });

    test('throws a context-tagged StateError on a non-object payload', () {
      expect(
        () => decodeJsonObject('[1,2,3]', context: 'edges.attrs_json'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('edges.attrs_json'),
              contains('is not a JSON object'),
            ),
          ),
        ),
      );
    });

    test('rethrows a FormatException on malformed JSON', () {
      expect(
        () => decodeJsonObject('{not json', context: 'attrs_json'),
        throwsFormatException,
      );
    });
  });
}

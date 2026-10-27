/// The validator: the OpenAPI 3.1 meta-schema through Python, the
/// cross-reference rules in Dart, and "not measured" kept apart from "valid".
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

const _minimal = {
  'openapi': '3.1.0',
  'info': {'title': 't', 'version': '1'},
  'paths': <String, Object?>{},
};

void main() {
  test('a minimal document is valid', () async {
    final validation = await TomOpenApiValidator().validateDocument(_minimal);
    expect(validation.measured, isTrue, reason: '$validation');
    expect(validation.isValid, isTrue, reason: '$validation');
  });

  test('a document missing a required member is not', () async {
    final validation = await TomOpenApiValidator().validateDocument({
      'openapi': '3.1.0',
      'info': {'title': 't'},
      'paths': <String, Object?>{},
    });
    expect(validation.measured, isTrue);
    expect(validation.errors.join(), contains("'version' is a required"));
  });

  test('an embedded schema object is checked too (schema-base)', () async {
    final validation = await TomOpenApiValidator().validateDocument({
      ..._minimal,
      'components': {
        'schemas': {
          'Bad': {'type': 'strin'},
        },
      },
    });
    expect(validation.isValid, isFalse);
  });

  test('the cross-reference rules apply on top of the meta-schema', () async {
    final validation = await TomOpenApiValidator().validateDocument({
      ..._minimal,
      'paths': {
        '/a': {
          'get': {
            'operationId': 'a',
            'responses': {
              '200': {
                'description': 'ok',
                'content': {
                  'application/json': {
                    'schema': {r'$ref': '#/components/schemas/Missing'},
                  },
                },
              },
            },
          },
        },
      },
    });
    expect(validation.errors.join(), contains('"Missing"'));
  });

  test(
    'an interpreter that cannot start is NOT MEASURED, never valid',
    () async {
      final validation = await TomOpenApiValidator(
        python: const ['no-such-python-interpreter'],
      ).validateDocument(_minimal);
      expect(validation.measured, isFalse);
      expect(validation.isValid, isFalse);
      expect('$validation', contains('NOT MEASURED'));
    },
  );

  test('a file that is not JSON is reported, not thrown', () async {
    final dir = Directory(p.join('.dart_tool', 'tom_core_openapi'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'not_json.json'))
      ..writeAsStringSync('{');
    try {
      final validation = await TomOpenApiValidator().validateFile(file.path);
      expect(validation.isValid, isFalse);
      expect(validation.errors.single, contains('not a JSON object'));
    } finally {
      file.deleteSync();
    }
  });
}

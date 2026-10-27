/// The document-side of `tom_core_openapi`, step by step: check a document,
/// validate it against the OpenAPI 3.1 meta-schema, and generate the typed
/// Dart client a caller would use.
///
/// Run with `dart run example/tom_core_openapi_example.dart`. Every step checks
/// its own result, and the run fails when one does not hold.
///
/// Generating a document needs a server's reflection seed, so that step lives
/// in a server package's `tool/openapi.dart` — the advanced sample's
/// `advanced_app_server/tool/openapi.dart` is the worked example. Everything
/// here reads a document only, which is what a consumer of a Tom server has.
library;

import 'package:tom_core_openapi/tom_core_openapi.dart';

/// A small document of the shape the generator writes: one secured read, one
/// public write, one model.
const Map<String, Object?> document = {
  'openapi': '3.1.0',
  'info': {'title': 'Notes', 'version': '1.0.0'},
  'paths': {
    '/notes/{id}': {
      'get': {
        'operationId': 'readNote',
        'parameters': [
          {
            'name': 'id',
            'in': 'path',
            'required': true,
            'schema': {'type': 'string'},
          },
        ],
        'responses': {
          '200': {
            'description': 'The note.',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Note'},
              },
            },
          },
        },
        'security': [
          {'bearerAuth': <String>[]},
        ],
      },
    },
    '/notes': {
      'post': {
        'operationId': 'addNote',
        'requestBody': {
          'required': true,
          'content': {
            'application/json': {
              'schema': {r'$ref': '#/components/schemas/Note'},
            },
          },
        },
        'responses': {
          '200': {'description': 'Stored; no body.'},
        },
        'security': <Object?>[],
      },
    },
  },
  'components': {
    'schemas': {
      'Note': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'text': {'type': 'string'},
          'due': {
            'type': ['string', 'null'],
            'format': 'date-time',
          },
        },
        'required': ['id', 'text'],
      },
    },
    'securitySchemes': {
      'bearerAuth': {'type': 'http', 'scheme': 'bearer', 'bearerFormat': 'JWT'},
    },
  },
};

void check(bool condition, String what) {
  if (!condition) throw StateError('Example check failed: $what');
}

Future<void> main() async {
  // 1. The cross-reference rules: unique operation ids, resolvable
  //    references, a parameter for every path variable.
  final problems = TomOpenApiDocumentCheck.problems(document);
  print('1. consistency problems     : ${problems.length}');
  check(problems.isEmpty, 'the document is consistent');

  // 2. The OpenAPI 3.1 meta-schema, every embedded schema included. It runs
  //    through Python's jsonschema; when that cannot run, the answer is
  //    NOT MEASURED rather than valid.
  final validation = await TomOpenApiValidator().validateDocument(document);
  print('2. meta-schema              : $validation');
  check(validation.isValid, 'the document validates');

  // 3. A typed client: one class per model, one method per operation,
  //    package:http as its only dependency.
  final source = TomOpenApiDartClientGenerator(
    clientName: 'NotesApi',
  ).generate(document);
  print('3. client                   : ${source.split('\n').length} lines');
  check(source.contains('class Note {'), 'the model is a class');
  check(
    source.contains('Future<Note> readNote({required String id})'),
    'the read is typed by its response schema',
  );
  check(
    source.contains('Future<void> addNote({required Note body})'),
    'a write with no response body returns void',
  );
  check(
    source.contains("import 'package:http/http.dart' as http;") &&
        !source.contains("import 'package:tom_"),
    'the client needs no Tom package',
  );

  // 4. A broken document is refused by name.
  final broken = Map.of(document)..remove('info');
  final refused = await TomOpenApiValidator().validateDocument(broken);
  print('4. without info             : ${refused.errors.first}');
  check(!refused.isValid, 'a document without info does not validate');
}

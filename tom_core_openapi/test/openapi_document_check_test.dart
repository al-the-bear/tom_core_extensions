/// The cross-reference rules the meta-schema cannot express.
library;

import 'package:test/test.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

Map<String, Object?> _document(
  Map<String, Object?> paths, [
  Map<String, Object?> schemas = const {},
]) => {
  'openapi': '3.1.0',
  'info': {'title': 't', 'version': '1'},
  'paths': paths,
  'components': {'schemas': schemas},
};

Map<String, Object?> _op(String id, {List<Object?> parameters = const []}) => {
  'operationId': id,
  'parameters': parameters,
  'responses': {
    '200': {'description': 'ok'},
  },
};

Map<String, Object?> _path(String name) => {
  'name': name,
  'in': 'path',
  'required': true,
  'schema': {'type': 'string'},
};

void main() {
  test('a sound document has no problems', () {
    expect(
      TomOpenApiDocumentCheck.problems(
        _document({
          '/a/{id}': {
            'get': _op('getA', parameters: [_path('id')]),
          },
        }),
      ),
      isEmpty,
    );
  });

  test('a repeated operationId is reported with both places', () {
    final problems = TomOpenApiDocumentCheck.problems(
      _document({
        '/a': {'get': _op('same')},
        '/b': {'post': _op('same')},
      }),
    );
    expect(problems.single, contains('GET /a'));
    expect(problems.single, contains('POST /b'));
  });

  test('a path variable without a parameter, and the reverse', () {
    final problems = TomOpenApiDocumentCheck.problems(
      _document({
        '/a/{id}': {
          'get': _op('a', parameters: [_path('other')]),
        },
      }),
    );
    expect(problems, hasLength(2));
    expect(problems.join(), allOf(contains('{id}'), contains('"other"')));
  });

  test('a parameter declared twice', () {
    final query = {
      'name': 'q',
      'in': 'query',
      'schema': {'type': 'string'},
    };
    expect(
      TomOpenApiDocumentCheck.problems(
        _document({
          '/a': {
            'get': _op('a', parameters: [query, query]),
          },
        }),
      ).single,
      contains('query q'),
    );
  });

  test('a reference to an undefined schema', () {
    final problems = TomOpenApiDocumentCheck.problems(
      _document({
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
      }),
    );
    expect(problems.single, contains('"Missing"'));
  });
}

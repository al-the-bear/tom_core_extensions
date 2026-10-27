/// The document generator over the fixture's endpoints: one assertion per
/// rule that decides what an operation looks like.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

import 'fixtures/openapi_fixture.dart';
import 'fixtures/openapi_fixture.reflection.dart';

void main() {
  late Map<String, Object?> document;
  late Map<String, Object?> paths;

  Map<String, Object?> op(String path, String method) =>
      ((paths[path] as Map)[method] as Map).cast<String, Object?>();

  List<Map<String, Object?>> parameters(String path, String method) => [
    for (final p in (op(path, method)['parameters'] as List?) ?? const [])
      (p as Map).cast<String, Object?>(),
  ];

  Map<String, Object?> success(String path, String method) =>
      ((op(path, method)['responses'] as Map)['200'] as Map)
          .cast<String, Object?>();

  setUpAll(() {
    registerFixtureApis();
    initializeReflection();
    document = TomOpenApiDocumentGenerator(
      info: const TomOpenApiInfo(
        title: 'Fixture',
        version: '1.2.3',
        description: 'The fixture server.',
      ),
      servers: const ['http://localhost:9999'],
    ).generate();
    paths = (document['paths'] as Map).cast<String, Object?>();
  });

  group('the document', () {
    test('is OpenAPI 3.1 with the given info and servers', () {
      expect(document['openapi'], '3.1.0');
      expect(document['info'], {
        'title': 'Fixture',
        'version': '1.2.3',
        'description': 'The fixture server.',
      });
      expect(document['servers'], [
        {'url': 'http://localhost:9999'},
      ]);
    });

    test('lists the framework endpoints the router would mount too', () {
      expect(paths.keys, containsAll(['/health', '/openapi.json']));
    });

    test('is deterministic: paths and schemas are sorted', () {
      final keys = paths.keys.toList();
      expect(keys, [...keys]..sort());
      final schemas = ((document['components'] as Map)['schemas'] as Map).keys
          .toList();
      expect(schemas, [...schemas]..sort());
    });

    test(
      'generateJson is the same document, indented, ending in a newline',
      () {
        final json = TomOpenApiDocumentGenerator(
          info: const TomOpenApiInfo(title: 'Fixture', version: '1.2.3'),
        ).generateJson();
        expect(json, endsWith('}\n'));
        expect(json, contains('\n  "openapi": "3.1.0"'));
        expect(jsonDecode(json), isA<Map<String, Object?>>());
      },
    );

    test('leaves out excluded prefixes', () {
      final trimmed = TomOpenApiDocumentGenerator(
        info: const TomOpenApiInfo(title: 'F', version: '1'),
        excludePathPrefixes: const ['/scim', '/saml'],
      ).generate();
      final keys = (trimmed['paths'] as Map).keys;
      expect(keys.where((p) => p.startsWith('/scim')), isEmpty);
      expect(keys, contains('/fixture/notes'));
    });

    test('passes its own consistency check', () {
      expect(TomOpenApiDocumentCheck.problems(document), isEmpty);
    });

    test('defines the bearer scheme and the error envelope', () {
      final components = document['components'] as Map;
      expect((components['securitySchemes'] as Map)['bearerAuth'], {
        'type': 'http',
        'scheme': 'bearer',
        'bearerFormat': 'JWT',
      });
      expect((components['securitySchemes'] as Map)['apiKeyAuth'], {
        'type': 'apiKey',
        'in': 'header',
        'name': 'X-API-Key',
        'description': isA<String>(),
      });
      expect(((components['schemas'] as Map)['TomError'] as Map)['required'], [
        'errorType',
      ]);
    });
  });

  group('an operation', () {
    test('takes its operationId from the class and method', () {
      expect(
        op('/fixture/notes/{id}', 'get')['operationId'],
        'fixtureNoteServiceRead',
      );
    });

    test('takes its operationId and description from the registry', () {
      final listAll = op('/fixture-api/all', 'get');
      expect(listAll['operationId'], 'fixtureListAll');
      expect(listAll['description'], 'Every note.');
      expect(listAll['tags'], ['fixtureApi']);
    });

    test('of a multi-method endpoint is one per method, suffixed', () {
      expect(op('/fixture/both', 'get')['operationId'], endsWith('BothGet'));
      expect(op('/fixture/both', 'post')['operationId'], endsWith('BothPost'));
    });

    test('of a socket endpoint does not exist', () {
      expect(paths.containsKey('/fixture/socket'), isFalse);
    });

    test('binds a primitive parameter named in the path from the path', () {
      expect(parameters('/fixture/notes/{id}', 'get'), [
        {
          'name': 'id',
          'in': 'path',
          'required': true,
          'schema': {'type': 'string'},
        },
      ]);
    });

    test('binds other primitives from the query, optional when optional', () {
      expect(parameters('/fixture/notes', 'get'), [
        {
          'name': 'author',
          'in': 'query',
          'required': true,
          'schema': {'type': 'string'},
        },
        {
          'name': 'limit',
          'in': 'query',
          'required': false,
          'schema': {
            'type': ['integer', 'null'],
            'format': 'int64',
          },
        },
      ]);
    });

    test('writes a shelf <name> capture as {name}', () {
      expect(paths.containsKey('/fixture/raw/{name}'), isTrue);
    });

    test('takes a DTO as a required JSON body; the principal is hidden', () {
      final create = op('/fixture/notes', 'post');
      expect(create['parameters'], isNull);
      expect(create['requestBody'], {
        'required': true,
        'content': {
          'application/json': {
            'schema': {r'$ref': '#/components/schemas/FixtureNote'},
          },
        },
      });
    });

    test('sends no body when the path carries the whole DTO', () {
      final delete = op('/fixture/notes/{id}', 'delete');
      expect(delete['requestBody'], isNull);
      expect(parameters('/fixture/notes/{id}', 'delete').single['name'], 'id');
    });

    test('binds a mapped query parameter typed by its DTO field', () {
      expect(parameters('/fixture/search', 'get'), [
        {
          'name': 'q',
          'in': 'query',
          'required': false,
          'schema': {'type': 'string'},
        },
      ]);
    });

    test('takes a form with its file part as multipart', () {
      final body =
          ((op('/fixture/upload', 'post')['requestBody'] as Map)['content']
                  as Map)['multipart/form-data']
              as Map;
      final schema = body['schema'] as Map;
      expect((schema['properties'] as Map).keys, [
        'id',
        'filter',
        'attachment',
      ]);
      expect(schema['required'], ['attachment']);
      expect((schema['properties'] as Map)['attachment'], {
        'type': 'string',
        'contentMediaType': 'application/octet-stream',
      });
    });

    test('takes a raw request as an optional body of its media type', () {
      expect(op('/fixture/raw/{name}', 'post')['requestBody'], {
        'required': false,
        'content': {'text/plain': <String, Object?>{}},
      });
    });

    test('answers a list of DTOs with an array of references', () {
      expect(success('/fixture/notes', 'get')['content'], {
        'application/json': {
          'schema': {
            'type': 'array',
            'items': {r'$ref': '#/components/schemas/FixtureNote'},
          },
        },
      });
    });

    test('reads the full generic result off the registry type', () {
      expect(success('/fixture-api/authors-by-tag', 'get')['content'], {
        'application/json': {
          'schema': {
            'type': 'object',
            'additionalProperties': {
              'type': 'array',
              'items': {r'$ref': '#/components/schemas/FixtureAuthor'},
            },
          },
        },
      });
    });

    test('answers void with no body', () {
      expect(
        success('/fixture/notes/{id}', 'delete').containsKey('content'),
        isFalse,
      );
    });

    test('answers a shelf Response with an untyped body', () {
      expect(success('/fixture/raw/{name}', 'post')['content'], {
        'text/plain': <String, Object?>{},
      });
    });

    test('answers a redirect with 302 and a Location', () {
      final responses = op('/fixture/go', 'get')['responses'] as Map;
      expect(responses.containsKey('200'), isFalse);
      expect((responses['302'] as Map)['headers'], contains('Location'));
    });

    test('states the 404 a refusal is and the default envelope', () {
      final responses = op('/fixture/notes', 'get')['responses'] as Map;
      expect(responses.keys, containsAll(['404', 'default']));
    });

    test('states the 429 a rate limit answers, with Retry-After', () {
      final responses = op('/fixture/notes', 'get')['responses'] as Map;
      expect(((responses['429'] as Map)['headers'] as Map).keys, [
        'Retry-After',
      ]);
    });
  });

  group('security', () {
    test('a public endpoint requires nothing', () {
      expect(op('/fixture/notes/{id}', 'get')['security'], isEmpty);
    });

    test('a bearer-free registry endpoint requires nothing', () {
      expect(op('/fixture-api/authors-by-tag', 'get')['security'], isEmpty);
    });

    test('an authenticated endpoint takes a bearer token or an API key', () {
      expect(op('/fixture/notes/{id}', 'delete')['security'], [
        {'bearerAuth': <String>[]},
        {'apiKeyAuth': <String>[]},
      ]);
      expect(op('/fixture/notes/{id}', 'delete')['x-tom-access'], isNull);
    });

    test('an undeclared rule falls under the protection default', () {
      expect(op('/fixture/notes', 'get')['security'], [
        {'bearerAuth': <String>[]},
        {'apiKeyAuth': <String>[]},
      ]);
    });

    test('a role rule says which roles', () {
      expect(op('/fixture/notes', 'post')['x-tom-access'], {
        'rule': 'roles',
        'roles': ['editor'],
      });
    });
  });

  test(
    'a server that serves no document still lists /openapi.json, public',
    () {
      final served = op('/openapi.json', 'get');
      expect(served['security'], isEmpty);
      expect(served['operationId'], 'tomOpenApiServiceOpenApiDocument');
    },
  );

  test('the document validates against the OpenAPI 3.1 meta-schema', () async {
    final validation = await TomOpenApiValidator().validateDocument(document);
    expect(validation.isValid, isTrue, reason: '$validation');
  });
}

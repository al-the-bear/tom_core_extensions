/// The schema builder: Dart types and reflected classes to JSON Schema, by
/// the serializer's rules rather than the type system's.
library;

import 'package:test/test.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

import 'fixtures/openapi_fixture.reflection.dart';

void main() {
  setUpAll(initializeReflection);

  group('TomOpenApiDartType.parse', () {
    test('reads nested type arguments by bracket depth', () {
      final type = TomOpenApiDartType.parse(
        'Map<String, List<Map<String, int>>>',
      );
      expect(type.name, 'Map');
      expect(type.arguments.map((a) => a.name), ['String', 'List']);
      expect(type.arguments[1].arguments.single.arguments[1].name, 'int');
    });

    test('reads a nullable type', () {
      final type = TomOpenApiDartType.parse('List<String?>?');
      expect(type.nullable, isTrue);
      expect(type.arguments.single.nullable, isTrue);
    });

    test('awaited unwraps Future and FutureOr', () {
      expect(
        TomOpenApiDartType.parse(
          'Future<FutureOr<List<int>>>',
        ).awaited.toString(),
        'List<int>',
      );
      expect(TomOpenApiDartType.parse('Future<void>').awaited.isVoid, isTrue);
    });
  });

  group('primitive and collection schemas', () {
    final builder = TomOpenApiSchemaBuilder();
    Map<String, Object?> of(String type) =>
        builder.schemaOf(TomOpenApiDartType.parse(type));

    test('primitives', () {
      expect(of('String'), {'type': 'string'});
      expect(of('int'), {'type': 'integer', 'format': 'int64'});
      expect(of('bool'), {'type': 'boolean'});
      expect(of('DateTime'), {'type': 'string', 'format': 'date-time'});
    });

    test('a nullable primitive gains "null" in its type list', () {
      expect(of('double?'), {
        'type': ['number', 'null'],
        'format': 'double',
      });
    });

    test('collections and maps', () {
      expect(of('Set<String>'), {
        'type': 'array',
        'items': {'type': 'string'},
      });
      expect(of('Map<String, bool>'), {
        'type': 'object',
        'additionalProperties': {'type': 'boolean'},
      });
    });

    test('Object and dynamic accept anything', () {
      expect(of('Object'), isEmpty);
      expect(of('dynamic'), isEmpty);
    });

    test('a nullable reference is wrapped in anyOf', () {
      expect(TomOpenApiSchemaBuilder.nullableOf({r'$ref': '#/x'}), {
        'anyOf': [
          {r'$ref': '#/x'},
          {'type': 'null'},
        ],
      });
    });
  });

  group('a reflected DTO', () {
    late TomOpenApiSchemaBuilder builder;
    late Map<String, Object?> note;

    setUp(() {
      builder = TomOpenApiSchemaBuilder();
      expect(builder.schemaOf(TomOpenApiDartType.parse('FixtureNote')), {
        r'$ref': '#/components/schemas/FixtureNote',
      });
      note = builder.components['FixtureNote']!;
    });

    test(
      'lists the fields the serializer writes, and no final or static one',
      () {
        expect((note['properties'] as Map).keys, [
          'id',
          'text',
          'priority',
          'createdAt',
          'tags',
          'counts',
          'author',
          'secret',
        ]);
      },
    );

    test('requires the non-nullable fields nothing can withhold', () {
      expect(note['required'], ['id', 'text', 'createdAt', 'tags', 'counts']);
    });

    test('a nullable nested DTO is an optional, nullable reference', () {
      expect((note['properties'] as Map)['author'], {
        'anyOf': [
          {r'$ref': '#/components/schemas/FixtureAuthor'},
          {'type': 'null'},
        ],
      });
      expect(builder.components.keys, contains('FixtureAuthor'));
    });

    test('a generic field keeps its element type', () {
      expect((note['properties'] as Map)['counts'], {
        'type': 'object',
        'additionalProperties': {'type': 'integer', 'format': 'int64'},
      });
    });
  });

  test('a TomClass is described by its observable members', () {
    final builder = TomOpenApiSchemaBuilder()
      ..schemaOf(TomOpenApiDartType.parse('FixtureObservable'));
    final observable = builder.components['FixtureObservable']!;
    final properties = observable['properties'] as Map;
    expect(properties.keys, ['title', 'due', 'labels']);
    expect(properties['title'], {'type': 'string'});
    expect(properties['due'], {
      ...TomOpenApiSchemaBuilder.tomDateTime,
      'type': ['string', 'null'],
    });
    expect(properties['labels'], {
      'type': 'array',
      'items': {'type': 'string'},
    });
    expect(observable['required'], ['title', 'labels']);
  });

  test('a self-rendering type is opaque, not guessed at', () {
    final builder = TomOpenApiSchemaBuilder()
      ..schemaOf(TomOpenApiDartType.parse('FixtureRendered'));
    expect(builder.components['FixtureRendered']!['x-tom-opaque'], isTrue);
    expect(builder.components['FixtureRendered']!['properties'], isNull);
  });

  test('a type that is not reflected is refused by name', () {
    expect(
      () => TomOpenApiSchemaBuilder().schemaOf(
        TomOpenApiDartType.parse('NoSuchType'),
      ),
      throwsA(
        isA<TomOpenApiException>().having(
          (e) => e.key,
          'key',
          'openapi.schema.type_not_reflected',
        ),
      ),
    );
  });
}

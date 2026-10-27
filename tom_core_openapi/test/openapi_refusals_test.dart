/// What the generator refuses to describe, each by its key: a document that
/// would be wrong is not written.
library;

import 'package:test/test.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';
import 'package:tom_core_server/tom_core_server.dart';

import 'fixtures/openapi_fixture.dart';
import 'fixtures/openapi_fixture.reflection.dart';

Matcher _refused(String key) =>
    throwsA(isA<TomOpenApiException>().having((e) => e.key, 'key', key));

ClassMirror _mirror(Type type) => tomReflector.reflectType(type) as ClassMirror;

void main() {
  setUpAll(initializeReflection);

  TomOpenApiDocumentGenerator generator(List<Type> services) =>
      TomOpenApiDocumentGenerator(
        info: const TomOpenApiInfo(title: 'Refusals', version: '1'),
        services: [for (final s in services) _mirror(s)],
      );

  test('openapi.document.duplicate_route: two endpoints on one route', () {
    expect(
      () => generator([FixtureDuplicateRoutes]).generate(),
      _refused('openapi.document.duplicate_route'),
    );
  });

  test('openapi.document.inconsistent: two operations, one derived id', () {
    expect(
      () => generator([FixtureCollideA, FixtureCollide]).generate(),
      throwsA(
        isA<TomOpenApiException>()
            .having((e) => e.key, 'key', 'openapi.document.inconsistent')
            .having(
              (e) => e.defaultUserMessage,
              'message',
              contains('fixtureCollideABC'),
            ),
      ),
    );
  });

  test('openapi.schema.ambiguous_type: two reflected classes, one name', () {
    expect(fixtureTwins, hasLength(2));
    expect(
      () => TomOpenApiSchemaBuilder.resolveClass('FixtureTwin'),
      _refused('openapi.schema.ambiguous_type'),
    );
  });

  test('a named service list describes only those services', () {
    final paths =
        generator([FixtureCollideA]).generate()['paths']
            as Map<String, Object?>;
    expect(paths.keys, ['/fixture/collide/one']);
  });
}

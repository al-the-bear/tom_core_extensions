/// The reflection root of the test suite: a service, a registry API and the
/// DTOs they carry, one of each shape the generator has a rule for.
///
/// `reflection_generation.sh` follows this file's import graph and writes
/// `openapi_fixture.reflection.dart` beside it; the tests call its
/// `initializeReflection()`. The framework's own services come along through
/// the `tom_core_server` barrel, so every generated document also lists them —
/// the tests read the `/fixture` paths.
library;

import 'package:shelf/shelf.dart';
import 'package:tom_core_server/tom_core_server.dart';

// Imported for their reflection: two classes named FixtureTwin.
import 'twins/twin_a.dart' as twin_a;
import 'twins/twin_b.dart' as twin_b;

/// A plain DTO: every field shape the serializer walks.
@tomReflector
class FixtureNote {
  /// A required string.
  String id = '';

  /// Another required string.
  String text = '';

  /// A nullable field — optional and admitting `null`.
  int? priority;

  /// A date, written as UTC ISO-8601.
  DateTime createdAt = DateTime.utc(1970);

  /// A list.
  List<String> tags = [];

  /// A map.
  Map<String, int> counts = {};

  /// A nested DTO, nullable.
  FixtureAuthor? author;

  /// A field the JSON protection tier may withhold: optional on the wire.
  @TomProtectedField('fixture.note.secret')
  String secret = '';

  /// Final, so the serializer skips it.
  final String constant = 'constant';

  /// Static, so the serializer skips it.
  static int instances = 0;

  /// A note.
  FixtureNote();
}

/// The nested DTO.
@tomReflector
class FixtureAuthor {
  /// The author's name.
  String name = '';

  /// An author.
  FixtureAuthor();
}

/// A request carrying an id and a filter.
@tomReflector
class FixtureIdRequest {
  /// The id, bound from the path.
  String id = '';

  /// A filter, bound from the body or a mapped query parameter.
  String filter = '';

  /// A request.
  FixtureIdRequest();
}

/// A request the path carries completely.
@tomReflector
class FixtureIdOnly {
  /// The id.
  String id = '';

  /// A request.
  FixtureIdOnly();
}

/// An observable entity, rendered by `TomClass`.
@tomReflector
class FixtureObservable extends TomClass {
  /// A non-null observable string.
  late final title = TomString('');

  /// A nullable observable date — `@!@`-prefixed on the wire.
  late final due = TomNDateTime(null);

  /// An observable list.
  late final labels = TomList<TomString>();
}

/// A DTO that renders itself, so its shape is not declared.
@tomReflector
class FixtureRendered {
  /// A member the rendering decides about.
  String a = '';

  /// A rendered value.
  FixtureRendered();

  /// The rendering.
  Map<String, Object?> toJson() => {'a': a};
}

/// The fixture's inline-annotated service.
@tomReflector
@tomService
abstract class FixtureNoteService {
  /// Public, a path parameter, a DTO result.
  @TomPublicAccess()
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/notes/{id}')
  Future<FixtureNote> read(String id);

  /// Query parameters, one optional.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/notes')
  Future<List<FixtureNote>> list(String author, [int? limit]);

  /// A JSON body; the principal is the pipeline's, not the caller's.
  @TomRoleAccess(['editor'])
  @TomEndpoint(methods: [TomHttpMethod.post], uri: '/fixture/notes')
  Future<FixtureNote> create(FixtureNote note, TomPrincipal principal);

  /// A DTO the path carries completely: no body.
  @TomAuthenticatedAccess()
  @TomEndpoint(methods: [TomHttpMethod.delete], uri: '/fixture/notes/{id}')
  Future<void> delete(FixtureIdOnly request);

  /// A DTO bound from a mapped query parameter on a GET.
  @TomEndpoint(
    methods: [TomHttpMethod.get],
    uri: '/fixture/search',
    urlParameterMapping: {'q': 'filter'},
  )
  Future<List<FixtureNote>> search(FixtureIdRequest request);

  /// A multipart form with a file part.
  @TomEndpoint(
    methods: [TomHttpMethod.post],
    uri: '/fixture/upload',
    consumes: TomMimeType.multipartFormData,
  )
  Future<void> upload(FixtureIdRequest request, TomFormFile attachment);

  /// The handler builds its own response, from the raw request.
  @TomEndpoint(
    methods: [TomHttpMethod.post],
    uri: '/fixture/raw/<name>',
    consumes: TomMimeType.plainText,
    produces: TomMimeType.plainText,
  )
  Future<Response> raw(Request request, String name);

  /// A redirect.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/go')
  Future<TomRedirect> go();

  /// A `TomClass` result.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/observable')
  Future<FixtureObservable> observable();

  /// A self-rendering result.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/rendered')
  Future<FixtureRendered> rendered();

  /// One endpoint, two methods: two operations.
  @TomEndpoint(
    methods: [TomHttpMethod.get, TomHttpMethod.post],
    uri: '/fixture/both',
  )
  Future<void> both();

  /// A socket: not an HTTP operation, so not in the document.
  @TomWebSocketEndpoint(uri: '/fixture/socket')
  Future<void> socket(TomWebSocketConnection connection);
}

/// The fixture's registry API: the contract states the types.
final TomApi fixtureApi = TomApi(
  id: 'fixtureApi',
  name: 'Fixture API',
  description: 'The registry-declared fixture endpoints.',
  uri: '/fixture-api',
  endpoints: [
    TomApiEndpoint<List<FixtureNote>, Object?>(
      id: 'fixtureListAll',
      uri: '/all',
      method: TomHttpMethod.get,
      requestTypes: const [],
      description: 'Every note.',
      access: const TomAuthenticatedAccess(),
    ),
    TomApiEndpoint<Map<String, List<FixtureAuthor>>, Object?>(
      id: 'fixtureAuthorsByTag',
      uri: '/authors-by-tag',
      method: TomHttpMethod.get,
      requestTypes: const [],
      access: const TomPublicAccess(),
      includeBearerAuthentication: false,
    ),
  ],
);

/// Registers [fixtureApi], as a server's boot registers its contracts.
void registerFixtureApis() => TomRemoteApis.registerApi(fixtureApi);

/// The implementation of [fixtureApi].
@tomReflector
@TomApiImplementation(apiId: 'fixtureApi')
class FixtureApiService {
  /// The service.
  FixtureApiService();

  /// `fixtureListAll`.
  @TomApiEndpointImplementation(
    apiId: 'fixtureApi',
    endpointId: 'fixtureListAll',
  )
  Future<List<FixtureNote>> listAll() async => [];

  /// `fixtureAuthorsByTag`.
  @TomApiEndpointImplementation(
    apiId: 'fixtureApi',
    endpointId: 'fixtureAuthorsByTag',
  )
  Future<Map<String, List<FixtureAuthor>>> authorsByTag() async => {};
}

/// The twins, named so the imports above are load-bearing.
const List<Type> fixtureTwins = [twin_a.FixtureTwin, twin_b.FixtureTwin];

/// Entry point the reflection generator requires of a root. Never run.
void main() {}

/// Two endpoints on one route and method — refused. Not a `@tomService`, so
/// only a test that names it describes it.
@tomReflector
class FixtureDuplicateRoutes {
  /// The first claim on `GET /fixture/dup`.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/dup')
  Future<void> first() async {}

  /// The second.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/dup')
  Future<void> second() async {}
}

/// With [FixtureCollide], derives one operationId for two operations:
/// `fixtureCollideA` + `BC` and `fixtureCollide` + `ABC`.
@tomReflector
class FixtureCollideA {
  /// `fixtureCollideABC`.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/collide/one')
  Future<void> bC() async {}
}

/// See [FixtureCollideA].
@tomReflector
class FixtureCollide {
  /// Also `fixtureCollideABC`.
  @TomEndpoint(methods: [TomHttpMethod.get], uri: '/fixture/collide/two')
  Future<void> aBC() async {}
}

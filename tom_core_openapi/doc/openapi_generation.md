# OpenAPI generation

How `tom_core_openapi` turns a Tom server into an OpenAPI 3.1 document, how it
validates one, and how it turns a document into a typed Dart client. Every rule
below is what the code does; the test that pins it is named where one does.

## Table of Contents

- [The design: a build step](#the-design-a-build-step)
- [Setting a server up](#setting-a-server-up)
- [What the document contains](#what-the-document-contains)
- [Operations](#operations)
- [Parameters](#parameters)
- [Request bodies](#request-bodies)
- [Responses](#responses)
- [Security](#security)
- [Schemas](#schemas)
- [The cross-reference check](#the-cross-reference-check)
- [Validation](#validation)
- [The Dart client](#the-dart-client)
- [The command-line tool](#the-command-line-tool)
- [Error keys](#error-keys)
- [Verification](#verification)

---

## The design: a build step

The document is **generated at build time and served as a file**. Generation
runs where the server's reflection seed is — a developer's checkout, a build
job — through a command; the result is committed beside the server; and the
running server only serves it, through `tom_core_server`'s
`TomOpenApiServer` at `GET /openapi.json` when its `openApiDocument` setting
names the file.

That split is deliberate. A committed document is reviewed like the code that
produced it, so a change to the API surface shows up as a diff. It is the same
on every node of a deployment. It is the file a client generator reads anyway.
And the server carries no generator. A document generated per request would
have none of those properties.

The committed file is kept honest by `--check`: `:document --check` regenerates
in memory and fails when the file on disk differs, and a server's suite runs it.
Generation is deterministic — paths, tags, methods and component schemas are
sorted, and the JSON is written with two-space indentation and a final newline
(`generateJson`) — so a regenerated document differs from the committed one
only where the API did.

**Only a Dart client is generated.** The document is standard OpenAPI 3.1, so
any standard generator — `openapi-typescript`, `openapi-generator` — produces a
TypeScript or other-language client from it. Writing one here would duplicate
those tools.

## Setting a server up

The generator needs exactly what the router needs to find the endpoints: the
server's API registrations and its reflection seed. It needs no instance, no
configuration and no database. So a server package carries a small entry point,
`tool/openapi.dart`, that prepares both and hands over to the tool:

```dart
import 'package:advanced_todo_contracts/advanced_todo_contracts.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

import '../bin/auth_server_start.reflection.dart';

Future<void> main(List<String> args) => runTomOpenApiTool(
  args,
  prepare: () {
    registerAdvancedTodoApis();
    initializeReflection();
  },
  title: 'Advanced Auth Server',
  description:
      'Credential login, token lifecycle and the role-gated administration '
      'API of the advanced sample.',
  servers: const ['http://localhost:8081'],
);
```

`prepare` runs only for `:document`. The `title`, `description` and `servers`
are the document's defaults; the command line overrides each. Stating them
here means `:document --check` reproduces the committed file with no arguments
to remember. The `info.version` defaults to the server package's pubspec
`version`, and the title to its `name` when `runTomOpenApiTool` is given none.

`tom_core_openapi` is a `dev_dependency` of the server: the build needs it, the
running server does not.

## What the document contains

```text
openapi: 3.1.0
info: {title, version, description?}
servers: [{url}, ...]                 — omitted when none
tags: [{name, description?}, ...]     — one per API or service class, sorted
paths: {path: {method: operation}}    — sorted by path, methods in a fixed order
components:
  schemas: {...}                      — every reached class, plus TomError and TomProblem
  securitySchemes:
    bearerAuth: {type: http, scheme: bearer, bearerFormat: JWT}
    apiKeyAuth: {type: apiKey, in: header, name: X-API-Key, description}
```

**Which endpoints.** `generate` runs the router's own discovery:
`registerFrameworkApis`, then `scanClasses` for every `@tomService` and
`@TomApiImplementation` class, then `getClassMethodMetadata` for each. So the
document lists what the server mounts — its own endpoints and the framework's
(health, preferences, the SCIM and SAML endpoints, `GET /openapi.json` itself,
whatever the server's registrations bring in) — and nothing it does not.

- A **WebSocket endpoint** is left out: OpenAPI has no vocabulary for a socket
  conversation, and describing the handshake as a plain `GET` would be wrong.
- **`OPTIONS`** is never listed; it is the pipeline's CORS preflight, not an
  operation.
- **`excludePathPrefixes`** (`--exclude` on the command line) drops every path
  starting with a prefix, for a surface a given client should not see.
- **`services`**, when given, replaces the scan with the listed classes — for
  a document of part of a server, or a class set no router could mount.

**Paths.** A route template's `<name>` capture, the `shelf_router` spelling,
becomes `{name}`; an empty route is `/` (`TomOpenApiDocumentGenerator.openApiPath`).
A path is the route the server mounts, so a versioned API's operations appear
under its version segment: `/v2/orders` for an endpoint of a
`@TomService(version: 2)` service or of a registry `TomApi` with `version: 2`,
and two versions of one API are two sets of paths side by side.
Within a path the methods are ordered `get`, `put`, `post`, `delete`, `head`,
`patch`, `trace`. Two endpoints claiming one method on one path are refused
(`openapi.document.duplicate_route`).

**Tags.** An operation is tagged with its registry API's id when the endpoint
belongs to a registered `TomApi`, else with the simple name of the class that
declares it. The tag's description is the API's description, else its name.

## Operations

| Member | Value |
| ------ | ----- |
| `tags` | the one tag above |
| `operationId` | the registry endpoint's `id` when the endpoint is declared against the `tomRemoteApis` registry; otherwise the class name with a lower-case first letter followed by the method name with an upper-case first letter (`noteServiceReadNote`). An endpoint declaring several HTTP methods yields one operation per method, each id suffixed with its method (`…Get`, `…Post`) |
| `description` | the registry endpoint's `description`, when it has one |
| `parameters` | see [Parameters](#parameters); omitted when empty |
| `requestBody` | see [Request bodies](#request-bodies); omitted when there is none |
| `responses` | see [Responses](#responses) |
| `security` | see [Security](#security) |
| `x-tom-access` | see [Security](#security); omitted for public and plainly authenticated operations |

The `operationId` is what a client generator names the method after, so its
uniqueness is checked before the document is returned.

## Parameters

Each handler parameter is classified by its declared type, read from the
reflected `Type` of the declaration:

| Declared type | Becomes |
| ------------- | ------- |
| `TomPrincipal`, `TomClientJwtToken`, `TomExecutionContext`, `TomRequestLogInfo` | nothing — the pipeline supplies them from the request (`TomOpenApiDocumentGenerator.contextTypes`) |
| shelf `Request` | nothing as a parameter; the operation gets an optional raw body (see below) |
| `TomMultipartForm` | nothing as a parameter; the form body admits any further field |
| `TomFormFile` | a file part of a multipart body, named after the parameter |
| `String`, `int`, `double`, `num`, `bool` | a parameter: `in: path` when the path has a variable of that name, else `in: query`. A path parameter is required; a query parameter is required unless the Dart parameter is optional |
| anything else | the request DTO |

Then the DTO's share of the URL is added:

- **Every path variable no primitive parameter took** becomes a required path
  parameter. Its schema is the DTO field it binds to — the
  `urlParameterMapping` entry for the variable, else the field of the same
  name — without `null`, or `string` when there is no such field.
- **Every `urlParameterMapping` entry that is not a path variable** becomes an
  optional query parameter typed by its DTO field, unless a primitive parameter
  of the same name already binds it (the pipeline reads one query parameter
  once) or another parameter already covers that field.

A query parameter the mapping does not name is not bound by the pipeline, and
so is not in the document either.

## Request bodies

Only `POST`, `PUT`, `PATCH` and `DELETE` operations carry a body.

- **A form.** When the handler takes a `TomFormFile` or a `TomMultipartForm`,
  or the endpoint `consumes` multipart or URL-encoded form data, the body is
  required `multipart/form-data` with an object schema: the DTO's fields
  (restricted to the endpoint's `formFields` when it lists any), each file part
  as `{type: string, contentMediaType: application/octet-stream}`, the file
  parts listed as `required`, and `additionalProperties: true` when the handler
  takes a `TomMultipartForm`.
- **A DTO.** A required body of the endpoint's `consumes` media type whose
  schema is the DTO's — unless the path and query parameters already carry
  every field of it, in which case the operation has no body at all (a
  `DELETE /notes/{id}` whose DTO is just `{id}`).
- **A raw request.** A handler that takes a shelf `Request` gets an optional
  body of its `consumes` media type with an empty schema: the handler reads the
  body itself, so nothing declares its shape.

## Responses

The success response is read from the registry endpoint's `responseType` when
the endpoint has one — a `Type` keeps every type argument, `List<Note>` — and
otherwise from the method's reflected return type, without its `Future`
(`TomOpenApiDocumentGenerator.returnTypeOf`).

| Result type | Success response |
| ----------- | ---------------- |
| `TomRedirect` | `302` with a `Location` header (`format: uri`), and no `200` |
| `void` (or `Null`, `Never`), or an endpoint producing no media type | `200` with no body |
| shelf `Response` | `200` with an untyped body of the produced media type |
| anything else | `200` with the type's schema under the produced media type |

Every operation also carries three error responses:

- **`429`**, with the same two media types and schemas as `default`, and a
  `Retry-After` header (`integer`, `minimum: 1`) giving the seconds to wait. It
  is stated for every operation because rate limits are deployment
  configuration the build cannot see: any operation may be limited, and a
  caller should be ready to wait the `Retry-After` it is given. The body is the
  framework envelope keyed `rate_limit.exceeded`, or the problem document with
  `type` `urn:tom:error:rate_limit.exceeded`.

- **`404`**, as `text/plain`. It is stated for every operation because it is
  how the framework refuses a caller: a denied request answers a bare
  `404 Not found`, indistinguishable from a route that does not exist, so that
  a refusal does not confirm what it refuses. A client must read a `404` as
  "not found or not yours".
- **`default`**, as `application/json` with the schema
  `anyOf: [{$ref: TomError}, {type: object}]`, and as
  `application/problem+json` with the schema `{$ref: 'TomProblem'}`. Which status
  an error carries is the server's error handler's decision, and so is its body
  — usually the framework envelope, which the `TomError` component describes,
  or, for a request whose `Accept` names `application/problem+json` (and for
  every error of a service declared `problemJson: true`), the same fields as an
  RFC 9457 problem document, which the component `'TomProblem'` describes; a handler may write
  its own.

`TomError` is the framework's error envelope (`tomErrorEnvelope`): an object
whose only required member is `errorType`, with `errorKey`, `uuid`, `autoLog`,
`requestUuid` (string or `null`), `clientThrow` and `loginFailure` present when
the error carries them.

The `'TomProblem'` component is the RFC 9457 problem document (`tomProblemDetails`):
`allOf` the `TomError` envelope and an object requiring `type` (a
`uri-reference`: `urn:tom:error:<errorKey>`, or `about:blank` for an error
without a key), `title` (the status's reason phrase) and `status` (an integer),
with `instance` (`urn:tom:request:<requestUuid>`) when the error names its
request. Its component name is `TomOpenApiDocumentGenerator.problemSchema`.

## Security

The document defines two security schemes, and every authenticated operation
accepts either:

| Scheme | Constant | Definition |
| ------ | -------- | ---------- |
| `bearerAuth` | `TomOpenApiDocumentGenerator.bearerScheme` | HTTP bearer with a JWT — a signed-in user's token |
| `apiKeyAuth` | `TomOpenApiDocumentGenerator.apiKeyScheme` | an API key in the `X-API-Key` header — a service account's key, `tomk.<keyId>.<secret>`, read by the server only when no `Authorization` header is sent |

Each operation's `security` follows the endpoint's access control. For an
authenticated operation it lists the two schemes as two alternative
requirements, which is how OpenAPI spells "either":

| Access control | `security` | `x-tom-access` |
| -------------- | ---------- | -------------- |
| `@TomPublicAccess()` | `[]` | — |
| none declared, on a registry endpoint with `includeBearerAuthentication: false` | `[]` | — |
| `@TomAuthenticatedAccess()` | `[{bearerAuth: []}, {apiKeyAuth: []}]` | — |
| `@TomRoleAccess([...])` | `[{bearerAuth: []}, {apiKeyAuth: []}]` | `{rule: roles, roles: [...]}` |
| any other rule | `[{bearerAuth: []}, {apiKeyAuth: []}]` | `{rule: <the rule's type name>}` |
| none declared | `[{bearerAuth: []}, {apiKeyAuth: []}]` | — |

An endpoint that declares no access rule falls under the server's protection
default, which requires an authenticated principal — so it is documented as
needing a bearer token or an API key. A service account's key carries roles like
a user's token, so `x-tom-access` applies to it the same way. `x-tom-access` is a vendor extension: OpenAPI has no
standard way to say *which* authenticated callers an operation admits, and a
reader can learn the roles from it while a standard generator ignores it.

## Schemas

Schemas describe what the wire **actually carries**, and that is decided by the
kernel serializer, `TomReflectionInfo.getValues`, not by the Dart declaration
alone. `TomOpenApiSchemaBuilder` follows the serializer's rules. Every class it
reaches becomes a component under `components.schemas`, named by its simple
name, and is referenced with `$ref`; a component is registered before it is
built, so a class that refers to itself ends in a reference, not a loop.

**Primitives** (`TomOpenApiSchemaBuilder.primitives`):

| Dart type | Schema |
| --------- | ------ |
| `String` | `{type: string}` |
| `int` | `{type: integer}`, with the 64-bit integer `format` |
| `double` | `{type: number}`, with the `double` `format` |
| `num` | `{type: number}` |
| `bool` | `{type: boolean}` |
| `DateTime` | `{type: string, format: date-time}` — a plain `DateTime` field travels as UTC ISO-8601 |
| `Uri` | `{type: string, format: uri}` |
| `Duration` | `{type: integer, x-tom-type: Duration}` |
| `TomZonedDateTime`, `TomZonedDate`, `TomZonedTime` | `{type: string, x-tom-type: <the type>}` — the value's own string form |
| `Object`, `dynamic`, `void` | `{}` — anything |
| `List<T>`, `Set<T>`, `Iterable<T>` | `{type: array, items: <T>}` |
| `Map<K, V>` | `{type: object, additionalProperties: <V>}` |
| an `enum` | `{type: string}` |

**A plain DTO** — a reflected class that is not a `TomClass` — contributes its
own fields that are non-static, non-private and non-final, exactly the ones
`getValues` walks. A field is `required` when its type is non-nullable and it
carries no `@TomProtectedField`, since a protected field may be withheld.

**A `TomClass`** renders its observable members, so its schema is read from
them — its own and its superclasses' up to `TomClass`, in declaration order:

| Member type | Schema | Required |
| ----------- | ------ | -------- |
| `TomString`, `TomInt`, `TomDouble`, `TomBool` | the value type's | yes |
| `TomNString`, `TomNInt`, `TomNDouble`, `TomNBool` | the value type's, admitting `null` | no |
| `TomDateTime` / `TomNDateTime` | `TomOpenApiSchemaBuilder.tomDateTime` (admitting `null` for the `N` variant) | yes / no |
| `TomOZonedDateTime`, `TomOZonedDate`, `TomOZonedTime` and their `N` variants | the zoned type's | yes / no |
| `TomList<T>` | `{type: array, items: <T>}` | yes |
| `TomMap<K, V>` | `{type: object, additionalProperties: <V>}` | yes |
| `TomObservableEnum` | `{type: string}` | yes |
| a nested `TomClass` | a `$ref` | yes |

**An observable `TomDateTime` is not `format: date-time`.** `TomClass` writes
it as the ISO-8601 text behind an `@!@` prefix, so its reader can tell a date
from a string, and that text is not a valid `date-time`. Its schema says what
it is instead:

```text
{type: string, pattern: "^@!@", x-tom-type: TomDateTime,
 description: "An ISO-8601 date-time behind the \"@!@\" prefix, …"}
```

A standard generator types it as a string, which is correct; the Dart client
generator knows the convention and holds it as a `DateTime`.

**A self-rendering type** — a class, not a `TomClass`, that declares `toJson`,
declares a `jsonEncode` method, or implements `TomJsonSerializable` — has a
shape no declaration states. It is described as
`{type: object, x-tom-opaque: true}` with a description saying so, rather than
guessed at.

**Nullability** follows JSON Schema 2020-12, which OpenAPI 3.1 is:
`nullable: true` no longer exists. A typed schema gains `"null"` in its type
list (`{type: [string, null]}`), and a `$ref` is wrapped:
`{anyOf: [{$ref: …}, {type: null}]}` (`TomOpenApiSchemaBuilder.nullableOf`).

**Refused types.** A type that appears on the wire and is not reflected cannot
be described, and is refused by name (`openapi.schema.type_not_reflected`) with
the remedy: annotate it with `@tomReflector` and regenerate the seed. Two
reflected classes with one simple name would share a component name, so the
second is refused (`openapi.schema.ambiguous_type`) rather than silently
described by the first.

**Why declarations are read from their `Type`.** The generated reflection data
can attach the wrong class to a type-argument mirror — a `List<String>` field
whose argument mirror names another class. The reflected `Type` of a field or
parameter is always right and keeps every type argument, so the shape is parsed
from it (`TomOpenApiDartType.fromDeclaration`); only the top-level nullability,
which a `Type` erases, comes from the mirror.

## The cross-reference check

The OpenAPI meta-schema checks each object's shape in isolation, so it cannot
see the faults that break a client generator rather than a validator.
`TomOpenApiDocumentCheck.problems` reports them, one sentence each:

- two operations sharing one `operationId`;
- a local `$ref` to a schema `components.schemas` does not define;
- a `{variable}` in a path with no path parameter, or a path parameter naming
  no variable of its path;
- one parameter (name and location) declared twice on an operation.

It runs in Dart, without Python. The generator applies it to every document it
builds and refuses an inconsistent one (`openapi.document.inconsistent`), and
the validator applies it on top of the meta-schema.

## Validation

`TomOpenApiValidator` validates a document against the **OpenAPI 3.1
meta-schema**, in its 2022-10-07 *schema-base* variant: the base variant also
validates every embedded schema object against the OpenAPI dialect (JSON
Schema 2020-12 plus the OpenAPI vocabulary), where the plain variant accepts
any schema object. The four schema files are vendored under
`lib/src/validation/schemas/` (Apache-2.0, from spec.openapis.org), so
validation needs no network.

The meta-schema runs through Python's `jsonschema` —
`lib/src/validation/validate_openapi.py` — because the reference JSON Schema
2020-12 implementation is Python's, and the Dart `json_schema` package cannot
load the OpenAPI schema. The interpreter is `python3`, `py -3` on Windows, or
the command `TOM_PYTHON` names (`TomOpenApiValidator.defaultPython`). The
cross-reference check is added to the meta-schema's findings.

**NOT MEASURED is never valid.** When the interpreter cannot be started, the
`jsonschema` module is missing, or the script answers no report, the result is
`measured: false` with the reason, and `isValid` is false:

```text
openapi/openapi.json: valid
openapi/openapi.json: NOT MEASURED — not measured: No module named 'jsonschema'
(in memory): 2 fault(s)
  /paths/~1notes/get: 'responses' is a required property
  operationId "readNote" is used by GET /notes/{id} and GET /notes
```

A file that is not a JSON object is a measured fault, not an unmeasured one:
the check ran and found the document broken.

## The Dart client

`TomOpenApiDartClientGenerator` writes one Dart library from a document. It
reads the document only — never the server — so it serves any OpenAPI 3.1
document of the shapes Tom writes. The library imports `dart:convert` and
`package:http` and nothing else.

**Models.** Every component schema of `type: object` with declared properties
becomes a class with a constructor, `fromJson` and `toJson`. A required member
is a `required` constructor parameter; an optional one is nullable, and
`toJson` leaves it out when it is `null` rather than sending `null`, since a
member may be optional without admitting `null`. A component without
properties — an `x-tom-opaque` type — is no class: a reference to it is a
`Map<String, Object?>`.

| Schema | Dart type | Decoded / encoded |
| ------ | --------- | ----------------- |
| `string` | `String` | as is |
| `string`, `format: date-time` | `DateTime` | `DateTime.parse`; `toUtc().toIso8601String()` |
| `string`, `x-tom-type: TomDateTime` | `DateTime` | the `@!@` prefix stripped, then parsed; written back behind `@!@` |
| `integer` | `int` | through `num`, so `1.0` decodes |
| `number` | `double` | through `num`, so `1` decodes |
| `boolean` | `bool` | as is |
| `array` | `List<T>` | element-wise |
| `object` with `additionalProperties` | `Map<String, T>` | value-wise |
| a `$ref` to a model | the model class | `fromJson` / `toJson` |
| anything else | `Object?` | as is |

A type admitting `null` is nullable. Class names are UpperCamel, member names
lowerCamel; a member named after a Dart keyword gains a `Value` suffix, and a
class named after a Dart type the generated code uses (`String`, `List`,
`DateTime`, …) or after the client gains a `Model` suffix.

**The client class.** `<ClientName>(Uri baseUri, {http.Client? httpClient,
String? bearerToken, String? apiKey})`, with a mutable `bearerToken` and
`apiKey`, and `close()`. One method
per operation, named after its `operationId`:

- path and query parameters are named arguments — `required` when the document
  requires them — and a path value is URL-encoded into the path;
- a JSON body is a typed `body` argument, `required` when the request body is;
- a multipart body is `fields` (`Map<String, String>`) and `files`
  (`List<http.MultipartFile>`);
- any other body is `Object? body`, sent as a string, as bytes, or JSON-encoded;
- a `200` with a JSON schema returns the decoded type; a `200` with no body
  returns `Future<void>`; an untyped body, or no `200` at all (a redirect),
  returns the raw `http.Response`.

**Authentication.** `bearerToken` is sent as `Authorization: Bearer …` only to
operations whose `security` is not empty, so a public operation never receives
it. When no `bearerToken` is set, `apiKey` is sent as `X-API-Key` to the same
operations instead — a client holds a signed-in user's token or a service
account's key, and a request carries one credential, never both. A public
operation receives neither.

**Failures.** Any status below `200` or from `400` up throws
`<ClientName>Exception` with `statusCode`, the raw `body`, the response
`headers`, and `errorKey` when the body is the framework error envelope. A
refused call is a `404` with no `errorKey`, as the document says; a
rate-limited one a `429` whose `errorKey` is `rate_limit.exceeded` and whose
`retryAfter` is the wait its `Retry-After` header names. The client does not
retry on its own: when to try again is the caller's decision.

`formatDartSource` runs `dart format` over the result; the command-line tool
always does, so a committed client is stable for a byte comparison.

## The command-line tool

`openapi` is a `tom_build_base` multi-command tool, written with its `:command`
syntax. `runTomOpenApiTool` runs it; `bin/openapi.dart` is the entry point for
`dart run tom_core_openapi:openapi`.

| Command | Does | Options |
| ------- | ---- | ------- |
| `:document` | writes the server's document | `--output <file>` (default `openapi/openapi.json`), `--title`, `--api-version`, `--description`, `--server <url>` (repeatable), `--exclude <prefix>` (repeatable), `--check` |
| `:dart-client` | writes a typed Dart client from a document | `--input <file>` (default `openapi/openapi.json`), `--output <file>`, `--client-name <Name>`, `--check` |
| `:validate` | validates documents | `--input <file>` (repeatable; default `openapi/openapi.json`) |

`:document` reads the server's reflection seed, so it runs from the server's
`tool/openapi.dart`; through `bin/openapi.dart`, which has no server to
prepare, it refuses and points there. `:dart-client` and `:validate` read a
document only and run anywhere.

`--check` compares with the file on disk instead of writing it, and fails when
the file is missing or differs — the form a test runs. `:validate` fails when
any document has a fault or was not measured.

## Error keys

`TomOpenApiException`, raised while generating:

| Key | When |
| --- | ---- |
| `openapi.document.duplicate_route` | two endpoints declare the same method on the same path |
| `openapi.document.inconsistent` | the built document fails `TomOpenApiDocumentCheck`; `parameters['problems']` lists the faults |
| `openapi.schema.type_not_reflected` | a type on the wire is not reflected, so its shape cannot be described |
| `openapi.schema.ambiguous_type` | two reflected classes share the simple name a component would take |

The endpoint that serves the document answers two `404`s of its own,
`openapi.document.not_served` and `openapi.document.missing`; they are
`tom_core_server`'s, described in its
[endpoints guide](../../../core/tom_core_server/doc/endpoints.md#the-openapi-document).

## Verification

```bash
dart test
```

| Suite | Pins |
| ----- | ---- |
| `test/openapi_document_generator_test.dart` | the document over a reflected fixture server (`test/fixtures/openapi_fixture.dart`): info and servers, framework endpoints present, sorted output, exclusion, operation ids, every parameter and body rule, every response rule, every security rule, and that the result validates |
| `test/openapi_schema_builder_test.dart` | type parsing, primitive and collection schemas, nullability, plain DTOs, `TomClass` observables, opaque types, the unreflected-type refusal |
| `test/openapi_document_check_test.dart` | each cross-reference rule |
| `test/openapi_validator_test.dart` | the meta-schema, the schema-base variant reaching embedded schemas, the cross-reference rules on top, NOT MEASURED, a non-JSON file |
| `test/dart_client_generator_test.dart` | the generated library's header and imports, models, that it analyzes clean, and a round trip against a loopback server: what it sends and what it decodes |
| `test/openapi_tool_test.dart` | the three commands and `--check` both ways |
| `test/examples_test.dart` | `example/tom_core_openapi_example.dart` runs all four steps |

The fixture's reflection seed is regenerated with `./reflection_generation.sh`.
The validator suites need `python3` with `jsonschema`.

The end-to-end chain is pinned in `tom_core_samples`: each sample server's
`test/openapi_document_test.dart` holds its committed document to its
annotations and to the meta-schema; `advanced_openapi_client`'s freshness test
holds the committed clients to the documents; and its live suite, run by
`advanced_client_core/tool/run_cross_tier_integration.sh`, logs in, reads and
writes through the generated clients and requires each running server to serve
the document its client was generated from.

# Tom Core OpenAPI API Reference: tom_core_openapi

OpenAPI 3.1 for Tom servers: the document generator, the schema builder it
uses, the cross-reference check, the meta-schema validator, the typed Dart
client generator, and the `openapi` command-line tool over all of them. One
library, `package:tom_core_openapi/tom_core_openapi.dart`.

For the rules the generator follows — which parameter becomes what, how a DTO
becomes a schema, what the responses and the security say — see
[openapi_generation.md](../openapi_generation.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomOpenApiInfo](#tomopenapiinfo)
  - [TomOpenApiDocumentGenerator](#tomopenapidocumentgenerator)
  - [TomOpenApiDartType](#tomopenapidarttype)
  - [TomOpenApiSchemaBuilder](#tomopenapischemabuilder)
  - [TomOpenApiException](#tomopenapiexception)
  - [TomOpenApiDocumentCheck](#tomopenapidocumentcheck)
  - [TomOpenApiValidation](#tomopenapivalidation)
  - [TomOpenApiValidator](#tomopenapivalidator)
  - [TomOpenApiDartClientGenerator](#tomopenapidartclientgenerator)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

Source: `lib/src/document/openapi_document_generator.dart`,
`lib/src/document/openapi_schema_builder.dart`,
`lib/src/document/openapi_document_check.dart`,
`lib/src/validation/openapi_validator.dart`,
`lib/src/client/dart_client_generator.dart`,
`lib/src/cli/openapi_tool.dart`.

| File | Declares |
| ---- | -------- |
| `openapi_document_generator.dart` | `TomOpenApiInfo`, `TomOpenApiDocumentGenerator` |
| `openapi_schema_builder.dart` | `TomOpenApiDartType`, `TomOpenApiSchemaBuilder`, `TomOpenApiException` |
| `openapi_document_check.dart` | `TomOpenApiDocumentCheck` |
| `openapi_validator.dart` | `TomOpenApiValidation`, `TomOpenApiValidator` |
| `dart_client_generator.dart` | `TomOpenApiDartClientGenerator` |
| `openapi_tool.dart` | `runTomOpenApiTool`, `createTomOpenApiExecutors`, `formatDartSource`, `tomOpenApiTool`, the three command definitions, `tomOpenApiToolVersion`, `defaultOpenApiDocumentPath` |

The generator reads a server's endpoints exactly as `TomEndpointRouting` finds
them, so it needs the server's reflection seed and API registrations and
nothing else — no instance, no configuration, no database. Everything that
reads a *document* (the check, the validator, the client generator) needs no
reflection at all.

`lib/src/validation/` also ships `validate_openapi.py` and the vendored
OpenAPI 3.1 meta-schema files under `schemas/`; they are resources the
validator runs, not Dart API.

## Class Hierarchy

```
TomOpenApiInfo
TomOpenApiDocumentGenerator
TomOpenApiDartType
TomOpenApiSchemaBuilder
TomOpenApiDocumentCheck  (abstract final)
TomOpenApiValidation
TomOpenApiValidator
TomOpenApiDartClientGenerator

TomException  (tom_core_kernel)
    └── TomOpenApiException
```

## Classes

### TomOpenApiInfo

The `info` block of a generated document.

#### Constructors

```dart
const TomOpenApiInfo({
  required this.title,
  required this.version,
  this.description,
})
```

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `title` | `String` | The API's title. |
| `version` | `String` | The API's version — the server's, not the OpenAPI version. |
| `description` | `String?` | A longer description, or `null`. |

### TomOpenApiDocumentGenerator

Builds the OpenAPI document of the endpoints the reflector knows. `generate`
registers the framework's API contracts, scans every `@tomService` and
`@TomApiImplementation` class, and resolves each annotated method to its
`TomEndpoint` — the router's own steps — so the document lists what the server
mounts, framework endpoints included. WebSocket endpoints are skipped; an
`OPTIONS` method is never listed. Paths, tags, methods and component schemas
are sorted, so the output is deterministic and a committed copy diffs cleanly.
Every operation states a `404`, a `429` with a `Retry-After` header — a rate
limit is deployment configuration any operation may be under — and a `default`
error response; an authenticated operation's `security` is
`[{bearerAuth: []}, {apiKeyAuth: []}]`, a bearer token or an API key.

```dart
registerMyApis();
initializeReflection();
final document = TomOpenApiDocumentGenerator(
  info: const TomOpenApiInfo(title: 'My server', version: '1.0.0'),
).generate();
```

#### Constructors

```dart
TomOpenApiDocumentGenerator({
  required this.info,
  this.servers = const [],
  this.excludePathPrefixes = const [],
  this.services,
})
```

#### Static Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `openApiVersion` | `String` | The OpenAPI version written into every document, `3.1.0` (a `const`). |
| `bearerScheme` | `String` | The security scheme of a bearer token, `bearerAuth` (a `const`): HTTP bearer with a JWT. Every authenticated operation names it. |
| `apiKeyScheme` | `String` | The security scheme of a service account's API key, `apiKeyAuth` (a `const`): `type: apiKey` in the `X-API-Key` header. Every authenticated operation names it as the alternative to `bearerScheme`. |
| `errorSchema` | `String` | The component describing the framework's error envelope, `TomError` (a `const`). |
| `contextTypes` | `Set<String>` | The parameter types the pipeline supplies from the request itself and a caller never sends: `TomPrincipal`, `TomClientJwtToken`, `TomExecutionContext`, `TomRequestLogInfo`. |
| `primitiveParameterTypes` | `Set<String>` | The parameter types bound from a path variable or a query parameter: `String`, `int`, `double`, `num`, `bool`. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `info` | `TomOpenApiInfo` | The document's `info` block. |
| `servers` | `List<String>` | The base URLs a client may call, in order of preference; the `servers` block is omitted when empty. |
| `excludePathPrefixes` | `List<String>` | Path prefixes left out of the document, for a surface a client should not see (`/scim`, say). |
| `services` | `List<ClassMirror>?` | The service classes to describe, or `null` for every one the router would mount. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `openApiPath` | `static String openApiPath(String uri)` | A Tom route template as an OpenAPI path: a `<name>` capture becomes `{name}`, and an empty route is `/`. |
| `returnTypeOf` | `static TomOpenApiDartType returnTypeOf(MethodMirror method)` | What a method answers with, without its `Future`. Read from the reflected return `Type` when the data carries one, because a `Type` keeps every type argument; falls back to the return-type mirror. |
| `operationKey` | `static String operationKey(TomHttpMethod method)` | The key of an operation in a path item — the method name in lower case. |
| `captures` | `static List<String> captures(String path)` | The `{variable}` names of an OpenAPI path, in order. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `generate` | `Map<String, Object?> generate()` | Builds the document. Throws `TomOpenApiException` when an endpoint cannot be described (`openapi.document.duplicate_route`, `openapi.schema.*`) or when the result fails `TomOpenApiDocumentCheck` (`openapi.document.inconsistent`). |
| `generateJson` | `String generateJson()` | `generate`, encoded with two-space indentation and a final newline — the form written to disk, stable for a byte comparison. |

### TomOpenApiDartType

A Dart type as the schema builder reasons about it: a name, its type
arguments, whether it admits `null`, and — when it came from a declaration — its
class mirror.

#### Constructors

```dart
const TomOpenApiDartType(
  this.name, {
  this.arguments = const [],
  this.nullable = false,
  this.mirror,
})
```

#### Factory Constructors

```dart
factory TomOpenApiDartType.parse(String text)
factory TomOpenApiDartType.fromMirror(TypeMirror mirror)
factory TomOpenApiDartType.fromDeclaration(VariableMirror declaration)
```

| Factory | Description |
| ------- | ----------- |
| `parse` | Parses a type as Dart prints it — `List<Workspace>`, `Map<String, Object?>`, `Future<void>` — splitting arguments by bracket depth. Used for the registry's `responseType` and for reflected `Type`s, which keep every type argument. |
| `fromMirror` | Reads a type mirror: nullability and the first level of type arguments, which is all the reflection data carries. |
| `fromDeclaration` | Reads a field or parameter. The shape comes from the declaration's reflected `Type`; only top-level nullability, which a `Type` erases, comes from the mirror. The mirror's own type arguments are not used, because the generated reflection data can attach the wrong class to an argument mirror. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `name` | `String` | The simple name, without type arguments (`List`, `Workspace`). |
| `arguments` | `List<TomOpenApiDartType>` | The type arguments, outermost first. |
| `nullable` | `bool` | Whether the type admits `null`. |
| `mirror` | `ClassMirror?` | The class mirror, when the type was read from a declaration and the mirror names the same class. |
| `awaited` | `TomOpenApiDartType` | This type without its `Future` / `FutureOr` wrapper. |
| `isVoid` | `bool` | Whether the type has no value on the wire: `void`, `Null` or `Never`. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `toString` | `String toString()` | The type in Dart syntax, `List<Workspace>?`. |

### TomOpenApiSchemaBuilder

Turns Dart types into OpenAPI 3.1 schema objects and collects every reflected
class it reaches as a named component. The schemas describe what the kernel
serializer (`TomReflectionInfo.getValues`) actually writes, not the Dart
declaration alone; see
[openapi_generation.md](../openapi_generation.md#schemas).

#### Constructors

```dart
TomOpenApiSchemaBuilder()
```

#### Static Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `primitives` | `Map<String, Map<String, Object?>>` | The primitive Dart types and their schemas: `String`, `int` (`integer`, 64-bit format), `double` (`number`, `double` format), `num`, `bool`, `DateTime` (`string`, `date-time`), `Uri` (`string`, `uri`), `Duration` (`integer`, `x-tom-type: Duration`) and the three zoned kernel types (`string`, `x-tom-type`). |
| `tomDateTime` | `Map<String, Object?>` | The wire form of an observable `TomDateTime` member: a `string` with `pattern: ^@!@` and `x-tom-type: TomDateTime`, deliberately not `format: date-time`. |
| `observables` | `Map<String, (String, bool)>` | The observable `TomClass` member types and the value type each carries, with whether it admits `null` (the `N` variants). |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `components` | `Map<String, Map<String, Object?>>` | The named component schemas built so far, by component name. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `nullableOf` | `static Map<String, Object?> nullableOf(Map<String, Object?> schema)` | A schema widened to admit `null`: `"null"` joins a type list, and a reference is wrapped in `anyOf` with `{type: null}`. An empty schema already admits anything. |
| `resolveClass` | `static ClassMirror resolveClass(String name)` | The reflected class with that simple name. Throws `TomOpenApiException` keyed `openapi.schema.type_not_reflected` when none is reflected and `openapi.schema.ambiguous_type` when two are. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `schemaOf` | `Map<String, Object?> schemaOf(TomOpenApiDartType type)` | The schema of a type, registering any class it reaches as a component and answering a `$ref` to it. A class refused for its name raises `TomOpenApiException`. |

### TomOpenApiException

A failure to describe a server as an OpenAPI document, keyed
`openapi.<area>.<condition>`.

- **Extends:** `TomException`

#### Constructors

```dart
TomOpenApiException(
  String key,
  String defaultUserMessage, {
  Map<String, Object?>? parameters,
})
```

### TomOpenApiDocumentCheck

The consistency rules a document must meet that the OpenAPI meta-schema cannot
express, because the meta-schema checks each object in isolation. Each broken
rule breaks a client generator rather than a validator. Runs without Python, so
the generator applies it to everything it writes.

```dart
abstract final class TomOpenApiDocumentCheck
```

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `problems` | `static List<String> problems(Map<String, Object?> document)` | Every fault in the document, one sentence each; empty when it is sound. Checked: `operationId`s are unique; every local `$ref` resolves; every `{variable}` of a path has a path parameter and every path parameter names a variable of its path; no operation declares one parameter (name and location) twice. |

### TomOpenApiValidation

The outcome of validating one document.

#### Constructors

```dart
const TomOpenApiValidation({
  required this.path,
  required this.measured,
  this.errors = const [],
  this.reason,
})
```

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `path` | `String` | The document that was validated; `(in memory)` for `validateDocument`. |
| `measured` | `bool` | Whether the meta-schema validation ran. A check that did not run has not passed. |
| `errors` | `List<String>` | The faults found, one sentence each — the cross-reference problems and the meta-schema errors (`<location>: <message>`). |
| `reason` | `String?` | Why the meta-schema validation did not run, when `measured` is false. |
| `isValid` | `bool` | Whether the document was measured **and** found sound. Never true for an unmeasured document. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `toString` | `String toString()` | `<path>: valid`, `<path>: NOT MEASURED — <reason>`, or `<path>: N fault(s)` followed by one line per fault. |

### TomOpenApiValidator

Validates documents against the OpenAPI 3.1 meta-schema — the 2022-10-07
*schema-base* variant, which also checks every embedded schema object against
the OpenAPI dialect — and against `TomOpenApiDocumentCheck`. The meta-schema
runs through Python's `jsonschema` (`validate_openapi.py` beside the library,
over the vendored schema files), because the Dart `json_schema` package cannot
load the OpenAPI schema.

#### Constructors

```dart
TomOpenApiValidator({List<String>? python})
```

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `python` | `List<String>` | The interpreter command and its leading arguments. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `defaultPython` | `static List<String> defaultPython()` | `TOM_PYTHON` split on whitespace when set; otherwise `py -3` on Windows and `python3` elsewhere. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `validateDocument` | `Future<TomOpenApiValidation> validateDocument(Map<String, Object?> document)` | Validates a document held in memory, through a scratch copy under `.dart_tool/tom_core_openapi/` of the working directory. |
| `validateFile` | `Future<TomOpenApiValidation> validateFile(String documentPath)` | Validates the document at a path. A file that is not a JSON object is a measured fault; an interpreter that cannot start, a missing `jsonschema` module or an unreadable report is **not measured**, with the reason. |

### TomOpenApiDartClientGenerator

Generates a typed Dart client library from an OpenAPI 3.1 document. The
generated code depends on `package:http` and nothing else — no Tom package, no
reflection. It reads the document only, never a server. The generated client is
constructed as `<clientName>(Uri baseUri, {http.Client? httpClient, String?
bearerToken, String? apiKey})`; a secured operation sends `bearerToken` as
`Authorization: Bearer …` when it is set, else `apiKey` as `X-API-Key`, and a
public operation sends neither.

#### Constructors

```dart
TomOpenApiDartClientGenerator({
  required this.clientName,
  this.regenerateCommand,
})
```

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `clientName` | `String` | The name of the generated client class; the exception class is `<clientName>Exception`. |
| `regenerateCommand` | `String?` | The command that regenerates the file, stated in its header. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `generate` | `String generate(Map<String, Object?> document)` | The Dart source of the client library, unformatted; `formatDartSource` formats it. |

## Global Functions and Constants

```dart
Future<void> runTomOpenApiTool(
  List<String> args, {
  void Function()? prepare,
  String? title,
  String? description,
  List<String> servers = const [],
})

Map<String, CommandExecutor> createTomOpenApiExecutors({
  void Function()? prepare,
  String? title,
  String? description,
  List<String> servers = const [],
})

Future<String> formatDartSource(String source)
```

| Name | Signature | Description |
| ---- | --------- | ----------- |
| `runTomOpenApiTool` | `Future<void> runTomOpenApiTool(List<String> args, {...})` | Runs the `openapi` tool. `prepare` makes the server's endpoints visible (API registration, `initializeReflection`) and is called before `:document`; `title`, `description` and `servers` are the document's defaults where the command line gives no `--title`, `--description` or `--server`. |
| `createTomOpenApiExecutors` | `Map<String, CommandExecutor> createTomOpenApiExecutors({...})` | The executors of the three commands, keyed `document`, `dart-client` and `validate`. |
| `formatDartSource` | `Future<String> formatDartSource(String source)` | Formats Dart source with `dart format`, through a scratch file under `.dart_tool/tom_core_openapi/`. Throws `StateError` when `dart format` fails. |
| `tomOpenApiTool` | `final ToolDefinition tomOpenApiTool` | The `tom_build_base` tool definition: multi-command, default command `validate`. |
| `openApiDocumentCommand` | `const CommandDefinition openApiDocumentCommand` | The `:document` command and its options. |
| `openApiDartClientCommand` | `const CommandDefinition openApiDartClientCommand` | The `:dart-client` command and its options. |
| `openApiValidateCommand` | `const CommandDefinition openApiValidateCommand` | The `:validate` command and its options. |
| `tomOpenApiToolVersion` | `const String tomOpenApiToolVersion` | The tool's version, `0.1.0`. |
| `defaultOpenApiDocumentPath` | `const String defaultOpenApiDocumentPath` | The document path the commands default to, relative to the package root: `openapi/openapi.json`. |

# tom_core_openapi

Published on pub.dev as [`tom_core_openapi` 0.2.0](https://pub.dev/packages/tom_core_openapi).

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed and published on pub.dev.

OpenAPI 3.1 for Tom servers. It writes a server's OpenAPI document from the
endpoint annotations and reflected DTOs the server already has, validates any
OpenAPI 3.1 document against the official meta-schema, and generates a typed
Dart client from a document — a client that depends on `package:http` and
nothing else.

## Why it exists

A Tom server's routes are declared once, on the methods that serve them, and
`tom_core_server` derives its route table from those annotations at start-up.
A caller that is not a Tom client — a TypeScript front end, a partner's
service, an API browser — has had no way to learn that surface except by
reading the Dart. This package publishes it in the one format every such caller
already reads.

**The document is a build step, not a runtime feature.** It is generated from
the server's reflection seed by a command a developer runs, committed beside
the server, and served as a file by `GET /openapi.json` (`tom_core_server`'s
`TomOpenApiServer`, switched on by the `openApiDocument` setting). A file
written by the build is reviewed like any other change, is the same on every
node of a deployment, and is what a client generator reads anyway; a document
generated per request would be an artefact nobody reviewed, and every server
would carry the generator. A `--check` mode keeps the committed file honest:
it fails when the file is not what the annotations generate today.

## Installation

Add it from pub.dev, as a **`dev_dependency`** of the server whose document it writes:

```yaml
dev_dependencies:
  tom_core_openapi: ^0.2.0
```

```dart
import 'package:tom_core_openapi/tom_core_openapi.dart';
```

Validation runs Python's `jsonschema` (with `referencing`, which it brings
along). Install it once per machine with `pip install jsonschema`; the
interpreter is `python3`, `py -3` on Windows, or whatever `TOM_PYTHON` names.

## Features

| Type | What it does |
| ---- | ------------ |
| `TomOpenApiDocumentGenerator` · `TomOpenApiInfo` | Builds the OpenAPI 3.1 document of every endpoint the router would mount — framework endpoints included — from the annotations and the reflection seed. Every authenticated operation accepts a bearer token (`bearerAuth`) or a service account's API key (`apiKeyAuth`, `X-API-Key`), and every operation states the `429` a rate limit answers, with `Retry-After`. Error bodies are offered as the framework envelope (`TomError`, `application/json`) and as an RFC 9457 problem document (the `'TomProblem'` component, `application/problem+json`); a versioned API's operations sit under their `/v<version>` segment. Deterministic, sorted output. |
| `TomOpenApiSchemaBuilder` · `TomOpenApiDartType` | Turns Dart types into JSON Schema 2020-12 schemas that follow the kernel serializer, not the declaration: plain DTOs, `TomClass` observables, self-rendering types, nullability. |
| `TomOpenApiDocumentCheck` | The cross-reference rules the meta-schema cannot express: unique `operationId`s, resolvable `$ref`s, path variables matched to path parameters, no duplicate parameter. |
| `TomOpenApiValidator` · `TomOpenApiValidation` | The OpenAPI 3.1 meta-schema (*schema-base* variant, vendored) through Python's `jsonschema`, plus the cross-reference check. A validation that could not run is **NOT MEASURED**, never valid. |
| `TomOpenApiDartClientGenerator` | A typed Dart client: one class per object schema, one method per operation, a `bearerToken` or an `apiKey` sent to secured operations, a `<Client>Exception` carrying the status and the error key. |
| `runTomOpenApiTool` | The `openapi` command-line tool on `tom_build_base`: `:document`, `:dart-client`, `:validate`. |
| `TomOpenApiException` | The generator's refusals, keyed `openapi.document.*` and `openapi.schema.*`. |

## Quick start — publishing a server's document

`:document` reads the server's reflection seed, so it runs from a small entry
point **inside the server package**, `tool/openapi.dart`, which registers the
server's API contracts and installs its seed before generating. This is
`tom_core_samples/advanced_app_server/tool/openapi.dart`:

```dart
import 'package:advanced_todo_contracts/advanced_todo_contracts.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

import '../bin/app_server_start.reflection.dart';

Future<void> main(List<String> args) => runTomOpenApiTool(
  args,
  prepare: () {
    registerAdvancedTodoApis();
    initializeReflection();
  },
  title: 'Advanced App Server',
  description: 'The secured task API of the advanced sample.',
  servers: const ['http://localhost:8080'],
);
```

Stating the title, description and servers here — rather than on the command
line — is what lets `:document --check` reproduce the committed document
without anyone remembering how it was written. Then:

```bash
dart run tool/openapi.dart :document           # writes openapi/openapi.json
dart run tool/openapi.dart :document --check   # fails when the file is stale
dart run tool/openapi.dart :validate           # meta-schema + cross-references
```

Commit `openapi/openapi.json`, and point the server at it in its configuration
resources so `GET /openapi.json` serves it:

```yaml
openApiDocument: "openapi/openapi.json"
```

A suite test that runs `:document --check` and `:validate` keeps the committed
document current; `advanced_app_server/test/openapi_document_test.dart` is the
worked example.

## Quick start — calling a server from its document

A consumer needs the document only, never the server's code:

```bash
dart run tom_core_openapi:openapi :dart-client \
    --input openapi/openapi.json --output lib/app_api.dart --client-name AppApi
```

The generated library is formatted with `dart format` and headed with the
command that regenerates it. Calling through it:

```dart
import 'package:advanced_openapi_client/app_api.dart';

Future<void> main() async {
  final app = AppApi(Uri.parse('http://localhost:8080'), bearerToken: token);
  try {
    final workspaces = await app.appListWorkspaces(); // List<Workspace>
    print(workspaces.first.name);
  } on AppApiException catch (e) {
    print('${e.statusCode} ${e.errorKey}');
  } finally {
    app.close();
  }
}
```

`token` is whatever the server's login returned — through the generated client
of the identity server, in the advanced sample. The bearer token is sent only
to operations the document marks as secured.

A service account calls with its API key instead — the client sends it as
`X-API-Key` to the same operations when no bearer token is set:

```dart
final app = AppApi(Uri.parse('http://localhost:8080'), apiKey: 'tomk.<keyId>.<secret>');
```

**Other languages.** The document is standard OpenAPI 3.1, so any standard
generator reads it — `openapi-typescript`, `openapi-generator`, an API
browser. A TypeScript client is not generated here for that reason. The one Tom
wire convention a standard generator cannot know — an observable `TomDateTime`
member sent as `@!@<ISO-8601>` — is marked `x-tom-type: TomDateTime` with a
`pattern`, so such a generator types it as a string, which is correct.

## The `openapi` command

| Command | Runs from | Options |
| ------- | --------- | ------- |
| `:document` | the server package's `tool/openapi.dart` | `--output` (default `openapi/openapi.json`), `--title` (default: the title `runTomOpenApiTool` was given, else the pubspec `name`), `--api-version` (default: the pubspec `version`), `--description` and `--server <url>` (repeatable) (default: what `runTomOpenApiTool` was given), `--exclude <prefix>` (repeatable), `--check` |
| `:dart-client` | anywhere — `dart run tom_core_openapi:openapi` | `--input` (default `openapi/openapi.json`), `--output` (required), `--client-name` (required), `--check` |
| `:validate` | anywhere | `--input <file>` (repeatable; default `openapi/openapi.json`) |

`--check` compares instead of writing and exits non-zero when the file is
missing or stale. `:validate` exits non-zero when any document has a fault
**or was not measured**. `:document` run from `bin/openapi.dart` — without a
server's preparation — refuses with a pointer to `tool/openapi.dart`.

## Limits

- **WebSocket endpoints are not described.** OpenAPI has no vocabulary for a
  socket conversation; the generator leaves them out rather than describe the
  handshake as an ordinary `GET`.
- **No TypeScript or other-language client is generated.** Use a standard
  generator over the document.
- **Validation needs Python's `jsonschema`.** The Dart `json_schema` package
  cannot load the OpenAPI 3.1 schema. Without Python the cross-reference check
  still runs, and the result says NOT MEASURED.
- **A type the reflection seed does not carry cannot be described.** The
  generator refuses it by name (`openapi.schema.type_not_reflected`) rather than
  guess a shape; two reflected classes sharing a simple name are refused the
  same way (`openapi.schema.ambiguous_type`).
- **The generated client does not retry.** A rate-limited call throws
  `<Client>Exception` with status `429`, the error key `rate_limit.exceeded`,
  the response headers and `retryAfter`; when to try again is the caller's
  decision.
- **A self-rendering type is opaque.** A DTO with its own `toJson`, a
  `jsonEncode` getter or `TomJsonSerializable` is described as an object marked
  `x-tom-opaque`, because no declaration states its shape.

## Further documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/openapi_generation.md](doc/openapi_generation.md) | Every rule the generator follows — operations, parameters, bodies, responses, security, schemas — the client generator's mapping, validation, and the error keys |
| [doc/api/api_summary_tom_core_openapi.md](doc/api/api_summary_tom_core_openapi.md) | Every public type and member |

**Runnable example:** [`example/tom_core_openapi_example.dart`](example/tom_core_openapi_example.dart)
walks the document side — the cross-reference check, the meta-schema, a
generated client, a broken document refused — and checks every step:

```bash
dart run example/tom_core_openapi_example.dart
```

`test/examples_test.dart` runs it and requires all four steps to report.

**Worked integration:** in `tom_core_samples`, `advanced_app_server` and
`advanced_auth_server` publish their documents, and `advanced_openapi_client`
holds the two clients generated from them, a freshness test, and a live suite
that calls both running servers through the generated code.

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `tom_core_server` | runtime | the endpoint scan (`TomEndpointRouting`), the annotations and the reflection types |
| `tom_core_kernel` | runtime | `TomException`, the access-control annotations, `TomHttpMethod`, `TomMimeType` |
| `tom_build_base` | runtime | the command-line tool (`ToolDefinition`, `ToolRunner`) |
| `path` | runtime | file paths for the scratch files and the vendored schemas |
| `test`, `lints`, `shelf` | dev | the suite |
| `build`, `build_runner`, `tom_reflection_generator` | dev | the test fixture's reflection seed (`./reflection_generation.sh`) |

## Status

Version **0.2.0**. The suite runs with `dart test`; the meta-schema tests need
`python3` with `jsonschema`. Every document this package writes passes its own
`TomOpenApiDocumentCheck` before it is returned.

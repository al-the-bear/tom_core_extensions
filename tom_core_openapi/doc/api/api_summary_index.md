# Tom Core OpenAPI API Reference: Index

API summaries for `tom_core_openapi` — OpenAPI 3.1 for Tom servers: the
document generator, the schema builder it uses, the cross-reference check, the
meta-schema validator, the typed Dart client generator, and the `openapi`
command-line tool over all of them. The package has one library,
`package:tom_core_openapi/tom_core_openapi.dart`, documented in one summary.

The summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors and members, top-level functions and
constants). Only public members are listed; `_`-prefixed declarations are
omitted.

## Quick Navigation

| Module Reference | Module Guide | Description |
| ---------------- | ------------ | ----------- |
| [tom_core_openapi](api_summary_tom_core_openapi.md) | [Guide](../openapi_generation.md) | The OpenAPI document of a server's endpoints, its schemas and checks, the meta-schema validator, the typed Dart client, and the `openapi` tool. |

## tom_core_openapi Module

### Classes

| Class | Description | Link |
| ----- | ----------- | ---- |
| `TomOpenApiInfo` | The `info` block of a generated document. | [→](api_summary_tom_core_openapi.md#tomopenapiinfo) |
| `TomOpenApiDocumentGenerator` | Builds the OpenAPI document of the endpoints the reflector knows. | [→](api_summary_tom_core_openapi.md#tomopenapidocumentgenerator) |
| `TomOpenApiDartType` | A Dart type as the schema builder reasons about it. | [→](api_summary_tom_core_openapi.md#tomopenapidarttype) |
| `TomOpenApiSchemaBuilder` | Turns Dart types into OpenAPI 3.1 schema objects and collects every reflected type they reach. | [→](api_summary_tom_core_openapi.md#tomopenapischemabuilder) |
| `TomOpenApiException` | A failure to describe a server as an OpenAPI document, keyed. | [→](api_summary_tom_core_openapi.md#tomopenapiexception) |
| `TomOpenApiDocumentCheck` | The consistency rules a document must meet that the meta-schema cannot express. | [→](api_summary_tom_core_openapi.md#tomopenapidocumentcheck) |
| `TomOpenApiValidation` | The outcome of validating one document. | [→](api_summary_tom_core_openapi.md#tomopenapivalidation) |
| `TomOpenApiValidator` | Validates documents against the OpenAPI 3.1 meta-schema. | [→](api_summary_tom_core_openapi.md#tomopenapivalidator) |
| `TomOpenApiDartClientGenerator` | Generates a typed Dart client library from an OpenAPI 3.1 document. | [→](api_summary_tom_core_openapi.md#tomopenapidartclientgenerator) |

### Functions

| Function | Signature | Description | Link |
| -------- | --------- | ----------- | ---- |
| `runTomOpenApiTool` | `Future<void> runTomOpenApiTool(List<String> args, {...})` | Runs the `openapi` tool. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |
| `createTomOpenApiExecutors` | `Map<String, CommandExecutor> createTomOpenApiExecutors({...})` | The executors of `:document`, `:dart-client` and `:validate`. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |
| `formatDartSource` | `Future<String> formatDartSource(String source)` | Formats Dart source with `dart format`. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |

### Global Variables

| Variable | Type | Description | Link |
| -------- | ---- | ----------- | ---- |
| `tomOpenApiTool` | `ToolDefinition` | The `tom_build_base` tool definition of `openapi`. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |
| `openApiDocumentCommand` | `CommandDefinition` | The `:document` command. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |
| `openApiDartClientCommand` | `CommandDefinition` | The `:dart-client` command. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |
| `openApiValidateCommand` | `CommandDefinition` | The `:validate` command. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |
| `tomOpenApiToolVersion` | `String` | The tool's version. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |
| `defaultOpenApiDocumentPath` | `String` | The document path the commands default to: `openapi/openapi.json`. | [→](api_summary_tom_core_openapi.md#global-functions-and-constants) |

## Alphabetical Class Index

| Class | Module |
| ----- | ------ |
| `TomOpenApiDartClientGenerator` | tom_core_openapi |
| `TomOpenApiDartType` | tom_core_openapi |
| `TomOpenApiDocumentCheck` | tom_core_openapi |
| `TomOpenApiDocumentGenerator` | tom_core_openapi |
| `TomOpenApiException` | tom_core_openapi |
| `TomOpenApiInfo` | tom_core_openapi |
| `TomOpenApiSchemaBuilder` | tom_core_openapi |
| `TomOpenApiValidation` | tom_core_openapi |
| `TomOpenApiValidator` | tom_core_openapi |

## Alphabetical Function Index

| Function | Module |
| -------- | ------ |
| `createTomOpenApiExecutors` | tom_core_openapi |
| `formatDartSource` | tom_core_openapi |
| `runTomOpenApiTool` | tom_core_openapi |

## Alphabetical Global Variable Index

| Variable | Module |
| -------- | ------ |
| `defaultOpenApiDocumentPath` | tom_core_openapi |
| `openApiDartClientCommand` | tom_core_openapi |
| `openApiDocumentCommand` | tom_core_openapi |
| `openApiValidateCommand` | tom_core_openapi |
| `tomOpenApiTool` | tom_core_openapi |
| `tomOpenApiToolVersion` | tom_core_openapi |

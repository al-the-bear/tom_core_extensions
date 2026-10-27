# tom_core_openapi — documentation

The catalogue of this package's documentation. The package
[README](../README.md) says what the package is for, how a server publishes its
document and how a consumer calls a server from it; the pages below carry the
detail.

| Document | Covers |
| -------- | ------ |
| [openapi_generation.md](openapi_generation.md) | Why the document is a build step; how a server is set up for it; every rule the generator follows for operations, parameters, request bodies, responses, security and schemas; the cross-reference check and the validator; the Dart client generator's mapping; the command-line tool; the error keys |
| [api/api_summary_tom_core_openapi.md](api/api_summary_tom_core_openapi.md) | Every public type, member, function and constant, with signatures |

**Elsewhere in the repository:**

| Document | Covers |
| -------- | ------ |
| [`tom_core_server/doc/endpoints.md`](../../../core/tom_core_server/doc/endpoints.md#the-openapi-document) | `GET /openapi.json` — the endpoint that serves the generated document |
| [`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#publishing-the-openapi-document) | The `openApiDocument` setting that switches serving on |
| [`tom_core_samples/advanced_openapi_client/README.md`](../../../core/tom_core_samples/advanced_openapi_client/README.md) | Two generated clients and the live suite that calls the sample servers through them |

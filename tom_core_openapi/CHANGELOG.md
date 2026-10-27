# Changelog

## Unreleased

### Added

- **`apiKeyAuth`** (`TomOpenApiDocumentGenerator.apiKeyScheme`): a security
  scheme of `type: apiKey` in the `X-API-Key` header — a service account's key
  — defined beside `bearerAuth`. Every authenticated operation's `security`
  names both as alternative requirements, `[{bearerAuth: []}, {apiKeyAuth: []}]`.
- **A `429` response on every operation**, with the framework error envelope
  and a `Retry-After` header (`integer`, `minimum: 1`), because rate limits are
  deployment configuration any operation may be under.
- **`apiKey` on the generated Dart client**: a constructor parameter and a
  mutable field, sent as `X-API-Key` to secured operations when no
  `bearerToken` is set; public operations send neither.

## 0.1.0

### Added

- **`TomOpenApiDocumentGenerator`** and **`TomOpenApiInfo`**: an OpenAPI 3.1.0
  document of every endpoint a server mounts, read off the endpoint
  annotations through the router's own scan (`registerFrameworkApis`,
  `scanClasses`, `getClassMethodMetadata`), framework endpoints included and
  WebSocket endpoints left out. `excludePathPrefixes` drops part of the
  surface; paths, tags, methods and schemas are sorted, and `generateJson`
  writes the stable on-disk form. Operation ids, parameters, request bodies,
  responses (`404` and the framework error envelope on every operation) and
  security (`bearerAuth`, `security: []` for public endpoints, `x-tom-access`
  for role rules) follow the rules in `doc/openapi_generation.md`.
- **`TomOpenApiSchemaBuilder`** and **`TomOpenApiDartType`**: schemas that follow
  the kernel serializer — plain DTO fields, `TomClass` observables, the `@!@`
  wire form of an observable `TomDateTime` (`TomOpenApiSchemaBuilder.tomDateTime`),
  `x-tom-opaque` for self-rendering types, JSON Schema 2020-12 nullability.
  Declaration types are read from the reflected `Type`.
- **`TomOpenApiException`**, keyed `openapi.document.duplicate_route`,
  `openapi.document.inconsistent`, `openapi.schema.type_not_reflected` and
  `openapi.schema.ambiguous_type`.
- **`TomOpenApiDocumentCheck.problems`**: unique `operationId`s, resolvable
  `$ref`s, path variables matched to path parameters, no duplicate parameter.
- **`TomOpenApiValidator`** and **`TomOpenApiValidation`**: the OpenAPI 3.1
  meta-schema (2022-10-07 *schema-base* variant, vendored from
  spec.openapis.org under Apache-2.0) through Python's `jsonschema`
  (`lib/src/validation/validate_openapi.py`), plus the cross-reference check.
  An unmeasured validation is never valid. `TOM_PYTHON` overrides the
  interpreter; Windows uses `py -3`.
- **`TomOpenApiDartClientGenerator`**: a typed Dart client depending on
  `package:http` only — a class per object schema, a method per operation named
  by its `operationId`, `<Client>Exception` with `statusCode`, `body` and
  `errorKey`, the bearer token sent to secured operations only, and the `@!@`
  `TomDateTime` convention decoded and encoded.
- **The `openapi` tool** on `tom_build_base` (`runTomOpenApiTool`,
  `createTomOpenApiExecutors`, `tomOpenApiTool`): `:document` from a server's
  `tool/openapi.dart`, `:dart-client` and `:validate` from
  `dart run tom_core_openapi:openapi`; `--check` on both writers.
  `formatDartSource` formats generated code with `dart format`.
- `example/tom_core_openapi_example.dart`, `doc/index.md`,
  `doc/openapi_generation.md` and `doc/api/api_summary_tom_core_openapi.md`.

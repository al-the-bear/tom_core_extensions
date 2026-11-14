# Tom Core Secrets Local API Reference: tom_core_secrets/local.dart

The Tom Secrets Manager as a secrets provider for Tom servers. One library,
`package:tom_core_secrets/local.dart`.

For the reference syntax, configuration, approvals and the error keys, see
[local_secrets.md](../local_secrets.md); for the framework side (`TomSecrets`,
`TomSecretsProvider`, `TomSecretPayload`, `TomSecretsException`),
`tom_core_server`'s
[configuration API summary](../../../../core/tom_core_server/doc/api/api_summary_configuration.md);
for the client it talks through, `tom_secrets_client`.

## Table of Contents

- [Overview](#overview)
- [Classes](#classes)
  - [TomLocalSecretsProvider](#tomlocalsecretsprovider)

## Overview

Source: `lib/src/local/local_secrets_provider.dart`, which declares
`TomLocalSecretsProvider`.

The provider is registered with `TomSecrets.register` and answers every
reference `secret:local:<tsm reference>[#<field>]`.

## Classes

### TomLocalSecretsProvider

A `TomSecretsProvider` over the Tom Secrets Manager's secrets service.

- **Implements:** `TomSecretsProvider`

#### Constructors

```dart
TomLocalSecretsProvider({
  String name = 'local',
  String? clientName,
  Map<String, String> dimensions = const {},
  bool wait = true,
  Duration? timeout,
  Map<String, String>? environment,
  TomSecretsClient? client,
})

factory TomLocalSecretsProvider.fromConfiguration({
  TomServerConfigResourceProvider? config,
  Map<String, String>? environment,
})
```

The constructor reads through `client`, or a `TomSecretsClient` it makes named
`clientName` (default the executable's name) that finds the service by
`environment` (default the process's). `fromConfiguration` reads
`secrets.local`: `clientName`, `dimensions`, `timeoutSeconds`, `waitForUnlock`,
all optional; a setting of the wrong type throws
`secrets.local.config.malformed`.

#### Constants

| Constant | Value | Description |
| -------- | ----- | ----------- |
| `configurationKey` | `'secrets.local'` | The configuration key the settings are read from. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `name` | `String` | The provider name references use; `local` by default. |
| `dimensions` | `Map<String, String>` | The dimension values passed with every request (unmodifiable). |
| `wait` | `bool` | Whether a request waits for an unlock or an approval. |
| `timeout` | `Duration?` | How long a request may wait; the service caps it. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `tsmReferenceOf` | `static String tsmReferenceOf(TomSecretReference reference)` | The tsm reference a configuration reference names: its path, and `#<field>` when it names a field. |
| `fetch` | `Future<TomSecretPayload> fetch(TomSecretReference reference)` | `get` of the tsm reference with `dimensions`, `wait` and `timeout`; answers `TomSecretPayload.field(value, version: '<modified UTC ISO 8601> <revision>')`. Throws `secrets.fetch.not_found` for kind `not_found`, `secrets.fetch.failed` for every other kind (parameters `provider`, `reference`, `kind`, `reason`), `secrets.local.binary_not_text` for a binary value. The value buffer is disposed after it is read. |
| `close` | `Future<void> close()` | Closes the connection to the service; a later `fetch` connects again. |

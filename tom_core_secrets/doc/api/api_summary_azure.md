# Tom Core Secrets Azure API Reference: tom_core_secrets/azure.dart

Azure Key Vault as a secrets provider for Tom servers: the provider, the
credential interface its bearer token comes from, three credentials, and the
two constants a Key Vault token is requested with. One library,
`package:tom_core_secrets/azure.dart`.

For the reference syntax, configuration, the credentials' behaviour and the
error keys, see [azure_secrets.md](../azure_secrets.md); for the framework side
(`TomSecrets`, `TomSecretsProvider`, `TomSecretPayload`,
`TomSecretsException`), `tom_core_server`'s
[configuration API summary](../../../../core/tom_core_server/doc/api/api_summary_configuration.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomAzureCredential](#tomazurecredential)
  - [TomAzureClientSecretCredential](#tomazureclientsecretcredential)
  - [TomAzureManagedIdentityCredential](#tomazuremanagedidentitycredential)
  - [TomAzureStaticTokenCredential](#tomazurestatictokencredential)
  - [TomAzureKeyVaultSecretsProvider](#tomazurekeyvaultsecretsprovider)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

Source: `lib/src/azure_secrets_provider.dart`.

| File | Declares |
| ---- | -------- |
| `azure_secrets_provider.dart` | `tomAzureKeyVaultScope`, `tomAzureKeyVaultResource`, `TomAzureCredential`, `TomAzureClientSecretCredential`, `TomAzureManagedIdentityCredential`, `TomAzureStaticTokenCredential`, `TomAzureKeyVaultSecretsProvider` |

The provider is registered with `TomSecrets.register` and answers every
reference `secret:azure:<name>[/<version>][#<field>]`.

The service-principal and managed-identity credentials share a private caching
base: a fetched token is kept until five minutes before it expires (half its
lifetime when that is ten minutes or less), and `invalidate` drops it. Each
implements `fetchToken`, which fetches without the cache; `token` and
`invalidate` (see [TomAzureCredential](#tomazurecredential)) come from that
base — `token` answers the cached token while it is fresh and calls
`fetchToken` otherwise, wrapping any failure in `secrets.azure.token_failed`.

## Class Hierarchy

```text
TomAzureCredential  (abstract)
    ├── TomAzureClientSecretCredential     (through the private caching base)
    ├── TomAzureManagedIdentityCredential  (through the private caching base)
    └── TomAzureStaticTokenCredential      (implements)

TomSecretsProvider  (tom_core_server)
    └── TomAzureKeyVaultSecretsProvider  (implements)
```

## Classes

### TomAzureCredential

Obtains the bearer token Key Vault requests carry.

```dart
abstract class TomAzureCredential {
  Future<String> token(http.Client client);
  void invalidate();
}
```

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `token` | `Future<String> token(http.Client client)` | A token valid for Key Vault, from cache while it is fresh; `client` is the provider's, for the token request. |
| `invalidate` | `void invalidate()` | Drops a cached token, so the next `token` fetches a new one — called after Key Vault answered `401`. |

### TomAzureClientSecretCredential

A service principal: a client id and client secret in a tenant, exchanged for a
token with the client-credentials grant at
`<authorityHost><tenantId>/oauth2/v2.0/token`, scope `tomAzureKeyVaultScope`.

- **Implements:** `TomAzureCredential`

#### Constructors

```dart
TomAzureClientSecretCredential({
  required this.tenantId,
  required this.clientId,
  required this.clientSecret,
  Uri? authorityHost,
  DateTime Function()? clock,
})
```

`authorityHost` defaults to `https://login.microsoftonline.com/`; `clock` to
`DateTime.now`, for the cache.

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `tenantId` | `String` | The directory (tenant) id. |
| `clientId` | `String` | The application (client) id. |
| `clientSecret` | `String` | The client secret. |
| `authorityHost` | `Uri` | Where tokens are requested — Entra ID's public cloud, or a sovereign cloud's host. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `fetchToken` | `Future<(String, Duration)> fetchToken(http.Client client)` | Requests a token and answers it with its lifetime, from `expires_in` or `expires_on`, thirty minutes when the answer carries neither. |

### TomAzureManagedIdentityCredential

The managed identity of the host the server runs on. With an identity header —
App Service, Functions, Container Apps — it asks `endpoint` with
`api-version=2019-08-01` and `X-IDENTITY-HEADER`; without one it asks the
instance metadata endpoint with `api-version=2018-02-01` and `Metadata: true`.
The resource is `tomAzureKeyVaultResource`.

- **Implements:** `TomAzureCredential`

#### Constructors

```dart
TomAzureManagedIdentityCredential({
  this.clientId,
  Uri? endpoint,
  String? identityHeader,
  Map<String, String> environment = const {},
  DateTime Function()? clock,
})
```

`identityHeader` defaults to `environment['IDENTITY_HEADER']`; `endpoint` to
`environment['IDENTITY_ENDPOINT']` when that is set, else
`http://169.254.169.254/metadata/identity/oauth2/token`.

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `clientId` | `String?` | The user-assigned identity's client id, or `null` for the system-assigned one. |
| `endpoint` | `Uri` | Where tokens are requested. |
| `identityHeader` | `String?` | The App Service identity header, or `null` on a VM. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `fetchToken` | `Future<(String, Duration)> fetchToken(http.Client client)` | Requests a token from the identity endpoint and answers it with its lifetime. |

### TomAzureStaticTokenCredential

A token obtained elsewhere — a developer's `az account get-access-token`, or a
test.

- **Implements:** `TomAzureCredential`

#### Constructors

```dart
TomAzureStaticTokenCredential(this.value)
```

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `value` | `String` | The token. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `token` | `Future<String> token(http.Client client)` | Answers `value`. |
| `invalidate` | `void invalidate()` | Does nothing: a static token cannot be renewed. |

### TomAzureKeyVaultSecretsProvider

A `TomSecretsProvider` over the Azure Key Vault REST API.

- **Implements:** `TomSecretsProvider` (from `tom_core_server`)

#### Constructors

```dart
TomAzureKeyVaultSecretsProvider({
  required this.vaultUri,
  required this.credential,
  this.apiVersion = '7.4',
  this.name = 'azure',
  http.Client? httpClient,
})
```

`httpClient` defaults to a `TomResilientClient` (the kernel's) over a new
`http.Client`, so every call runs under its destination's timeout, retry,
circuit-breaker and bulkhead policies; it is used for the token requests as
well and closed by `close`.

#### Factory Constructors

```dart
factory TomAzureKeyVaultSecretsProvider.fromConfiguration({
  TomServerConfigResourceProvider? config,
  Map<String, String>? environment,
})
```

| Factory | Description |
| ------- | ----------- |
| `fromConfiguration` | Builds the provider from the `secrets.azure` key of `config` (the active provider when omitted): `vaultUri`, `tenantId`, `clientId`, `clientSecret`, `managedIdentity`. The first four fall back to `AZURE_KEYVAULT_URL`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` in `environment` (none when omitted). `managedIdentity: true` builds a `TomAzureManagedIdentityCredential` (with `clientId` and `environment`), else a complete service principal a `TomAzureClientSecretCredential`. Throws `secrets.azure.config.missing_vault` or `secrets.azure.config.missing_credentials`. |

#### Static Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `configurationKey` | `String` | The configuration key the settings are read from, `secrets.azure` (a `const`). |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `vaultUri` | `Uri` | The vault's URI, `https://<name>.vault.azure.net/`. |
| `credential` | `TomAzureCredential` | Where the bearer token comes from. |
| `apiVersion` | `String` | The Key Vault REST API version requested. |
| `name` | `String` | The provider name references use; `azure` by default. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `fetch` | `Future<TomSecretPayload> fetch(String path)` | Reads `secrets/<path>` — a name, or `name/version` — and answers its `value`, with the last segment of its `id` as the payload version. Throws `secrets.fetch.failed` for an answer without a value. |
| `call` | `Future<Map<String, Object?>> call(String method, String resource, {Map<String, Object?>? body, String? path})` | Calls the vault at `resource` (relative to `vaultUri`, with `api-version`) with the bearer token and answers the decoded body. After a `401` it invalidates the token and retries once. Throws `secrets.fetch.not_found` on `404`, `secrets.fetch.failed` for an unreachable vault or any other status `>= 300`; `path` names the secret in a failure. Public so a test or a tool sets secrets through the same client. |
| `close` | `Future<void> close()` | Closes the HTTP client. |

## Global Functions and Constants

```dart
const String tomAzureKeyVaultScope = 'https://vault.azure.net/.default';
const String tomAzureKeyVaultResource = 'https://vault.azure.net';
```

| Name | Signature | Description |
| ---- | --------- | ----------- |
| `tomAzureKeyVaultScope` | `const String tomAzureKeyVaultScope` | The scope a Key Vault token is requested for with the client-credentials grant. |
| `tomAzureKeyVaultResource` | `const String tomAzureKeyVaultResource` | The resource a managed-identity token is requested for. |

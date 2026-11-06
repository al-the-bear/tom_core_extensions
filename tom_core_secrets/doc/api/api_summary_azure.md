# Tom Core Secrets Azure API Reference: tom_core_secrets/azure.dart

Azure Key Vault as a secrets provider for Tom servers: the provider, the
credential interface its bearer token comes from, three credentials, the two
constants a Key Vault token is requested with, and a Key Vault key as a
key-encryption key for field encryption. One library,
`package:tom_core_secrets/azure.dart`.

For the reference syntax, configuration, the credentials' behaviour, the Key
Vault key's settings and the error keys, see [azure_secrets.md](../azure_secrets.md);
for the framework side (`TomSecrets`, `TomSecretsProvider`, `TomSecretPayload`,
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
  - [TomAzureKeyVaultKeyEncryptionKey](#tomazurekeyvaultkeyencryptionkey)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

Source: `lib/src/azure/`.

| File | Declares |
| ---- | -------- |
| `azure/azure_key_vault_key.dart` | `TomAzureKeyVaultKeyEncryptionKey` |
| `azure/azure_secrets_provider.dart` | `tomAzureKeyVaultScope`, `tomAzureKeyVaultResource`, `TomAzureCredential`, `TomAzureClientSecretCredential`, `TomAzureManagedIdentityCredential`, `TomAzureStaticTokenCredential`, `TomAzureKeyVaultSecretsProvider` |

The provider is registered with `TomSecrets.register` and answers every
reference `secret:azure:<name>[/<version>][#<field>]`.
`TomAzureKeyVaultKeyEncryptionKey` is registered with `TomFieldEncryption` as
the key kind `azure-keyvault` and reaches the vault through the provider's
`call`.

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

TomKeyEncryptionKey  (tom_core_server)
    └── TomAzureKeyVaultKeyEncryptionKey  (implements)
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

### TomAzureKeyVaultKeyEncryptionKey

A key-encryption key for field encryption whose key never leaves Key Vault: a
data key is wrapped with the vault's `wrapkey` and unwrapped with `unwrapkey`,
under the vault key `keyName` at `keyVersion` (or its current version), with
`algorithm`. None of the algorithms takes associated data, so what is wrapped
is a frame binding the data key's id (`framed`), and the stored wrapped key
records the key version that wrapped it — the version's length in one byte, the
version, the vault's wrapped bytes — so a key rotated in Key Vault still
unwraps older data keys. Requests go through `provider` and so use its vault
and credential.

- **Implements:** `TomKeyEncryptionKey` (from `tom_core_server`)

#### Constructors

```dart
TomAzureKeyVaultKeyEncryptionKey({
  required this.id,
  required this.provider,
  required this.keyName,
  this.keyVersion,
  this.algorithm = 'RSA-OAEP-256',
})
```

#### Static Constants

| Constant | Type | Value | Description |
| -------- | ---- | ----- | ----------- |
| `kind` | `String` | `'azure-keyvault'` | The kind of a `fieldEncryption.keys` entry this key is built for. |
| `algorithms` | `List<String>` | `['RSA-OAEP-256', 'RSA-OAEP', 'A256KW']` | The wrapping algorithms the key accepts; `A256KW` for an AES key on a Managed HSM. |
| `dataKeyLength` | `int` | `32` | The length of a field-encryption data key. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `register` | `static void register({TomServerConfigResourceProvider? config, Map<String, String>? environment})` | Registers the kind `azure-keyvault` with `TomFieldEncryption.registerKeyKind`. The entries of that kind share one `TomAzureKeyVaultSecretsProvider.fromConfiguration(config:, environment:)`, built when the first entry is. |
| `fromSettings` | `static TomAzureKeyVaultKeyEncryptionKey fromSettings(String id, Map<String, Object?> settings, {required TomAzureKeyVaultSecretsProvider provider})` | The key `id` an entry's `settings` describe, through `provider`: `keyName` (required), `keyVersion` (default the current version), `algorithm` (default `RSA-OAEP-256`). Throws `secrets.kek.config.invalid` without a `keyName` or for an algorithm not in `algorithms`. |
| `framed` | `static Uint8List framed(List<int> dataKey, String keyId)` | What is wrapped for `dataKey` of `keyId`: the id's length in one byte, the id's UTF-8 bytes, the data key, zero-padded to a multiple of eight bytes. Throws `secrets.kek.failed` for an id longer than 255 bytes. |
| `unframed` | `static List<int>? unframed(List<int> frame, String keyId, int keyLength)` | The data key, `keyLength` bytes, that `frame` holds for `keyId`; `null` when the frame records another id or is too short. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `id` | `String` | The key's id, recorded with every data key it wraps. |
| `provider` | `TomAzureKeyVaultSecretsProvider` | The Key Vault secrets provider requests go through. |
| `keyName` | `String` | The vault key that wraps. |
| `keyVersion` | `String?` | The key version that wraps; `null` for the key's current version, read from the vault once. |
| `algorithm` | `String` | The wrapping algorithm. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `wrap` | `Future<List<int>> wrap(List<int> dataKey, {required String keyId})` | `POST keys/<keyName>/<version>/wrapkey` with the frame of `dataKey` and `keyId`; answers the version's length in one byte, the version and the wrapped bytes. |
| `unwrap` | `Future<List<int>> unwrap(List<int> wrapped, {required String keyId})` | `POST keys/<keyName>/<version>/unwrapkey` under the version `wrapped` records; answers the data key. Throws `secrets.kek.failed` for a wrapped key that names no version or whose frame records another id. |

Both throw `secrets.kek.failed` when the vault cannot be reached or refuses.

## Global Functions and Constants

```dart
const String tomAzureKeyVaultScope = 'https://vault.azure.net/.default';
const String tomAzureKeyVaultResource = 'https://vault.azure.net';
```

| Name | Signature | Description |
| ---- | --------- | ----------- |
| `tomAzureKeyVaultScope` | `const String tomAzureKeyVaultScope` | The scope a Key Vault token is requested for with the client-credentials grant. |
| `tomAzureKeyVaultResource` | `const String tomAzureKeyVaultResource` | The resource a managed-identity token is requested for. |

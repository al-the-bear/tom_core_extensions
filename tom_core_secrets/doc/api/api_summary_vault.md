# Tom Core Secrets Vault API Reference: tom_core_secrets/vault.dart

HashiCorp Vault as a secrets provider for Tom servers: the provider, the
interface it authenticates through, the two built-in auth methods, and a
Transit key as a key-encryption key for field encryption. One library,
`package:tom_core_secrets/vault.dart`.

For the reference syntax, configuration, authentication behaviour, the Transit
key's settings and the error keys, see [vault_secrets.md](../vault_secrets.md);
for the framework side (`TomSecrets`, `TomSecretsProvider`, `TomSecretPayload`,
`TomSecretsException`), `tom_core_server`'s
[configuration API summary](../../../../core/tom_core_server/doc/api/api_summary_configuration.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomVaultAuth](#tomvaultauth)
  - [TomVaultTokenAuth](#tomvaulttokenauth)
  - [TomVaultAppRoleAuth](#tomvaultapproleauth)
  - [TomVaultSecretsProvider](#tomvaultsecretsprovider)
  - [TomVaultTransitKeyEncryptionKey](#tomvaulttransitkeyencryptionkey)

## Overview

Source: `lib/src/vault/`.

| File | Declares |
| ---- | -------- |
| `vault/vault_secrets_provider.dart` | `TomVaultAuth`, `TomVaultTokenAuth`, `TomVaultAppRoleAuth`, `TomVaultSecretsProvider` |
| `vault/vault_transit_key.dart` | `TomVaultTransitKeyEncryptionKey` |

The provider is registered with `TomSecrets.register` and answers every
reference `secret:vault:<path>[#<field>]`, where `<path>` is the Vault API path
after `/v1/`. `TomVaultTransitKeyEncryptionKey` is registered with
`TomFieldEncryption` as the key kind `vault-transit` and reaches Vault through
the provider's `call`.

## Class Hierarchy

```text
TomVaultAuth  (abstract)
    ├── TomVaultTokenAuth
    └── TomVaultAppRoleAuth

TomSecretsProvider  (tom_core_server)
    └── TomVaultSecretsProvider  (implements)

TomKeyEncryptionKey  (tom_core_server)
    └── TomVaultTransitKeyEncryptionKey  (implements)
```

## Classes

### TomVaultAuth

How the provider obtains its Vault token.

```dart
abstract class TomVaultAuth {
  Future<String> token(TomVaultSecretsProvider provider);
  void invalidate();
}
```

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `token` | `Future<String> token(TomVaultSecretsProvider provider)` | A token to send, logging in through `provider.call` when there is none or it has run out. |
| `invalidate` | `void invalidate()` | Drops the token held, so the next `token` logs in again — called after Vault refused it with `403`. |

### TomVaultTokenAuth

A fixed token.

- **Implements:** `TomVaultAuth`

#### Constructors

```dart
TomVaultTokenAuth(this.value)
```

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `value` | `String` | The token, sent on every authenticated call. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `token` | `Future<String> token(TomVaultSecretsProvider provider)` | Answers `value`. |
| `invalidate` | `void invalidate()` | Does nothing: a fixed token cannot be replaced. |

### TomVaultAppRoleAuth

AppRole: a role id and a secret id exchanged for a token at
`auth/<mount>/login`. The token is kept for nine tenths of its
`lease_duration`, so it is never presented in its last seconds; a lease of zero
is a token that does not expire. A login answered without `auth.client_token`
throws `TomSecretsException` `secrets.vault.login_failed`.

- **Implements:** `TomVaultAuth`

#### Constructors

```dart
TomVaultAppRoleAuth({
  required this.roleId,
  required this.secretId,
  this.mount = 'approle',
  DateTime Function()? clock,
})
```

`clock` replaces `DateTime.now` for the lease arithmetic, for tests.

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `roleId` | `String` | The role id. |
| `secretId` | `String` | The secret id. |
| `mount` | `String` | Where the AppRole method is mounted. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `token` | `Future<String> token(TomVaultSecretsProvider provider)` | The held token while its lease runs, else a new login through `provider.call('POST', 'auth/<mount>/login', authenticated: false)`. |
| `invalidate` | `void invalidate()` | Drops the held token and its expiry, so the next `token` logs in. |

### TomVaultSecretsProvider

A `TomSecretsProvider` over the HashiCorp Vault HTTP API.

- **Implements:** `TomSecretsProvider` (from `tom_core_server`)

#### Constructors

```dart
TomVaultSecretsProvider({
  required this.address,
  required this.auth,
  this.namespace,
  this.name = 'vault',
  http.Client? httpClient,
})
```

`httpClient` defaults to a `TomResilientClient` (the kernel's) over a new
`http.Client`, so every call runs under Vault's destination policy — timeout,
retries for `GET`s, circuit breaker, bulkhead; it is closed by `close`.

#### Factory Constructors

```dart
factory TomVaultSecretsProvider.fromConfiguration({
  TomServerConfigResourceProvider? config,
  Map<String, String>? environment,
})
```

| Factory | Description |
| ------- | ----------- |
| `fromConfiguration` | Builds the provider from the `secrets.vault` key of `config` (the active provider when omitted): `address`, `token`, `roleId`, `secretId`, `appRoleMount`, `namespace`. Each falls back to `VAULT_ADDR`, `VAULT_TOKEN`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, `VAULT_APPROLE_MOUNT`, `VAULT_NAMESPACE` in `environment` (none when omitted). An AppRole pair wins over a token. Throws `secrets.vault.config.missing_address` or `secrets.vault.config.missing_credentials`. |

#### Static Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `configurationKey` | `String` | The configuration key the settings are read from, `secrets.vault` (a `const`). |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `address` | `Uri` | Where Vault answers. |
| `auth` | `TomVaultAuth` | How the provider authenticates. |
| `namespace` | `String?` | The Vault Enterprise namespace, sent as `X-Vault-Namespace`, or `null`. |
| `name` | `String` | The provider name references use; `vault` by default. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `fetch` | `Future<TomSecretPayload> fetch(String path)` | Reads `GET /v1/<path>`. A KV version 2 answer yields its inner `data` map with `metadata.version` as the payload version; any other answer its `data` map. Throws `secrets.fetch.not_found` on `404`, `secrets.fetch.failed` on any other failure or an answer without `data`. |
| `call` | `Future<Map<String, Object?>> call(String method, String path, {Map<String, Object?>? body, bool authenticated = true})` | Calls Vault at `/v1/<path>` and answers the decoded body (`{}` for an empty one). Sends the namespace header when set and, when `authenticated`, the token from `auth`; retries once after a `403` on an authenticated call with a fresh token. Public so an auth method logs in through the same client. |
| `close` | `Future<void> close()` | Closes the HTTP client. |

### TomVaultTransitKeyEncryptionKey

A key-encryption key for field encryption whose key never leaves Vault: a data
key is wrapped with the Transit engine's `encrypt` and unwrapped with its
`decrypt`, under the Transit key `keyName` of the engine mounted at `mount`,
with the associated data `tom-data-key:<data key id>` — so the Transit key must
be of an AEAD type (`aes256-gcm96`, the default, is). Requests go through
`provider` and so use its address, namespace and authentication.

- **Implements:** `TomKeyEncryptionKey` (from `tom_core_server`)

#### Constructors

```dart
TomVaultTransitKeyEncryptionKey({
  required this.id,
  required this.provider,
  required this.keyName,
  this.mount = 'transit',
})
```

#### Static Constants

| Constant | Type | Value | Description |
| -------- | ---- | ----- | ----------- |
| `kind` | `String` | `'vault-transit'` | The kind of a `fieldEncryption.keys` entry this key is built for. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `register` | `static void register({TomServerConfigResourceProvider? config, Map<String, String>? environment})` | Registers the kind `vault-transit` with `TomFieldEncryption.registerKeyKind`. The entries of that kind share one `TomVaultSecretsProvider.fromConfiguration(config:, environment:)`, built when the first entry is. |
| `fromSettings` | `static TomVaultTransitKeyEncryptionKey fromSettings(String id, Map<String, Object?> settings, {required TomVaultSecretsProvider provider})` | The key `id` an entry's `settings` describe, through `provider`: `keyName` (required), `mount` (default `transit`). Throws `secrets.kek.config.invalid` without a `keyName`. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `id` | `String` | The key's id, recorded with every data key it wraps. |
| `provider` | `TomVaultSecretsProvider` | The Vault secrets provider requests go through. |
| `keyName` | `String` | The Transit key that wraps. |
| `mount` | `String` | Where the Transit engine is mounted. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `wrap` | `Future<List<int>> wrap(List<int> dataKey, {required String keyId})` | `POST <mount>/encrypt/<keyName>` with `dataKey` and the associated data of `keyId`; answers the UTF-8 bytes of Vault's ciphertext text, `vault:v1:...`. |
| `unwrap` | `Future<List<int>> unwrap(List<int> wrapped, {required String keyId})` | `POST <mount>/decrypt/<keyName>` with the ciphertext text and the associated data of `keyId`; answers the plaintext. |

Both throw `secrets.kek.failed` when Vault cannot be reached or refuses — among
others a wrapped key that does not decrypt under the asked id.

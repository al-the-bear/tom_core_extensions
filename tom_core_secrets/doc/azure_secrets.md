# Azure Key Vault secrets

`TomAzureKeyVaultSecretsProvider` answers every configuration reference that
names the `azure` provider. This page covers the Azure side: how a reference
names a secret and a version, how the provider is configured, where its token
comes from and how long it is kept, how it reacts to rotation and refusal, how
a Key Vault key serves as a key-encryption key for field encryption, and how
its emulator suite runs. How references work in general — where they may
appear, their precedence, the boot order and the refresh cycle — is in
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#secret-references).

## Table of Contents

- [The reference](#the-reference)
- [Registering the provider](#registering-the-provider)
- [Configuration](#configuration)
- [The HTTP client](#the-http-client)
- [Credentials](#credentials)
  - [A service principal](#a-service-principal)
  - [A managed identity](#a-managed-identity)
  - [A static token](#a-static-token)
  - [Token caching and refusal](#token-caching-and-refusal)
- [Rotation](#rotation)
- [Key-encryption keys for field encryption](#key-encryption-keys-for-field-encryption)
- [Error keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## The reference

```text
secret:azure:<name>[/<version>][#<field>]
```

| Reference | Reads |
| --------- | ----- |
| `secret:azure:smtp-password` | the current version of the secret `smtp-password` |
| `secret:azure:smtp-password/4f0c…` | that version, and no other |
| `secret:azure:db#password` | member `password` of the JSON object the secret `db` holds |

`fetch` sends `GET <vaultUri>secrets/<path>?api-version=7.4` and answers the
secret's `value`; the version is the last segment of the secret's `id`, and
becomes `TomSecretPayload.version`. The value is one string: without
`#<field>` it is the configuration value, with a field the framework decodes it
as a JSON object and takes the member (`secrets.field.missing` when the string
is not one, or lacks the member). Each secret is read once per load or
refresh, however many of its fields the configuration names.

## Registering the provider

A boot registers the provider before it loads the references, and loads them
before it builds the configuration object:

```dart
import 'dart:io';

import 'package:tom_core_secrets/azure.dart';
import 'package:tom_core_server/tom_core_server.dart';

Future<void> boot(List<String> args) async {
  TomSecrets.register(
    TomAzureKeyVaultSecretsProvider.fromConfiguration(
      environment: Platform.environment,
    ),
  );
  await TomSecrets.load(TomBaseServerConfiguration.collectSources(args));
  TomSecrets.startRefresh(const Duration(minutes: 15));
}
```

`fromConfiguration` reads the active configuration provider unless a `config`
is passed, and consults the environment only through the `environment` map —
pass `Platform.environment`, or `TomEnvFile.resolveEnvironment()` to include a
`.env` file. The same map is what a managed identity reads
`IDENTITY_ENDPOINT` and `IDENTITY_HEADER` from.

The constructor takes the vault and a credential; `apiVersion` overrides the
REST API version, `name` registers the provider under another name (one per
vault, `azure` and `azure-shared`), and `httpClient` replaces the default
client, a `TomResilientClient` over a new `http.Client` (see [The HTTP
client](#the-http-client)) — the token requests go through the same client:

```dart
final provider = TomAzureKeyVaultSecretsProvider(
  vaultUri: Uri.parse('https://my-vault.vault.azure.net/'),
  credential: TomAzureClientSecretCredential(
    tenantId: tenantId,
    clientId: clientId,
    clientSecret: clientSecret,
  ),
  name: 'azure',
);
```

## Configuration

`fromConfiguration` reads `secrets.azure`. A setting the configuration does not
carry, or carries empty, falls back to the variable:

```yaml
secrets:
  azure:
    vaultUri: https://my-vault.vault.azure.net/   # or AZURE_KEYVAULT_URL
    tenantId: ...         # or AZURE_TENANT_ID     } a service principal
    clientId: ...         # or AZURE_CLIENT_ID     }
    clientSecret: ...     # or AZURE_CLIENT_SECRET }
    managedIdentity: true # the host's identity instead
```

| Setting | Variable | Meaning |
| ------- | -------- | ------- |
| `vaultUri` | `AZURE_KEYVAULT_URL` | The vault. Without it the provider is refused, `secrets.azure.config.missing_vault`. |
| `managedIdentity` | — | When `true` (a YAML boolean), the host's managed identity is used, whatever else is set. |
| `clientId` | `AZURE_CLIENT_ID` | The service principal's application id; with `managedIdentity`, the client id of a user-assigned identity. |
| `tenantId` | `AZURE_TENANT_ID` | The service principal's directory. |
| `clientSecret` | `AZURE_CLIENT_SECRET` | The service principal's secret. |

Without `managedIdentity: true`, all three service-principal settings are
needed; with neither, the provider is refused,
`secrets.azure.config.missing_credentials`. `secrets.azure` is read as
written: it holds the credentials that open the store, so a reference inside it
is not resolved.

## The HTTP client

Without an `httpClient` of its own the provider sends through the kernel's
`TomResilientClient`, and so do its token requests: every call runs under the
policy of its destination that `tom_core_server`'s `httpClient` configuration
key sets — see
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#outgoing-http-calls) — with a
timeout on every attempt (30 seconds by default) and a circuit breaker and a
bulkhead per destination. Three destinations are involved, each with its own
circuit:

| Destination | Calls | Retried |
| ----------- | ----- | ------- |
| The vault, `https://<name>.vault.azure.net` | `GET` of a secret | yes, after a connection failure, a timeout or a `429`/`502`/`503`/`504` |
| Entra ID, `https://login.microsoftonline.com` (or `authorityHost`) | the service principal's token `POST` | no |
| The managed identity endpoint, `IDENTITY_ENDPOINT` or `http://169.254.169.254` | the identity's token `GET` | yes |

A call the policy abandons or refuses fails as `secrets.fetch.failed`, or as
`secrets.azure.token_failed` when it was a token request.

```yaml
httpClient:
  destinations:
    "https://my-vault.vault.azure.net": {timeoutMs: 5000}
    "http://169.254.169.254": {timeoutMs: 2000}
```

**At boot the load comes first.** `TomSecrets.load` runs before
`TomServer.start` applies `httpClient`, so the load runs under the kernel's
defaults unless the boot applies the key itself first —
`TomServer.configureHttpClients` with the merged sources, as
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#outgoing-http-calls) shows. A
refresh after the start runs under the configured policies. A client passed as
`httpClient` replaces the resilient one; wrap it — `TomResilientClient(client)`
— to keep the policies.

## Credentials

A `TomAzureCredential` answers a token for Key Vault and can drop it.

### A service principal

`TomAzureClientSecretCredential` posts the client-credentials grant to
`<authorityHost><tenantId>/oauth2/v2.0/token` with the scope
`tomAzureKeyVaultScope` (`https://vault.azure.net/.default`). `authorityHost`
is Entra ID's public cloud, `https://login.microsoftonline.com/`, unless a
sovereign cloud's is given.

### A managed identity

`TomAzureManagedIdentityCredential` asks the platform for the host's identity,
for the resource `tomAzureKeyVaultResource` (`https://vault.azure.net`):

| Where | Detected by | Request |
| ----- | ----------- | ------- |
| App Service, Functions, Container Apps | `IDENTITY_HEADER` set (or `identityHeader` passed) | `GET <IDENTITY_ENDPOINT>?api-version=2019-08-01&resource=…` with `X-IDENTITY-HEADER` |
| A VM, a scale set, AKS with the metadata endpoint | otherwise | `GET http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=…` with `Metadata: true` |

`clientId` selects a user-assigned identity; without it the system-assigned one
answers. `endpoint` overrides where the token is requested — the emulator suite
points it at Lowkey Vault's token endpoint.

```dart
final credential = TomAzureManagedIdentityCredential(
  clientId: '00000000-0000-0000-0000-000000000000', // a user-assigned identity
  environment: Platform.environment,
);
```

### A static token

`TomAzureStaticTokenCredential(value)` answers `value` every time and cannot
renew it — for a developer's `az account get-access-token --resource
https://vault.azure.net`, or a test.

### Token caching and refusal

The service-principal and managed-identity credentials keep the token they
fetched. Its lifetime is read from `expires_in` (seconds) or `expires_on`
(epoch seconds), thirty minutes when the answer carries neither; the token is
reused until five minutes before it expires, or for half its lifetime when that
is ten minutes or less. When Key Vault answers a request `401`, the provider
calls `invalidate` and repeats the request once, so a token revoked or expired
early is replaced without failing the read; a second `401` fails with
`secrets.fetch.failed`. A token endpoint that answers other than `200`, answers
without `access_token`, or cannot be reached fails with
`secrets.azure.token_failed`.

## Rotation

The provider holds no secret values; `TomSecrets` does. `TomSecrets.refresh`
reads every loaded secret again, and the watchers of a reference whose value
changed are called with the new one. An unversioned reference reads the
current version, so a new version written to the vault — by hand, by a
rotation policy, by Event Grid automation — is seen at the next refresh; a
reference pinned to a version reads that version every time and does not
move. A refresh that cannot read a secret keeps the last value and lists the
reference in `TomSecretsRefresh.failed`; only the first `TomSecrets.load` fails
the boot.

## Key-encryption keys for field encryption

`TomAzureKeyVaultKeyEncryptionKey` (`lib/src/azure/azure_key_vault_key.dart`) is
a `TomKeyEncryptionKey` for `tom_core_server`'s field-level encryption whose key
never leaves Key Vault: a data key is wrapped with the vault's `wrapkey` and
unwrapped with `unwrapkey`, under the vault key `keyName`. How field encryption
uses its key-encryption keys is in
[`tom_core_server/doc/object_persistence.md`](../../../core/tom_core_server/doc/object_persistence.md#keys-held-by-a-key-management-service).

Requests go through a `TomAzureKeyVaultSecretsProvider`'s `call`, so they reach
its vault with its Entra ID credential — a service principal, the host's
managed identity or a static token. `TomAzureKeyVaultKeyEncryptionKey.register()`
registers the kind `azure-keyvault` (`TomAzureKeyVaultKeyEncryptionKey.kind`)
with `TomFieldEncryption.registerKeyKind`; the entries of that kind share one
provider, built from `secrets.azure` / `AZURE_*` as
[Configuration](#configuration) describes, when the first is built. It runs
before `TomServer.start` applies `fieldEncryption` and takes the same `config`
and `environment` as `fromConfiguration`:

```dart
TomAzureKeyVaultKeyEncryptionKey.register(environment: Platform.environment);
```

```yaml
fieldEncryption:
  datasource: main
  keys:
    - id: keyvault-2026
      kind: azure-keyvault
      keyName: field-keys       # required: the vault key
      keyVersion: 0123abcd...   # default: the key's current version
      algorithm: RSA-OAEP-256   # or RSA-OAEP, or A256KW on a Managed HSM
```

| Setting | Default | Meaning |
| ------- | ------- | ------- |
| `keyName` | required | The vault key that wraps. Without it the entry is refused, `secrets.kek.config.invalid`. |
| `keyVersion` | the key's current version, read from the vault once | The key version that wraps. |
| `algorithm` | `RSA-OAEP-256` | The wrapping algorithm, one of `TomAzureKeyVaultKeyEncryptionKey.algorithms`: `RSA-OAEP-256` or `RSA-OAEP` for an RSA key, `A256KW` for an AES key on a Managed HSM. Another is refused, `secrets.kek.config.invalid`. |

**The data key id is bound into the wrapped bytes.** None of the three
algorithms takes associated data, so what is wrapped is a frame
(`TomAzureKeyVaultKeyEncryptionKey.framed`): the id's length in one byte, the
id's UTF-8 bytes and the data key, zero-padded to a multiple of eight bytes for
AES key wrap. `unwrap` refuses a key whose frame records another id
(`unframed` answers `null` for it), so a wrapped key cannot be passed off as
another. An id longer than 255 bytes cannot be framed.

**The wrapped key records the version that wrapped it**: the version's length in
one byte, the version, then the vault's wrapped bytes. `unwrap` asks that
version, so a key rotated in Key Vault still unwraps the data keys its earlier
versions wrapped, while new data keys are wrapped under the version
`keyVersion` names, or the current version as read when the key first wrapped.
Moving to another vault key is a key-encryption-key rotation in
`fieldEncryption.keys`.

The identity needs the key operations `wrapKey` and `unwrapKey` (the
*Key Vault Crypto Service Encryption User* role, or an access policy with those
permissions), and reading the key (`get`) when `keyVersion` is not set.

| Key | When |
| --- | ---- |
| `secrets.kek.config.invalid` | The entry has no `keyName`, or names an algorithm not in `algorithms`. |
| `secrets.kek.failed` | Key Vault could not be reached or refused the call — a key it does not hold, an operation the identity may not perform; a wrapped key that names no key version; a frame that records another data key id; or a data key id too long to frame. |

## Error keys

Every failure is a `TomSecretsException`; its message names the secret, never
its value.

| Key | When |
| --- | ---- |
| `secrets.azure.config.missing_vault` | `fromConfiguration` found neither `secrets.azure.vaultUri` nor `AZURE_KEYVAULT_URL`. |
| `secrets.azure.config.missing_credentials` | `fromConfiguration` found neither `managedIdentity: true` nor a complete service principal. |
| `secrets.azure.token_failed` | The token endpoint refused, answered without a token, or could not be reached (parameter `status` when it answered). |
| `secrets.fetch.not_found` | Key Vault answered `404`: no such secret, or no such version. |
| `secrets.fetch.failed` | Key Vault could not be reached, answered any other status `>= 300` (parameters `provider`, `path`, `status`), or answered without a `value`. |

The framework adds its own around them — `secrets.field.required`,
`secrets.field.missing`, `secrets.provider.unknown`,
`secrets.reference.malformed` and `secrets.reference.unresolved`; see
`tom_core_server/doc/configuration.md`.

## Not Yet Implemented

- **No certificate or federated credential.** A service principal with a
  certificate, workload identity federation (AKS, GitHub Actions) and the Azure
  CLI's token cache are not built in; each is a `TomAzureCredential`
  implementation.
- **No certificates.** Key Vault certificates are not read; a certificate's
  private key is reachable as the secret of the same name. Key Vault keys serve
  only as [key-encryption keys](#key-encryption-keys-for-field-encryption).

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/azure/azure_secrets_provider_test.dart` | `fromConfiguration` with a service principal from the configuration, from the Azure variables, and a managed identity on request, and its refusals; a fetch reading the value and the version from the id with a bearer; `404` as `not_found` and other failures as `failed`; a `401` dropping the token and retrying once; a token reused until shortly before it expires; a managed identity asking the instance metadata endpoint or App Service's; a refused or unreachable token endpoint as `token_failed`. Runs against `MockClient`. |
| `test/azure/example_test.dart` | Runs `example/azure_secrets_example.dart` and requires exit 0. |
| `test/azure/azure_emulator_test.dart` | Tagged `emulator`. Against Lowkey Vault: a plain secret read with a managed-identity token, fields of a JSON secret resolved through `TomSecrets`, a new version reaching a watcher while a pinned version does not move, `not_found` for an absent secret, and a missing identity endpoint refused as `token_failed`. Skips itself when the emulator does not answer. |
| `test/key_encryption_key_settings_test.dart` | KS-1 to KS-6, for all three key-encryption keys: an `azure-keyvault` entry's key, version and algorithm (KS-3); an entry without its key, or with an unknown algorithm, refused with `secrets.kek.config.invalid` (KS-4); each library registering its kind with field encryption (KS-5); the frame binding the data key id, padded to eight bytes (KS-6). No emulator. |
| `test/azure/azure_kek_emulator_test.dart` | Tagged `emulator`. Against Lowkey Vault, through the shared contract `test/support/key_encryption_key_contract.dart`: a data key wraps and unwraps under its own id (AKV-1); a wrapped key does not unwrap under another id, `secrets.kek.failed` (AKV-2); a keyring over the vault key encrypts, rotates its data key and rewraps the data keys of an application-held key under it, and a fresh keyring holding only the vault key reads everything (AKV-3); a key the vault does not hold refused with `secrets.kek.failed` (AKV-4). The test creates the RSA key `field-keys`; Lowkey Vault implements wrapping through its encrypt operation, so the test key also carries `encrypt` and `decrypt` — a real Key Vault needs only `wrapKey` and `unwrapKey`. Skips itself when the emulator does not answer. |

```bash
dart test                         # unit suite + example; emulator tests skip
./tool/run_azure_emulator_tests.sh      # the emulator suite against Lowkey Vault
```

`tool/run_azure_emulator_tests.sh` starts `nagyesta/lowkey-vault:7.3.127` with the
vault on `https://localhost:18443/` (`AZURE_TEST_PORT`) and its managed-identity
token endpoint on `http://localhost:18080/` (`AZURE_TEST_TOKEN_PORT`), waits
until the vault answers an unauthenticated request with `401`, runs
`dart test --tags emulator test/azure` with `AZURE_TEST_VAULT` and `AZURE_TEST_IDENTITY`
pointing at it, and removes the container. Lowkey Vault serves its vault under
the host and port a request names, so the container listens on the same port
the host maps (`LOWKEY_ARGS=--server.port=<port>`); a mapped port that differs
is answered "Unable to find active vault". The emulator serves a self-signed
certificate, which the emulator suite's own HTTP client accepts — a provider
built with the default client verifies certificates. Lowkey accepts any bearer
token, so the suite's refusal case is the token endpoint's. The image is built for
x86-64 and starts in about a minute under emulation on Apple silicon. A run in which
every emulator test skipped is reported as a failure. It needs Docker.

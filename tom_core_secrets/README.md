# tom_core_secrets

Published on pub.dev as [`tom_core_secrets` 0.2.0](https://pub.dev/packages/tom_core_secrets).

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed and published on pub.dev.

Cloud secret stores as secrets providers for Tom servers — configuration values
written as `secret:<provider>:<path>#<field>` references, resolved at boot and
refreshed on rotation. One library per provider:

| Library | Provider | Registered as |
| ------- | -------- | ------------- |
| `package:tom_core_secrets/aws.dart` | AWS Secrets Manager — `TomAwsSecretsProvider` | `aws` |
| `package:tom_core_secrets/azure.dart` | Azure Key Vault — `TomAzureKeyVaultSecretsProvider` | `azure` |
| `package:tom_core_secrets/vault.dart` | HashiCorp Vault — `TomVaultSecretsProvider` | `vault` |
| `package:tom_core_secrets/tom_core_secrets.dart` | all three | — |

Each implements `tom_core_server`'s `TomSecretsProvider`. Each library also
offers a key held by its service — an AWS KMS key, a Vault Transit key, a Key
Vault key — as a key-encryption key for `tom_core_server`'s field-level
encryption; see [Key-encryption keys for field
encryption](#key-encryption-keys-for-field-encryption). The device keychain a
client application keeps its settings key in is a different thing — it is
`tom_core_storage`'s `TomSecretStore`.

## Installation

Add it from pub.dev:

```yaml
dependencies:
  tom_core_server: ^1.3.0
  tom_core_secrets: ^0.2.0
```

Dart SDK `^3.10.0`. A server imports the library of the provider it registers.

## AWS Secrets Manager (`aws.dart`)

### Overview

`tom_core_server` lets any configuration value be written as a **reference**
to a secret store instead of the value itself:

```yaml
databasePassword: "secret:aws:prod/billing#password"
```

The server resolves every reference once at boot, before it builds its
configuration object, and puts the secret where the reference was. Which store
a reference reaches is decided by the provider registered under the name in
its middle part. This package is that provider for AWS Secrets Manager:
`TomAwsSecretsProvider`, registered as `aws`.

A reference names the secret by **name or ARN**. Without a field the whole
`SecretString` is the value; `#<field>` reads one member of a secret that
holds a JSON object — the shape the Secrets Manager console writes for
key/value secrets. The current version (`AWSCURRENT`) is read, so a rotation
by Secrets Manager reaches the server at the next refresh.

The provider calls `GetSecretValue` over HTTP and signs it with the
framework's own Signature Version 4 signer — the one `tom_core_server`'s S3
blob store uses — so no AWS SDK is involved. Credentials come from a
**credentials source** called for every request: static keys for a developer
or a CI job, or a function returning a role's temporary credentials on an
instance or task role.

### Features

| Type | What it does |
| ---- | ------------ |
| `TomAwsSecretsProvider` | The `TomSecretsProvider` over Secrets Manager: `fetch` calls `GetSecretValue` for a secret id, answers its `SecretString`, or its `SecretBinary` when that is UTF-8 text, with the `VersionId`. `fromConfiguration` builds one from `secrets.aws`, falling back to the standard `AWS_*` variables. `call` is the signed client for any Secrets Manager action. |
| `TomAwsCredentialsSource` | `tom_core_server`'s `Future<TomAwsCredentials> Function()`, defined beside `TomAwsV4Signer` — where each request's credentials come from. |
| `TomAwsKmsKeyEncryptionKey` | A key-encryption key for field encryption held by AWS KMS, the kind `aws-kms`: wraps a data key with KMS `Encrypt` and unwraps it with `Decrypt`, the data key id bound as the encryption context. |

### Quick start

A server registers the provider before it loads its secrets, and loads them
before it builds its configuration:

```dart
import 'dart:io';

import 'package:tom_core_secrets/aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

Future<void> main(List<String> args) async {
  TomSecrets.register(
    TomAwsSecretsProvider.fromConfiguration(
      environment: Platform.environment, // AWS_REGION, AWS_ACCESS_KEY_ID, ...
    ),
  );
  await TomSecrets.load(TomBaseServerConfiguration.collectSources(args));
  print(TomSecrets.current('secret:aws:prod/billing#password'));
  // the member `password` of the JSON secret `prod/billing`
}
```

The configuration class built after `TomSecrets.load` receives the secret, not
the reference. On a role, construct the provider with a credentials source
that returns the role's current temporary credentials instead:

```dart
final provider = TomAwsSecretsProvider(
  region: 'eu-west-1',
  credentials: roleCredentials, // a TomAwsCredentialsSource
);
```

### Example

| Example | Demonstrates |
| ------- | ------------ |
| [`example/aws_secrets_example.dart`](example/aws_secrets_example.dart) | A signed `GetSecretValue`, a member of a JSON secret loaded through `TomSecrets`, and a rotation reaching a watcher on refresh — against an in-process stand-in for Secrets Manager, so it runs anywhere |

```bash
dart run example/aws_secrets_example.dart
```

`test/aws/example_test.dart` runs it and requires a clean exit.

### Configuration

`TomAwsSecretsProvider.fromConfiguration` reads the `secrets.aws` key of the
configuration resources; each setting falls back to the standard AWS variables
when an `environment` map is passed:

| Setting | Variable | Meaning |
| ------- | -------- | ------- |
| `region` | `AWS_REGION`, then `AWS_DEFAULT_REGION` | The region the secrets live in. Required. |
| `accessKeyId` | `AWS_ACCESS_KEY_ID` | Required for the configured form. |
| `secretAccessKey` | `AWS_SECRET_ACCESS_KEY` | Required for the configured form. |
| `sessionToken` | `AWS_SESSION_TOKEN` | Optional, for temporary credentials. |
| `endpoint` | `AWS_ENDPOINT_URL_SECRETS_MANAGER` | Optional: a VPC endpoint or an emulator instead of `https://secretsmanager.<region>.amazonaws.com/`. |

**Outgoing calls are resilient by default.** Without an `httpClient` of its own,
`TomAwsSecretsProvider` sends through the kernel's `TomResilientClient`, under the policy of
the Secrets Manager endpoint that `tom_core_server`'s `httpClient` configuration key sets — a
30-second timeout per attempt by default, and a circuit breaker and a bulkhead
per destination. Every Secrets Manager action is a `POST`, so none is retried by the client; the timeout, the circuit breaker and the bulkhead apply. Name a destination under `httpClient.destinations`
to give it its own policy; `TomSecrets.load` runs before the server applies the
key, so a boot that wants it at load applies it first — see
[`tom_core_server/doc/configuration.md`](../../core/tom_core_server/doc/configuration.md#outgoing-http-calls) and [`doc/aws_secrets.md`](doc/aws_secrets.md#the-http-client).

### Limits

- **`fromConfiguration` takes static keys only.** Credentials that rotate —
  an instance profile, a task role, an assumed role — are supplied by
  constructing the provider with a `TomAwsCredentialsSource`; the package does
  not call the instance metadata service or STS itself.
- **A binary secret must be text.** `SecretBinary` is decoded as UTF-8; a
  secret that is not text cannot be a configuration value and is refused,
  `secrets.aws.binary_not_text`.
- **Only the current version is read.** A reference cannot pin a `VersionId`
  or a staging label.

### Further documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/aws_secrets.md](doc/aws_secrets.md) | The reference syntax, configuration, credentials and roles, signing, refresh, the KMS key-encryption key, the error keys and the emulator suite |
| [doc/api/api_summary_aws.md](doc/api/api_summary_aws.md) | Every public type and member |
| [`tom_core_server/doc/configuration.md`](../../core/tom_core_server/doc/configuration.md#secret-references) | Secret references in general: syntax, precedence, boot order, rotation, writing a provider |

The Vault and Azure providers are [`vault.dart`](#hashicorp-vault-vaultdart)
and [`azure.dart`](#azure-key-vault-azuredart).

## Azure Key Vault (`azure.dart`)

### Overview

`tom_core_server` lets any configuration value be written as a **reference**
to a secret store instead of the value itself:

```yaml
smtpPassword: "secret:azure:smtp-password"
```

The server resolves every reference once at boot, before it builds its
configuration object, and puts the secret where the reference was. Which store
a reference reaches is decided by the provider registered under the name in
its middle part. This package is that provider for Azure Key Vault:
`TomAzureKeyVaultSecretsProvider`, registered as `azure`.

A reference names the secret, and optionally a version: `db-password` reads
the current version, `db-password/<version>` a fixed one. A secret whose value
is a JSON object can be read a field at a time, `db#password`.

Every request carries a Microsoft Entra ID bearer token from a
**credential**: a service principal's client secret, the **managed identity**
of the VM, container or App Service the server runs on, or a token obtained
elsewhere. A token is reused until five minutes before it expires, and a `401`
from Key Vault drops it and retries once with a fresh one. The provider talks
to Key Vault's REST API (version 7.4) over HTTP with `package:http`; there is
no Azure SDK in between.

### Features

| Type | What it does |
| ---- | ------------ |
| `TomAzureKeyVaultSecretsProvider` | The `TomSecretsProvider` over Key Vault: `fetch` reads `secrets/<name>[/<version>]`, answers the value with the version taken from the secret's id, and retries once with a fresh token after a `401`. `fromConfiguration` builds one from `secrets.azure`, falling back to the variables Azure's SDKs read. |
| `TomAzureCredential` | Where the bearer token comes from — `token` and `invalidate`. |
| `TomAzureClientSecretCredential` | A service principal: tenant id, client id and client secret exchanged at Entra ID's token endpoint. |
| `TomAzureManagedIdentityCredential` | The host's managed identity: the App Service / Container Apps identity endpoint when `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are set, the instance metadata endpoint otherwise; system-assigned, or user-assigned by client id. |
| `TomAzureStaticTokenCredential` | A token obtained elsewhere — `az account get-access-token`, or a test. |
| `tomAzureKeyVaultScope` · `tomAzureKeyVaultResource` | The scope and the resource a Key Vault token is requested for. |
| `TomAzureKeyVaultKeyEncryptionKey` | A key-encryption key for field encryption held by Key Vault, the kind `azure-keyvault`: wraps a data key with `wrapkey` and unwraps it with `unwrapkey` (`RSA-OAEP-256`, `RSA-OAEP` or `A256KW`), the data key id bound into the wrapped bytes and the wrapping key version recorded with them. |

### Quick start

A server registers the provider before it loads its secrets, and loads them
before it builds its configuration:

```dart
import 'dart:io';

import 'package:tom_core_secrets/azure.dart';
import 'package:tom_core_server/tom_core_server.dart';

Future<void> main(List<String> args) async {
  TomSecrets.register(
    TomAzureKeyVaultSecretsProvider.fromConfiguration(
      environment: Platform.environment, // AZURE_KEYVAULT_URL, AZURE_TENANT_ID, ...
    ),
  );
  await TomSecrets.load(TomBaseServerConfiguration.collectSources(args));
  print(TomSecrets.current('secret:azure:smtp-password'));
  // the current version of the secret `smtp-password`
}
```

The configuration class built after `TomSecrets.load` receives the secret, not
the reference. On Azure compute, the host's identity needs no secret at all:

```dart
final provider = TomAzureKeyVaultSecretsProvider(
  vaultUri: Uri.parse('https://my-vault.vault.azure.net/'),
  credential: TomAzureManagedIdentityCredential(
    environment: Platform.environment,
  ),
);
```

### Example

| Example | Demonstrates |
| ------- | ------------ |
| [`example/azure_secrets_example.dart`](example/azure_secrets_example.dart) | A service principal's token, a field of a JSON secret loaded through `TomSecrets`, and a new version reaching a watcher on refresh while the cached token is reused — against in-process stand-ins for Entra ID and Key Vault, so it runs anywhere |

```bash
dart run example/azure_secrets_example.dart
```

`test/azure/example_test.dart` runs it and requires a clean exit.

### Configuration

`TomAzureKeyVaultSecretsProvider.fromConfiguration` reads the `secrets.azure`
key of the configuration resources; each setting but `managedIdentity` falls
back to an environment variable when an `environment` map is passed:

| Setting | Variable | Meaning |
| ------- | -------- | ------- |
| `vaultUri` | `AZURE_KEYVAULT_URL` | The vault, `https://<name>.vault.azure.net/`. Required. |
| `managedIdentity` | — | `true` uses the host's managed identity. |
| `tenantId` · `clientId` · `clientSecret` | `AZURE_TENANT_ID` · `AZURE_CLIENT_ID` · `AZURE_CLIENT_SECRET` | A service principal. With `managedIdentity`, `clientId` selects a user-assigned identity. |

**Outgoing calls are resilient by default.** Without an `httpClient` of its own,
`TomAzureKeyVaultSecretsProvider` sends through the kernel's `TomResilientClient`, under the policy of
the vault, Entra ID and the managed identity endpoint that `tom_core_server`'s `httpClient` configuration key sets — a
30-second timeout per attempt by default, and a circuit breaker and a bulkhead
per destination. The token requests use the same client, each destination with its own circuit; `GET`s are retried after a connection failure, a timeout or a `429`/`502`/`503`/`504`, the service principal's token `POST` is sent once. Name a destination under `httpClient.destinations`
to give it its own policy; `TomSecrets.load` runs before the server applies the
key, so a boot that wants it at load applies it first — see
[`tom_core_server/doc/configuration.md`](../../core/tom_core_server/doc/configuration.md#outgoing-http-calls) and [`doc/azure_secrets.md`](doc/azure_secrets.md#the-http-client).

### Limits

- **The provider's own settings are literal values.** `secrets.azure` holds
  the credentials that open the store, so a reference inside it is not
  resolved.
- **Three credentials are built in.** A certificate credential, workload
  identity federation or the Azure CLI's cache are not; each is an
  implementation of `TomAzureCredential`.
- **A pinned version does not move.** `name/<version>` reads that version on
  every refresh, so only an unpinned reference follows a rotation.

### Further documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/azure_secrets.md](doc/azure_secrets.md) | The reference syntax, configuration, the three credentials and token caching, refresh, the Key Vault key-encryption key, the error keys and the emulator suite |
| [doc/api/api_summary_azure.md](doc/api/api_summary_azure.md) | Every public type and member |
| [`tom_core_server/doc/configuration.md`](../../core/tom_core_server/doc/configuration.md#secret-references) | Secret references in general: syntax, precedence, boot order, rotation, writing a provider |

The Vault and AWS providers are [`vault.dart`](#hashicorp-vault-vaultdart)
and [`aws.dart`](#aws-secrets-manager-awsdart).

## HashiCorp Vault (`vault.dart`)

### Overview

`tom_core_server` lets any configuration value be written as a **reference**
to a secret store instead of the value itself:

```yaml
jwtSharedSecretKey: "secret:vault:secret/data/billing#jwt"
```

The server resolves every reference once at boot, before it builds its
configuration object, and puts the secret where the reference was. Which store
a reference reaches is decided by the provider registered under the name in
its middle part. This package is that provider for HashiCorp Vault:
`TomVaultSecretsProvider`, registered as `vault`.

A reference names the API path after `/v1/`, exactly as Vault's own CLI and
documentation do, and `#<field>` picks one value of the entry. Both KV versions
are read — version 2 nests the entry under `data` a second time and carries a
version number — and so is any engine whose response holds its values under
`data`. The provider talks to Vault over HTTP with `package:http`; there is no
Vault SDK in between.

Two ways to authenticate are built in: a fixed **token** (a developer's
`VAULT_TOKEN`, an agent sidecar, a CI job) and **AppRole** (a role id and a
secret id exchanged for a token that is renewed by logging in again).

### Features

| Type | What it does |
| ---- | ------------ |
| `TomVaultSecretsProvider` | The `TomSecretsProvider` over Vault: `fetch` reads a path through `GET /v1/<path>`, understands KV version 1 and 2, sends the namespace header, and retries once with a fresh token after a `403`. `fromConfiguration` builds one from `secrets.vault`, falling back to Vault's own environment variables. |
| `TomVaultAuth` | How the provider obtains its token — `token` and `invalidate`. |
| `TomVaultTokenAuth` | A fixed token. |
| `TomVaultAppRoleAuth` | AppRole: logs in at `auth/<mount>/login`, keeps the token for nine tenths of its lease, and logs in again when the lease runs out or Vault refuses the token. |
| `TomVaultTransitKeyEncryptionKey` | A key-encryption key for field encryption held by Vault's Transit engine, the kind `vault-transit`: wraps a data key with Transit `encrypt` and unwraps it with `decrypt`, the data key id bound as associated data. |

### Quick start

A server registers the provider before it loads its secrets, and loads them
before it builds its configuration:

```dart
import 'dart:io';

import 'package:tom_core_secrets/vault.dart';
import 'package:tom_core_server/tom_core_server.dart';

Future<void> main(List<String> args) async {
  TomSecrets.register(
    TomVaultSecretsProvider.fromConfiguration(
      environment: Platform.environment, // VAULT_ADDR, VAULT_TOKEN, ...
    ),
  );
  await TomSecrets.load(TomBaseServerConfiguration.collectSources(args));
  print(TomSecrets.current('secret:vault:secret/data/billing#jwt'));
  // the field `jwt` of the KV v2 entry `billing`
}
```

The configuration class built after `TomSecrets.load` receives the secret, not
the reference: `TomBaseServerConfiguration.getDefaultValues` substitutes every
loaded reference in place. `TomSecrets.startRefresh` keeps the values current
when Vault rotates them; see [doc/vault_secrets.md](doc/vault_secrets.md).

Without a configuration, construct the provider directly:

```dart
final provider = TomVaultSecretsProvider(
  address: Uri.parse('https://vault.example.com:8200'),
  auth: TomVaultAppRoleAuth(roleId: roleId, secretId: secretId),
  namespace: 'team-a',
);
```

### Example

| Example | Demonstrates |
| ------- | ------------ |
| [`example/vault_secrets_example.dart`](example/vault_secrets_example.dart) | Building the provider from configuration, loading two fields of one KV v2 entry, and a rotation reaching a watcher on refresh — against an in-process stand-in for Vault, so it runs anywhere |

```bash
dart run example/vault_secrets_example.dart
```

`test/vault/example_test.dart` runs it and requires a clean exit.

### Configuration

`TomVaultSecretsProvider.fromConfiguration` reads the `secrets.vault` key of
the configuration resources; each setting falls back to an environment
variable when an `environment` map is passed:

| Setting | Variable | Meaning |
| ------- | -------- | ------- |
| `address` | `VAULT_ADDR` | Where Vault answers. Required. |
| `token` | `VAULT_TOKEN` | A fixed token. |
| `roleId` · `secretId` | `VAULT_ROLE_ID` · `VAULT_SECRET_ID` | AppRole; preferred over a token when both are given. |
| `appRoleMount` | `VAULT_APPROLE_MOUNT` | Where the AppRole method is mounted; `approle` by default. |
| `namespace` | `VAULT_NAMESPACE` | The Vault Enterprise namespace, sent as `X-Vault-Namespace`. |

**Outgoing calls are resilient by default.** Without an `httpClient` of its own,
`TomVaultSecretsProvider` sends through the kernel's `TomResilientClient`, under the policy of
Vault's address that `tom_core_server`'s `httpClient` configuration key sets — a
30-second timeout per attempt by default, and a circuit breaker and a bulkhead
per destination. Reads are retried after a connection failure, a timeout or a `429`/`502`/`503`/`504`; the AppRole login `POST` is sent once. Name a destination under `httpClient.destinations`
to give it its own policy; `TomSecrets.load` runs before the server applies the
key, so a boot that wants it at load applies it first — see
[`tom_core_server/doc/configuration.md`](../../core/tom_core_server/doc/configuration.md#outgoing-http-calls) and [`doc/vault_secrets.md`](doc/vault_secrets.md#the-http-client).

### Limits

- **The provider's own settings are literal values.** `secrets.vault` holds
  the credentials that open the store, so it is read as written and a
  reference inside it is not resolved.
- **A dynamic secret's lease is not renewed.** An engine that issues
  credentials with a lease — the database engine, say — is read like any
  other; the provider re-reads the path on refresh, and renewing or revoking
  the lease stays with Vault.
- **Only token and AppRole are built in.** Another auth method is an
  implementation of `TomVaultAuth`, which logs in through the provider's public
  `call`.

### Further documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/vault_secrets.md](doc/vault_secrets.md) | The reference syntax, configuration, the two auth methods, namespaces, refresh, the Transit key-encryption key, the error keys and the emulator suite |
| [doc/api/api_summary_vault.md](doc/api/api_summary_vault.md) | Every public type and member |
| [`tom_core_server/doc/configuration.md`](../../core/tom_core_server/doc/configuration.md#secret-references) | Secret references in general: syntax, precedence, boot order, rotation, writing a provider |

The AWS and Azure providers are [`aws.dart`](#aws-secrets-manager-awsdart)
and [`azure.dart`](#azure-key-vault-azuredart).

## Key-encryption keys for field encryption

`tom_core_server`'s field-level encryption keeps its data keys wrapped under a
**key-encryption key**. An application-held AES key is built in; each library
of this package adds a key that never leaves its service, as a `kind` of
`fieldEncryption.keys` entry:

| Kind | Class | Library | Wraps with | Settings |
| ---- | ----- | ------- | ---------- | -------- |
| `aws-kms` | `TomAwsKmsKeyEncryptionKey` | `aws.dart` | KMS `Encrypt` / `Decrypt`, encryption context `{"tom-data-key": <id>}` | `kmsKeyId` (required), `region`, `endpoint` |
| `vault-transit` | `TomVaultTransitKeyEncryptionKey` | `vault.dart` | Transit `encrypt` / `decrypt`, associated data `tom-data-key:<id>` | `keyName` (required), `mount` (default `transit`) |
| `azure-keyvault` | `TomAzureKeyVaultKeyEncryptionKey` | `azure.dart` | Key Vault `wrapkey` / `unwrapkey`, the id framed into the wrapped bytes | `keyName` (required), `keyVersion`, `algorithm` (default `RSA-OAEP-256`) |

Each class's `register()` registers its kind with
`TomFieldEncryption.registerKeyKind`; a boot calls it before `TomServer.start`
applies `fieldEncryption`. The key reaches its service with the settings of the
library's secrets provider (`secrets.aws`, `secrets.vault`, `secrets.azure`, or
their environment variables), so the entry carries no secret:

```dart
import 'dart:io';

import 'package:tom_core_secrets/aws.dart';

void registerFieldKeys() =>
    TomAwsKmsKeyEncryptionKey.register(environment: Platform.environment);
```

```yaml
fieldEncryption:
  datasource: main
  keys:
    - id: kms-2026
      kind: aws-kms
      kmsKeyId: alias/field-keys
    - id: kek-2025                   # the AES key it replaces, until rewrap
      key: "secret:vault:secret/data/billing#fieldKek"
```

Listing the service key first and the AES key after it, then running
`TomFieldEncryption.keyring!.rewrap()`, moves every data key under the service
key. A malformed entry is refused with `secrets.kek.config.invalid`; a service
that refuses or cannot be reached, or a wrapped key that does not unwrap under
the asked data key id, fails with `secrets.kek.failed`. The settings, the
permissions and the tests are in each provider's guide —
[AWS](doc/aws_secrets.md#key-encryption-keys-for-field-encryption),
[Vault](doc/vault_secrets.md#key-encryption-keys-for-field-encryption),
[Azure](doc/azure_secrets.md#key-encryption-keys-for-field-encryption) — and
the field-encryption side in
[`tom_core_server/doc/object_persistence.md`](../../core/tom_core_server/doc/object_persistence.md#keys-held-by-a-key-management-service).

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `tom_core_server` | runtime | `TomSecretsProvider`, `TomSecretPayload`, `TomSecretsException`, `TomServerConfigResourceProvider`, `TomKeyEncryptionKey` and `TomFieldEncryption.registerKeyKind` (the key-encryption keys), the SigV4 signer `TomAwsV4Signer` with `TomAwsCredentials` and `TomAwsCredentialsSource` (`aws.dart`), and the kernel's `TomResilientClient` it re-exports — the default client |
| `tom_core_kernel` | runtime | the framework base the server builds on |
| `http` | runtime | the Secrets Manager, KMS, Key Vault and Vault HTTP APIs |
| `crypto` | runtime | SHA-256 and HMAC for SigV4 (`aws.dart`) |
| `test`, `lints` | dev | the suites |

## Status

Version **0.2.0**. `dart test` runs the unit suites, which drive each provider
against `MockClient` stand-ins, and the three examples. The tests tagged
`emulator` run against each provider's emulator and skip themselves when it does
not answer; `tool/run_aws_emulator_tests.sh`, `tool/run_azure_emulator_tests.sh`
and `tool/run_vault_emulator_tests.sh` start one in Docker, run that provider's
emulator tests, and fail when every one of them skipped.

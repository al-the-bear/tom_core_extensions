# Tom Core Secrets AWS API Reference: tom_core_secrets/aws.dart

AWS Secrets Manager as a secrets provider for Tom servers, and AWS KMS as a
key-encryption key for field encryption: the provider and the KMS key. One
library, `package:tom_core_secrets/aws.dart`.

For the reference syntax, configuration, credentials, signing, the KMS key's
settings and the error keys, see [aws_secrets.md](../aws_secrets.md);
for the framework side (`TomSecrets`, `TomSecretsProvider`, `TomSecretPayload`,
`TomSecretsException`), `tom_core_server`'s
[configuration API summary](../../../../core/tom_core_server/doc/api/api_summary_configuration.md);
for `TomAwsCredentials`, `TomAwsCredentialsSource` and `TomAwsV4Signer`, its
[file storage API summary](../../../../core/tom_core_server/doc/api/api_summary_file_storage.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomAwsSecretsProvider](#tomawssecretsprovider)
  - [TomAwsKmsKeyEncryptionKey](#tomawskmskeyencryptionkey)

## Overview

Source: `lib/src/aws/`.

| File | Declares |
| ---- | -------- |
| `aws/aws_secrets_provider.dart` | `TomAwsSecretsProvider` |
| `aws/aws_kms_key.dart` | `TomAwsKmsKeyEncryptionKey` |

The provider is registered with `TomSecrets.register` and answers every
reference `secret:aws:<secret name or ARN>[#<field>]`. Requests are signed with
`tom_core_server`'s `TomAwsV4Signer`; `TomAwsCredentials` and the
credentials source `TomAwsCredentialsSource` are that package's types.
`TomAwsKmsKeyEncryptionKey` is registered with `TomFieldEncryption` as the key
kind `aws-kms` and signs its KMS calls the same way, with the provider's
credentials.

## Class Hierarchy

```text
TomSecretsProvider  (tom_core_server)
    └── TomAwsSecretsProvider  (implements)

TomKeyEncryptionKey  (tom_core_server)
    └── TomAwsKmsKeyEncryptionKey  (implements)
```

## Classes

### TomAwsSecretsProvider

A `TomSecretsProvider` over AWS Secrets Manager.

- **Implements:** `TomSecretsProvider` (from `tom_core_server`)

#### Constructors

```dart
TomAwsSecretsProvider({
  required this.region,
  required this.credentials,
  Uri? endpoint,
  this.name = 'aws',
  http.Client? httpClient,
  DateTime Function()? clock,
})
```

`endpoint` defaults to `https://secretsmanager.<region>.amazonaws.com/`;
`httpClient` to a `TomResilientClient` (the kernel's) over a new `http.Client`,
so every call runs under the endpoint's timeout, circuit breaker and bulkhead,
closed by `close`; `clock` to
`DateTime.now`, the signing time.

#### Factory Constructors

```dart
factory TomAwsSecretsProvider.fromConfiguration({
  TomServerConfigResourceProvider? config,
  Map<String, String>? environment,
})
```

| Factory | Description |
| ------- | ----------- |
| `fromConfiguration` | Builds the provider from the `secrets.aws` key of `config` (the active provider when omitted): `region`, `accessKeyId`, `secretAccessKey`, `sessionToken`, `endpoint`. Each falls back to `AWS_REGION` then `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_ENDPOINT_URL_SECRETS_MANAGER` in `environment` (none when omitted). The credentials source answers one fixed `TomAwsCredentials`. Throws `secrets.aws.config.missing_region` or `secrets.aws.config.missing_credentials`. |

#### Static Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `configurationKey` | `String` | The configuration key the settings are read from, `secrets.aws` (a `const`). |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `region` | `String` | The region the secrets live in, and the signature's region. |
| `credentials` | `TomAwsCredentialsSource` | Where each request's credentials come from. |
| `endpoint` | `Uri` | The Secrets Manager endpoint. |
| `name` | `String` | The provider name references use; `aws` by default. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `fetch` | `Future<TomSecretPayload> fetch(String path)` | `GetSecretValue` for the secret id `path`: the `SecretString`, else the `SecretBinary` decoded as UTF-8, with the `VersionId` as the payload version. Throws `secrets.aws.binary_not_text` for a binary that is not text, `secrets.fetch.failed` for an answer with neither. |
| `call` | `Future<Map<String, Object?>> call(String action, Map<String, Object?> request, {String? path})` | Calls the Secrets Manager action `action` with `request`, signed with SigV4, and answers the decoded body. `path` names the secret in a failure. Throws `secrets.fetch.not_found` for a `ResourceNotFoundException`, `secrets.fetch.failed` for an unreachable endpoint or any other status `>= 300`, carrying AWS's error type and message. Public so a test or a tool administers secrets through the same signed client. |
| `close` | `Future<void> close()` | Closes the HTTP client. |

### TomAwsKmsKeyEncryptionKey

A key-encryption key for field encryption whose key never leaves AWS KMS: a
data key is wrapped with KMS `Encrypt` and unwrapped with `Decrypt` (the
`TrentService` JSON 1.1 API), signed with `TomAwsV4Signer` for the service
`kms`, under the encryption context `{"tom-data-key": <data key id>}`.

- **Implements:** `TomKeyEncryptionKey` (from `tom_core_server`)

#### Constructors

```dart
TomAwsKmsKeyEncryptionKey({
  required this.id,
  required this.kmsKeyId,
  required this.region,
  required this.credentials,
  Uri? endpoint,
  http.Client? httpClient,
  DateTime Function()? clock,
})
```

`endpoint` defaults to `https://kms.<region>.amazonaws.com/`; `httpClient` to a
`TomResilientClient` over a new `http.Client`, closed by `close`; `clock` to
`DateTime.now`, the signing time.

#### Static Constants

| Constant | Type | Value | Description |
| -------- | ---- | ----- | ----------- |
| `kind` | `String` | `'aws-kms'` | The kind of a `fieldEncryption.keys` entry this key is built for. |
| `contextKey` | `String` | `'tom-data-key'` | The encryption-context key the data key's id is bound under. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `register` | `static void register({TomServerConfigResourceProvider? config, Map<String, String>? environment})` | Registers the kind `aws-kms` with `TomFieldEncryption.registerKeyKind`; each entry of that kind is built by `fromSettings` with `config` and `environment`. |
| `fromSettings` | `static TomAwsKmsKeyEncryptionKey fromSettings(String id, Map<String, Object?> settings, {TomServerConfigResourceProvider? config, Map<String, String>? environment})` | The key `id` an entry's `settings` describe: `kmsKeyId` (required), `region` (default the provider's), `endpoint` (default `AWS_ENDPOINT_URL_KMS` in `environment`, else the regional endpoint). The region and credentials come from `TomAwsSecretsProvider.fromConfiguration(config:, environment:)`. Throws `secrets.kek.config.invalid` without a `kmsKeyId`, and the provider's own refusals without a region or credentials. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `id` | `String` | The key's id, recorded with every data key it wraps. |
| `kmsKeyId` | `String` | The KMS key that wraps: a key id, an ARN or an alias. |
| `region` | `String` | The region the KMS key lives in. |
| `credentials` | `TomAwsCredentialsSource` | Where the credentials come from, asked for every request. |
| `endpoint` | `Uri` | The KMS endpoint. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `wrap` | `Future<List<int>> wrap(List<int> dataKey, {required String keyId})` | KMS `Encrypt` of `dataKey` under `kmsKeyId` with the encryption context of `keyId`; answers the `CiphertextBlob`. |
| `unwrap` | `Future<List<int>> unwrap(List<int> wrapped, {required String keyId})` | KMS `Decrypt` of `wrapped` with the encryption context of `keyId`; answers the `Plaintext`. A key wrapped for another id is refused by KMS, `secrets.kek.failed`. |
| `call` | `Future<Map<String, Object?>> call(String action, Map<String, Object?> request)` | Calls the KMS action `action` (`x-amz-target: TrentService.<action>`) with `request`, signed with SigV4, and answers the decoded body. Throws `secrets.kek.failed` for an unreachable endpoint or any status `>= 300`, carrying KMS's error type and message. Public so a test or a tool administers keys through the same signed client. |
| `close` | `Future<void> close()` | Closes the HTTP client. |

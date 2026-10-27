# Tom Core Secrets AWS API Reference: tom_core_secrets/aws.dart

AWS Secrets Manager as a secrets provider for Tom servers: the provider and the
credentials-source type it signs with. One library,
`package:tom_core_secrets/aws.dart`.

For the reference syntax, configuration, credentials, signing and the error
keys, see [aws_secrets.md](../aws_secrets.md); for the framework side
(`TomSecrets`, `TomSecretsProvider`, `TomSecretPayload`,
`TomSecretsException`), `tom_core_server`'s
[configuration API summary](../../../../core/tom_core_server/doc/api/api_summary_configuration.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomAwsSecretsProvider](#tomawssecretsprovider)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

Source: `lib/src/aws_secrets_provider.dart`.

| File | Declares |
| ---- | -------- |
| `aws_secrets_provider.dart` | `TomAwsCredentialsSource`, `TomAwsSecretsProvider` |

The provider is registered with `TomSecrets.register` and answers every
reference `secret:aws:<secret name or ARN>[#<field>]`. Requests are signed with
`tom_core_server`'s `TomAwsV4Signer`; `TomAwsCredentials` is that package's
type.

## Class Hierarchy

```text
TomSecretsProvider  (tom_core_server)
    └── TomAwsSecretsProvider  (implements)
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

## Global Functions and Constants

```dart
typedef TomAwsCredentialsSource = Future<TomAwsCredentials> Function();
```

| Name | Signature | Description |
| ---- | --------- | ----------- |
| `TomAwsCredentialsSource` | `typedef TomAwsCredentialsSource = Future<TomAwsCredentials> Function()` | Supplies the credentials a request is signed with. Called for every request, so a source can hand out refreshed temporary credentials — a role's, cached until shortly before they expire. |

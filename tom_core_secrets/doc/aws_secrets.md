# AWS Secrets Manager secrets

`TomAwsSecretsProvider` answers every configuration reference that names the
`aws` provider. This page covers the AWS side: how a reference names a secret,
how the provider is configured, where its credentials come from, how requests
are signed, how it reacts to rotation and refusal, how a KMS key serves as a
key-encryption key for field encryption, and how its emulator suite runs. How
references work in general — where they may appear, their precedence, the boot
order and the refresh cycle — is in
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#secret-references).

## Table of Contents

- [The reference](#the-reference)
- [Registering the provider](#registering-the-provider)
- [Configuration](#configuration)
- [The HTTP client](#the-http-client)
- [Credentials](#credentials)
- [Signing](#signing)
- [Rotation](#rotation)
- [Key-encryption keys for field encryption](#key-encryption-keys-for-field-encryption)
- [Error keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## The reference

```text
secret:aws:<secret name or ARN>[#<field>]
```

| Reference | Reads |
| --------- | ----- |
| `secret:aws:prod/billing#password` | member `password` of the JSON object the secret `prod/billing` holds |
| `secret:aws:prod/jwt-key` | the whole `SecretString` of `prod/jwt-key` |
| `secret:aws:arn:aws:secretsmanager:eu-west-1:123456789012:secret:prod/billing-AbCdEf#user` | member `user`, by ARN — the colons of an ARN belong to the path |

`fetch` calls `GetSecretValue` with the reference's path as `SecretId` and
answers the secret's `SecretString`, or — for a secret stored as
`SecretBinary` — the binary decoded as UTF-8. The `VersionId` becomes
`TomSecretPayload.version`.

The payload is one string. Without `#<field>` that string is the value. With a
field, the framework decodes the string as a JSON object and takes the member;
a member that is not a string is handed on JSON-encoded. A string that is not a
JSON object, or one without the member, fails with `secrets.field.missing`.
Each secret is read once per load or refresh, however many of its fields the
configuration names.

## Registering the provider

A boot registers the provider before it loads the references, and loads them
before it builds the configuration object:

```dart
import 'dart:io';

import 'package:tom_core_secrets/aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

Future<void> boot(List<String> args) async {
  TomSecrets.register(
    TomAwsSecretsProvider.fromConfiguration(environment: Platform.environment),
  );
  await TomSecrets.load(TomBaseServerConfiguration.collectSources(args));
  TomSecrets.startRefresh(const Duration(minutes: 15));
}
```

`fromConfiguration` reads the active configuration provider unless a `config`
is passed, and consults the environment only through the `environment` map —
pass `Platform.environment`, or `TomEnvFile.resolveEnvironment()` to include a
`.env` file.

The constructor takes the region and a credentials source; `endpoint`
overrides the regional endpoint, `name` registers the provider under another
name (one per account or region, `aws` and `aws-us`), and `httpClient` replaces
the default client, a `TomResilientClient` over a new `http.Client` (see [The
HTTP client](#the-http-client)):

```dart
final provider = TomAwsSecretsProvider(
  region: 'eu-west-1',
  credentials: roleCredentials,
  endpoint: Uri.parse('https://vpce-0123.secretsmanager.eu-west-1.vpce.amazonaws.com/'),
  name: 'aws',
);
```

## Configuration

`fromConfiguration` reads `secrets.aws`. A setting the configuration does not
carry, or carries empty, falls back to the first variable that is set:

```yaml
secrets:
  aws:
    region: eu-west-1          # or AWS_REGION / AWS_DEFAULT_REGION
    accessKeyId: ...           # or AWS_ACCESS_KEY_ID
    secretAccessKey: ...       # or AWS_SECRET_ACCESS_KEY
    sessionToken: ...          # or AWS_SESSION_TOKEN (optional)
    endpoint: http://localhost:4566   # or AWS_ENDPOINT_URL_SECRETS_MANAGER
```

| Setting | Variables | Default | Meaning |
| ------- | --------- | ------- | ------- |
| `region` | `AWS_REGION`, `AWS_DEFAULT_REGION` | — | The region. Without it the provider is refused, `secrets.aws.config.missing_region`. |
| `accessKeyId` | `AWS_ACCESS_KEY_ID` | — | The access key id. |
| `secretAccessKey` | `AWS_SECRET_ACCESS_KEY` | — | The secret access key. Without both keys the provider is refused, `secrets.aws.config.missing_credentials`. |
| `sessionToken` | `AWS_SESSION_TOKEN` | none | The session token of temporary credentials. |
| `endpoint` | `AWS_ENDPOINT_URL_SECRETS_MANAGER` | `https://secretsmanager.<region>.amazonaws.com/` | A VPC endpoint, or an emulator. |

`secrets.aws` is read as written: it holds the credentials that open the
store, so a reference inside it is not resolved.

## The HTTP client

Without an `httpClient` of its own the provider sends through the kernel's
`TomResilientClient`, so every call to Secrets Manager runs under the policy of
its destination — the regional endpoint, or `endpoint` — that
`tom_core_server`'s `httpClient` configuration key sets; see
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#outgoing-http-calls). Every
Secrets Manager action is a `POST`, so the client does not retry one; what
applies is the timeout on the attempt (30 seconds by default) and the
destination's circuit breaker and bulkhead. A call the policy abandons or
refuses fails as `secrets.fetch.failed`.

```yaml
httpClient:
  destinations:
    "https://secretsmanager.eu-west-1.amazonaws.com": {timeoutMs: 5000}
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

A `TomAwsCredentialsSource` is `tom_core_server`'s
`Future<TomAwsCredentials> Function()`, defined beside `TomAwsV4Signer`, and
`TomAwsCredentials` that package's access key id, secret access key and
optional session token; a provider imports both from
`package:tom_core_server/tom_core_server.dart`. The source is called for **every request**, so it decides how long a set of
credentials lives. `fromConfiguration` answers one fixed `TomAwsCredentials`
built from the settings. A deployment on an instance profile, a container task
role or an assumed role constructs the provider with a source that returns the
role's current temporary credentials — read from the platform's credential
endpoint and cached by the source until shortly before they expire:

```dart
import 'package:tom_core_secrets/aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

TomAwsCredentials? cached;
DateTime cachedUntil = DateTime(0);

Future<TomAwsCredentials> roleCredentials() async {
  if (cached == null || DateTime.now().isAfter(cachedUntil)) {
    final (credentials, expiry) = await fetchRoleCredentials();
    cached = credentials;
    cachedUntil = expiry.subtract(const Duration(minutes: 5));
  }
  return cached!;
}
```

`fetchRoleCredentials` stands for the platform's own call — the instance
metadata service, the container credentials endpoint, or STS — which this
package does not make.

## Signing

Each request is a `POST` to the endpoint with `content-type:
application/x-amz-json-1.1`, `x-amz-target: secretsmanager.<Action>` and the
JSON request body. It is signed with `tom_core_server`'s `TomAwsV4Signer` for
the service `secretsmanager` and the configured region: the signer adds
`x-amz-date`, `x-amz-content-sha256` (the SHA-256 of the body),
`x-amz-security-token` when the credentials carry a session token, and the
`authorization` header. `host` is part of the signature but is set by the HTTP
client from the URL rather than sent from the signed map — the same way the S3
blob store sends its requests.

`call(action, request)` is that signed client for any action; the emulator
suite uses it to create and rotate secrets (`CreateSecret`,
`PutSecretValue`) through the same code path the provider reads with.

## Rotation

The provider holds no secret values; `TomSecrets` does. `TomSecrets.refresh`
reads every loaded secret again, and the watchers of a reference whose value
changed are called with the new one. Because `GetSecretValue` without a
version answers `AWSCURRENT`, a rotation Secrets Manager performs — by its
rotation Lambda or a `PutSecretValue` — is seen at the next refresh. A refresh
that cannot read a secret keeps the last value and lists the reference in
`TomSecretsRefresh.failed`; only the first `TomSecrets.load` fails the boot.

## Key-encryption keys for field encryption

`TomAwsKmsKeyEncryptionKey` (`lib/src/aws/aws_kms_key.dart`) is a
`TomKeyEncryptionKey` for `tom_core_server`'s field-level encryption whose key
never leaves AWS KMS: a data key is wrapped with KMS `Encrypt` and unwrapped
with `Decrypt` (the `TrentService` JSON 1.1 API, `x-amz-target:
TrentService.<Action>`), signed with `TomAwsV4Signer` for the service `kms`.
Every call carries the encryption context `{"tom-data-key": <data key id>}`
(`TomAwsKmsKeyEncryptionKey.contextKey`), so KMS refuses to decrypt a wrapped
key under any other id. How field encryption uses its key-encryption keys is in
[`tom_core_server/doc/object_persistence.md`](../../../core/tom_core_server/doc/object_persistence.md#keys-held-by-a-key-management-service).

`TomAwsKmsKeyEncryptionKey.register()` registers the kind `aws-kms`
(`TomAwsKmsKeyEncryptionKey.kind`) with `TomFieldEncryption.registerKeyKind`, so
a `fieldEncryption.keys` entry of that kind builds its key. It runs before
`TomServer.start` applies `fieldEncryption`; it takes the same `config` and
`environment` as `fromConfiguration`:

```dart
TomAwsKmsKeyEncryptionKey.register(environment: Platform.environment);
```

```yaml
fieldEncryption:
  datasource: main
  keys:
    - id: kms-2026
      kind: aws-kms
      kmsKeyId: alias/field-keys       # required
      region: eu-central-1             # default: secrets.aws / AWS_REGION
      endpoint: http://localhost:4566  # default: AWS_ENDPOINT_URL_KMS
```

| Setting | Default | Meaning |
| ------- | ------- | ------- |
| `kmsKeyId` | required | The KMS key that wraps: a key id, an ARN or an alias such as `alias/field-keys`. Without it the entry is refused, `secrets.kek.config.invalid`. |
| `region` | the provider's region (`secrets.aws.region`, `AWS_REGION`, `AWS_DEFAULT_REGION`) | The region the KMS key lives in. |
| `endpoint` | `AWS_ENDPOINT_URL_KMS`, else `https://kms.<region>.amazonaws.com/` | A VPC endpoint, or an emulator. |

The credentials are the secrets provider's — `secrets.aws` or the standard
`AWS_*` variables, read as [Configuration](#configuration) describes — so the
entry carries no secret. `TomAwsKmsKeyEncryptionKey.fromSettings(id, settings)`
builds the key `register` builds; the constructor takes a
`TomAwsCredentialsSource` of its own, for a role's temporary credentials.
`call(action, request)` is the signed KMS client for any action (the emulator
suite creates its key with `CreateKey`), and `close()` closes the HTTP client.
Its calls go through a `TomResilientClient`, like the provider's.

The principal needs `kms:Encrypt` and `kms:Decrypt` on the key. A KMS key
rotated by KMS keeps decrypting what its earlier key material encrypted, so
automatic key rotation needs no `rewrap`; moving to another KMS key is a
key-encryption-key rotation in `fieldEncryption.keys`.

| Key | When |
| --- | ---- |
| `secrets.kek.config.invalid` | The entry has no `kmsKeyId`. |
| `secrets.kek.failed` | KMS could not be reached, or refused the call — a key it does not hold, access denied, or a wrapped key that does not decrypt under the asked data key id (encryption context mismatch); the message carries KMS's error type. |

## Error keys

Every failure is a `TomSecretsException`; its message names the secret id and
carries AWS's own explanation of a refusal, never a secret's value.

| Key | When |
| --- | ---- |
| `secrets.aws.config.missing_region` | `fromConfiguration` found no region. |
| `secrets.aws.config.missing_credentials` | `fromConfiguration` found no access key id or secret access key. |
| `secrets.aws.binary_not_text` | The secret is `SecretBinary` that is not UTF-8 text. |
| `secrets.fetch.not_found` | Secrets Manager answered `ResourceNotFoundException`. |
| `secrets.fetch.failed` | The endpoint could not be reached; any other refusal — access denied, a bad signature, a secret scheduled for deletion — with the status and the AWS error type (parameters `provider`, `path`, `status`); or an answer with neither `SecretString` nor `SecretBinary`. |

The framework adds its own around them — `secrets.field.required`,
`secrets.field.missing`, `secrets.provider.unknown`,
`secrets.reference.malformed` and `secrets.reference.unresolved`; see
`tom_core_server/doc/configuration.md`.

## Not Yet Implemented

- **No built-in role credentials.** The instance metadata service, the ECS
  credentials endpoint and STS `AssumeRole` are not called by the package; a
  role is supplied as a `TomAwsCredentialsSource`.
- **No version or staging-label pinning.** A reference always reads
  `AWSCURRENT`.

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/aws/aws_secrets_provider_test.dart` | `fromConfiguration`'s settings, the environment fallbacks and its refusals; a SigV4-signed `GetSecretValue` for the secret id; `ResourceNotFoundException` mapped to `not_found` and other refusals to `failed`; a binary secret that is not text refused by key. Runs against `MockClient`. |
| `test/aws/example_test.dart` | Runs `example/aws_secrets_example.dart` and requires exit 0. |
| `test/aws/aws_emulator_test.dart` | Tagged `emulator`. Against LocalStack: a plain secret with its version, a member of a JSON secret resolved through `TomSecrets`, a binary secret that is text, a rotation reaching a watcher, and `not_found` for an absent secret. Skips itself when LocalStack does not answer. |
| `test/key_encryption_key_settings_test.dart` | KS-1 to KS-6, for all three key-encryption keys: an `aws-kms` entry's KMS key, and its region and endpoint from the entry or the secrets provider's settings (KS-1); an entry without its key refused with `secrets.kek.config.invalid` (KS-4); each library registering its kind with field encryption (KS-5). No emulator. |
| `test/aws/aws_kek_emulator_test.dart` | Tagged `emulator`. Against LocalStack's KMS, through the shared contract `test/support/key_encryption_key_contract.dart`: a data key wraps and unwraps under its own id (KMS-1); a wrapped key does not unwrap under another id, `secrets.kek.failed` (KMS-2); a keyring over the KMS key encrypts, rotates its data key and rewraps the data keys of an application-held key under it, and a fresh keyring holding only the KMS key reads everything (KMS-3); a KMS key KMS does not hold refused with `secrets.kek.failed` (KMS-4). Creates its KMS key with `call('CreateKey', ...)`. Skips itself when LocalStack does not answer. |

```bash
dart test                         # unit suite + example; emulator tests skip
./tool/run_aws_emulator_tests.sh      # the emulator suite against LocalStack
```

`tool/run_aws_emulator_tests.sh` starts `localstack/localstack:3.8` with only
Secrets Manager and KMS enabled (`SERVICES=secretsmanager,kms`) on
`127.0.0.1:14566` (`AWS_TEST_PORT` overrides the port), waits until
`/_localstack/health` reports both services available, runs
`dart test --tags emulator test/aws` with `AWS_TEST_ENDPOINT` pointing at it,
and removes the container. A run in which every emulator test skipped is reported
as a failure, because it means LocalStack never answered. It needs Docker.

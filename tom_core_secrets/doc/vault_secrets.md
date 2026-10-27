# HashiCorp Vault secrets

`TomVaultSecretsProvider` answers every configuration reference that names the
`vault` provider. This page covers the Vault side: how a reference names a
Vault path, how the provider is configured and authenticates, how it reacts to
rotation and refusal, and how its emulator suite runs. How references work in
general — where they may appear, their precedence, the boot order and the
refresh cycle — is in
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#secret-references).

## Table of Contents

- [The reference](#the-reference)
- [Registering the provider](#registering-the-provider)
- [Configuration](#configuration)
- [The HTTP client](#the-http-client)
- [Authentication](#authentication)
  - [A token](#a-token)
  - [AppRole](#approle)
  - [Another method](#another-method)
- [Namespaces](#namespaces)
- [Rotation](#rotation)
- [Error keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## The reference

```text
secret:vault:<api path>[#<field>]
```

The path is what follows `/v1/` in Vault's HTTP API — the same path Vault's CLI
prints and its documentation uses — so the provider sends `GET /v1/<path>` and
nothing is translated:

| Reference | Reads |
| --------- | ----- |
| `secret:vault:secret/data/billing#jwt` | field `jwt` of the KV version 2 entry `billing`, engine mounted at `secret/` |
| `secret:vault:legacy/billing#jwt` | field `jwt` of the KV version 1 entry `billing`, engine mounted at `legacy/` |
| `secret:vault:database/creds/reporting#password` | field `password` of the credentials the database engine issues for the role `reporting` |

A KV version 2 answer nests the entry under `data` a second time and carries
`metadata.version`; the provider unwraps it and reports the version in
`TomSecretPayload.version`. Any other answer holds its values directly under
`data`. Either way the payload is a map, so a Vault reference **names a field**:
without `#<field>` the load fails with `secrets.field.required`, and a field the
entry does not hold fails with `secrets.field.missing`.

Each path is read once per load or refresh, however many of its fields the
configuration names.

## Registering the provider

A boot registers the provider before it loads the references, and loads them
before it builds the configuration object — the order
`tom_core_server/doc/configuration.md` sets out:

```dart
import 'dart:io';

import 'package:tom_core_secrets/vault.dart';
import 'package:tom_core_server/tom_core_server.dart';

Future<void> boot(List<String> args) async {
  TomSecrets.register(
    TomVaultSecretsProvider.fromConfiguration(
      environment: Platform.environment,
    ),
  );
  await TomSecrets.load(TomBaseServerConfiguration.collectSources(args));
  TomSecrets.startRefresh(const Duration(minutes: 5));
}
```

`fromConfiguration` reads the active configuration provider unless a `config`
is passed, and consults the environment only through the `environment` map —
pass `Platform.environment`, or `TomEnvFile.resolveEnvironment()` to include a
`.env` file.

A provider can be built directly as well:

```dart
final provider = TomVaultSecretsProvider(
  address: Uri.parse('https://vault.example.com:8200'),
  auth: TomVaultTokenAuth(token),
);
```

`name` registers it under another provider name — two Vault clusters side by
side, `vault` and `vault-eu`, each answering its own references. `httpClient`
replaces the default client — a `TomResilientClient` over a new `http.Client`
(see [The HTTP client](#the-http-client)): a client with a custom trust store,
or a `MockClient` in a test.

## Configuration

`fromConfiguration` reads `secrets.vault`. A setting the configuration does not
carry, or carries empty, falls back to the variable:

```yaml
secrets:
  vault:
    address: https://vault.example.com:8200   # or VAULT_ADDR
    token: ...                                  # or VAULT_TOKEN
    roleId: ...                                 # or VAULT_ROLE_ID
    secretId: ...                               # or VAULT_SECRET_ID
    appRoleMount: approle                       # or VAULT_APPROLE_MOUNT
    namespace: team-a                           # or VAULT_NAMESPACE
```

| Setting | Variable | Default | Meaning |
| ------- | -------- | ------- | ------- |
| `address` | `VAULT_ADDR` | — | Where Vault answers. Without it the provider is refused, `secrets.vault.config.missing_address`. |
| `roleId` · `secretId` | `VAULT_ROLE_ID` · `VAULT_SECRET_ID` | — | AppRole. When both are present they win over a token. |
| `appRoleMount` | `VAULT_APPROLE_MOUNT` | `approle` | Where the AppRole method is mounted. |
| `token` | `VAULT_TOKEN` | — | A fixed token, used when no AppRole pair is given. With neither, the provider is refused, `secrets.vault.config.missing_credentials`. |
| `namespace` | `VAULT_NAMESPACE` | none | The Vault Enterprise namespace. |

`secrets.vault` is read as written: it holds the credentials that open the
store, so a reference inside it is not resolved. Keep the token or secret id
itself in the environment or a `.env` file the deployment does not commit.

## The HTTP client

Without an `httpClient` of its own the provider sends through the kernel's
`TomResilientClient`, so every call to Vault runs under the policy of Vault's
destination (`scheme://host:port` of `address`) that `tom_core_server`'s
`httpClient` configuration key sets — see
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#outgoing-http-calls): a
timeout on every attempt (30 seconds by default), and a circuit breaker and a
bulkhead per destination. Reads are `GET`s and are retried after a connection
failure, a timeout or a `429`/`502`/`503`/`504` — a standby or sealed node
answers `503`; the AppRole login is a `POST` and is sent once. A call the
policy abandons or refuses fails as `secrets.fetch.failed`.

```yaml
httpClient:
  destinations:
    "https://vault.example.com:8200": {timeoutMs: 5000, retry: {maxAttempts: 4}}
```

**At boot the load comes first.** `TomSecrets.load` runs before
`TomServer.start` applies `httpClient`, so the load runs under the kernel's
defaults unless the boot applies the key itself first —
`TomServer.configureHttpClients` with the merged sources, as
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#outgoing-http-calls) shows. A
refresh after the start runs under the configured policies. A client passed as
`httpClient` replaces the resilient one; wrap it — `TomResilientClient(client)`
— to keep the policies.

## Authentication

Every authenticated call carries `X-Vault-Token`, which the provider asks its
`TomVaultAuth` for. When Vault answers an authenticated call with `403`, the
provider drops the token (`invalidate`) and repeats the call once with a fresh
one; a second `403` is a failure, `secrets.fetch.failed` with the status. For a
fixed token the retry sends the same token, so a token Vault refuses fails
after one repetition; for AppRole the retry logs in again, so a token that
expired early is replaced without failing the read.

### A token

`TomVaultTokenAuth(value)` sends `value` on every call. It suits a developer's
`VAULT_TOKEN`, a Vault Agent that keeps a token file current, or a CI job
handed a short-lived token.

### AppRole

```dart
final auth = TomVaultAppRoleAuth(
  roleId: roleId,
  secretId: secretId,
  mount: 'approle',
);
```

The first call logs in at `auth/<mount>/login` with the role id and secret id
and keeps the returned client token. It is reused until nine tenths of its
`lease_duration` has passed, so a token is never presented in its last seconds,
and the next call then logs in again. A lease of zero is a token that does not
expire. A login answered without `auth.client_token` is
`secrets.vault.login_failed`; a login Vault refuses (a wrong secret id) is
`secrets.fetch.failed` for the path `auth/<mount>/login`.

### Another method

`TomVaultAuth` is two members — `token`, which may log in, and `invalidate`.
Another method (Kubernetes, JWT, TLS certificates) implements them and logs in
through the provider's public `call` with `authenticated: false`, which is how
`TomVaultAppRoleAuth` does it.

## Namespaces

When `namespace` is set, every call carries `X-Vault-Namespace: <namespace>`,
the AppRole login included, so the paths in references are relative to that
namespace.

## Rotation

The provider holds no secret values; `TomSecrets` does. `TomSecrets.refresh`
asks the provider for every loaded path again, and the watchers of a reference
whose value changed are called with the new one. A KV version 2 entry written
with a new version is therefore seen at the next refresh. A refresh that cannot
read a path keeps the last value and lists the reference in
`TomSecretsRefresh.failed`; only the first `TomSecrets.load` fails the boot.

## Error keys

Every failure is a `TomSecretsException`; its message names the path, never a
secret's value.

| Key | When |
| --- | ---- |
| `secrets.vault.config.missing_address` | `fromConfiguration` found neither `secrets.vault.address` nor `VAULT_ADDR`. |
| `secrets.vault.config.missing_credentials` | `fromConfiguration` found neither an AppRole pair nor a token. |
| `secrets.vault.login_failed` | Vault answered the AppRole login without a client token. |
| `secrets.fetch.not_found` | Vault answered `404`: it holds nothing at the path. |
| `secrets.fetch.failed` | Vault could not be reached, answered any other status `>= 300` (parameters `provider`, `path`, `status`), or answered a read without `data`. |

The framework adds its own around them — `secrets.field.required`,
`secrets.field.missing`, `secrets.provider.unknown`,
`secrets.reference.malformed` and `secrets.reference.unresolved`; see
`tom_core_server/doc/configuration.md`.

## Not Yet Implemented

- **Leases are not renewed.** A dynamic secret is read like a static one;
  renewing or revoking its lease is left to Vault and to its TTLs, and the
  refresh reads the path again.
- **No response wrapping.** A secret id delivered wrapped has to be unwrapped
  before it reaches `secretId`.

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/vault_secrets_provider_test.dart` | `fromConfiguration`'s settings, environment fallbacks, AppRole preference and refusals; the token and namespace headers on `/v1/<path>`; a refused AppRole token replaced by one new login; an unreachable Vault failing by key without the secret. Runs against `MockClient`. |
| `test/example_test.dart` | Runs `example/vault_secrets_example.dart` and requires exit 0. |
| `test/vault_emulator_test.dart` | Tagged `emulator`. Against a real Vault: a KV version 2 field with its version, references resolved through `TomSecrets`, a rotation reaching a watcher, a KV version 1 entry, `not_found` for an absent path, an AppRole login reading what its policy allows and refused what it does not, and a wrong secret id unable to log in. Skips itself when no Vault answers. |

```bash
dart test                         # unit suite + example; emulator tests skip
./tool/run_vault_emulator_tests.sh      # the emulator suite against a Vault container
```

`tool/run_vault_emulator_tests.sh` starts `hashicorp/vault:1.17` as a dev server on
`127.0.0.1:18200` (`VAULT_TEST_PORT` overrides the port) with the root token
`root`, waits for `/v1/sys/health`, runs `dart test --tags emulator` with
`VAULT_TEST_ADDR` pointing at it, and removes the container. A run in which
every emulator test skipped is reported as a failure, because it means Vault
never answered. It needs Docker.

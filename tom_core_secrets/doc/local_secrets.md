# Tom Secrets Manager secrets

`TomLocalSecretsProvider` answers every configuration reference that names the
`local` provider, by asking the Tom Secrets Manager's secrets service on the
same machine. This page covers that side: how a reference names a secret of the
Tom Secrets Manager, how the provider is configured and finds the service, how
approvals, versions and rotation work, and its error keys. How references work
in general — where they may appear, their precedence, the boot order and the
refresh cycle — is in
[`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#secret-references).

## Table of Contents

- [The reference](#the-reference)
- [Registering the provider](#registering-the-provider)
- [Configuration](#configuration)
- [Finding the service](#finding-the-service)
- [Approvals](#approvals)
- [Versions and rotation](#versions-and-rotation)
- [Error keys](#error-keys)
- [Verification](#verification)

## The reference

```text
secret:local:<tsm reference>[#<field>]
```

`<tsm reference>` is a reference in the Tom Secrets Manager's own grammar, as
`tsm get` takes it:

| Reference | Names |
| --------- | ----- |
| `secret:local:telegram.bot_token` | the entry whose `tsm.key` is `telegram.bot_token`, field `Password` |
| `secret:local:fleet/Cloud/AWS/root#UserName` | the entry `root` in group `Cloud/AWS` of the store `fleet`, field `UserName` |
| `secret:local:[env:prod]db.main` | the key `db.main` with the dimension `env` bound to `prod` |
| `secret:local:fleet/~0f3c2a1b4d5e6f708192a3b4c5d6e7f8#totp` | an entry by its UUID, which survives renames and moves |

`TomSecretReference.parse` splits the provider from the path at the **first**
colon, so the colons inside the brackets stay in the path, and takes the field
after the **last** `#`. The provider joins path and field again — the tsm
reference `[env:prod]db.main#UserName` — and sends it to the service, which
reads exactly that field. Without a field the service reads `Password`. A
reserved character inside a name is percent-encoded as tsm writes it
(`fleet/Mail/a%2Fb%23c`).

## Registering the provider

```dart
import 'package:tom_core_secrets/local.dart';
import 'package:tom_core_server/tom_core_server.dart';

Future<void> boot(List<String> args) async {
  TomSecrets.register(TomLocalSecretsProvider.fromConfiguration());
  await TomSecrets.load(TomBaseServerConfiguration.collectSources(args));
  TomSecrets.startRefresh(const Duration(minutes: 5));
}
```

A provider can be built directly as well, and registered the same way:

```dart
final provider = TomLocalSecretsProvider(
  clientName: 'billing-server',
  dimensions: {'env': 'prod'},
  timeout: const Duration(seconds: 30),
);
```

The constructor also takes `name` (default `local`), `wait` (default `true`),
`environment` (where the service is looked for) and a `client` of its own (a
`TomSecretsClient`). `close`, which `TomSecrets.reset` calls, closes the
connection; the next `fetch` opens a new one.

## Configuration

`fromConfiguration` reads the `secrets.local` key of the configuration
resources:

```yaml
secrets:
  local:
    clientName: billing-server
    dimensions:
      env: prod
    timeoutSeconds: 30
    waitForUnlock: true
```

| Setting | Type | Meaning |
| ------- | ---- | ------- |
| `clientName` | string | The name the approval prompt shows (default the executable's name). Shown beside the identity the service measures, never trusted. |
| `dimensions` | map of strings | Dimension values sent with every request beside the reference, for example the deployment's `env`. A reference that binds the same dimension to another value in its brackets is refused by the service (`secrets.fetch.failed`, kind `malformed`, reason `conflicting_dimension`). |
| `timeoutSeconds` | positive integer | How long a request may wait for an unlock or an approval, sent as `timeoutMs`; the service caps it. |
| `waitForUnlock` | bool | `true` (default): a request waits while the service is locked or the request awaits approval. `false`: it is answered at once, `locked` on a locked service. |

Every setting is optional; a setting of the wrong type is refused with
`secrets.local.config.malformed`, naming it. Like every provider's settings,
`secrets.local` is read as written: a reference inside it is not resolved.

## Finding the service

The provider uses `tom_secrets_client`, which finds the service in the runtime
directory of the user the server runs as:

| OS | Where |
| --- | --- |
| any | `TSM_RUNTIME_DIR` when set (containers, tests) |
| Linux | `$XDG_RUNTIME_DIR/tsm/`, else `/tmp/tsm-<uid>/` |
| macOS | `$TMPDIR/tsm/`, else `/tmp/tsm-<uid>/` |
| Windows | `%LOCALAPPDATA%\TomSecretsManager\run\` (a localhost port and a client token) |

`fromConfiguration(environment: ...)` and the constructor's `environment` take
the variables to look in; by default the process's. The connection is opened
by the first `fetch` and kept; after the service restarts, the next `fetch`
connects again.

## Approvals

The service decides whether a process may read a secret. The first request of
a server that has no grant goes to approval: the desktop app prompts, or on a
headless host the request waits with an approval code that `tsm approve` on a
trusted device answers. With `waitForUnlock: true` and a `timeoutSeconds`
long enough, the boot waits through it; once approved (and "always" chosen),
later starts are answered from the grant. A server whose boot must not wait
sets `waitForUnlock: false` and gets `secrets.fetch.failed` with the kind
`locked` or `denied` instead.

## Versions and rotation

Every value comes back with its version: the entry's last modification time
and the revision of the store file it was read from. The provider reports it as
the payload version, `"<modified, UTC ISO 8601> <revision>"`, and
`TomSecrets.versionOf(reference)` answers it. A secret changed in the vault —
on this machine or on another one, reaching this one by its next refresh —
reaches the server at the next `TomSecrets.refresh`, whose watchers are called
for the values that changed.

Each reference is fetched on its own (`TomSecretPayload.field`), because the
service answers one field per request: two fields of one entry are two
requests.

## Error keys

| Key | When |
| --- | ---- |
| `secrets.fetch.not_found` | The service holds no entry or field for the reference (kind `not_found`). |
| `secrets.fetch.failed` | Any other refusal or failure; the parameters name the `provider`, the tsm `reference`, the `kind` (`not_running`, `locked`, `denied`, `ambiguous`, `malformed`, `timeout`, `rate_limited`, ...) and the `reason` when the service gave one. |
| `secrets.local.binary_not_text` | The value is binary; a configuration value is text. |
| `secrets.local.config.malformed` | A `secrets.local` setting has the wrong type; `setting` names it. |

No message or parameter carries a value.

## Verification

`test/local/local_secrets_provider_test.dart` drives the provider against an
in-process stand-in for the secrets service (a Unix socket, or on Windows a
localhost port with its port and token files): the reference and field it
sends, the dimensions, `wait` and `timeoutMs`, configuration, refresh and
versions, and the error mapping. `test/local/example_test.dart` runs
[`example/local_secrets_example.dart`](../example/local_secrets_example.dart).
The service itself is tested in the Tom Secrets Manager's repositories.

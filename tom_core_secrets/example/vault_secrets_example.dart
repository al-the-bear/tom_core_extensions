/// Wiring HashiCorp Vault into a Tom server's configuration.
///
/// A real server builds the provider with
/// [TomVaultSecretsProvider.fromConfiguration], which reads `secrets.vault`
/// or `VAULT_ADDR` / `VAULT_TOKEN`. So that this example runs anywhere, a
/// stand-in answers Vault's KV version 2 API in-process; against a real Vault
/// drop the `httpClient` argument. `tool/run_vault_emulator_tests.sh` runs the same
/// flow against a Vault dev server.
///
/// Run with `dart run example/vault_secrets_example.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_core_secrets/vault.dart';
import 'package:tom_core_server/tom_core_server.dart';

void _check(bool ok, String expectation) {
  if (!ok) throw StateError('example check failed: $expectation');
}

Future<void> main() async {
  // The stand-in Vault: one KV v2 entry whose password rotates.
  var password = 'pw-1';
  var version = 1;
  final vault = MockClient((request) async {
    _check(request.headers['x-vault-token'] == 'dev-token', 'token sent');
    if (request.url.path != '/v1/secret/data/billing') {
      return http.Response('{"errors":[]}', 404);
    }
    return http.Response(
      jsonEncode({
        'data': {
          'data': {'password': password, 'user': 'billing'},
          'metadata': {'version': version},
        },
      }),
      200,
    );
  });

  // 1. Register the provider; it answers every `secret:vault:` reference.
  final provider = TomVaultSecretsProvider.fromConfiguration(
    config: TomServerConfigResourceProvider.from({
      'secrets': {
        'vault': {
          'address': 'http://vault.internal:8200',
          'token': 'dev-token',
        },
      },
    }),
  );
  TomSecrets.register(
    TomVaultSecretsProvider(
      address: provider.address,
      auth: provider.auth,
      httpClient: vault,
    ),
  );

  // 2. The configuration names the secret; the boot loads it before the
  //    configuration object is built.
  await TomSecrets.load({
    'dbPassword': 'secret:vault:secret/data/billing#password',
    'dbUser': 'secret:vault:secret/data/billing#user',
  });
  final current = TomSecrets.current(
    'secret:vault:secret/data/billing#password',
  );
  print('1. dbPassword resolved from Vault: $current');
  _check(current == 'pw-1', 'the KV v2 field is read');

  // 3. Vault rotates the secret; the next refresh reaches the watcher.
  TomSecrets.watch(
    'secret:vault:secret/data/billing#password',
    (value) => print('2. rotated password arrived: $value'),
  );
  password = 'pw-2';
  version = 2;
  final outcome = await TomSecrets.refresh();
  _check(outcome.changed.length == 1, 'one reference changed');

  await TomSecrets.reset();
}

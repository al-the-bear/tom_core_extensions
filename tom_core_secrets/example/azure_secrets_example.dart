/// Wiring Azure Key Vault into a Tom server's configuration.
///
/// A real server builds the provider with
/// [TomAzureKeyVaultSecretsProvider.fromConfiguration], which reads
/// `secrets.azure` or `AZURE_KEYVAULT_URL` and a service principal's
/// `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET`, or uses the
/// host's managed identity. So that this example runs anywhere, a stand-in
/// answers Entra ID's token endpoint and Key Vault's REST API in-process;
/// against Azure drop the `httpClient` argument. `tool/run_azure_emulator_tests.sh`
/// runs the same flow against Lowkey Vault.
///
/// Run with `dart run example/azure_secrets_example.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_core_secrets/azure.dart';
import 'package:tom_core_server/tom_core_server.dart';

void _check(bool ok, String expectation) {
  if (!ok) throw StateError('example check failed: $expectation');
}

Future<void> main() async {
  // The stand-in Azure: a token endpoint, and one JSON secret that rotates.
  var password = 'pw-1';
  var tokensIssued = 0;
  final azure = MockClient((request) async {
    if (request.url.host == 'login.microsoftonline.com') {
      tokensIssued++;
      return http.Response(
        jsonEncode({'access_token': 'aad-token', 'expires_in': 3600}),
        200,
      );
    }
    _check(
      request.headers['authorization'] == 'Bearer aad-token',
      'the Entra ID token is presented',
    );
    if (request.url.path != '/secrets/billing') {
      return http.Response('{"error":{"code":"SecretNotFound"}}', 404);
    }
    return http.Response(
      jsonEncode({
        'value': jsonEncode({'password': password, 'user': 'billing'}),
        'id': 'https://my-vault.vault.azure.net/secrets/billing/v-$password',
      }),
      200,
    );
  });

  // 1. Register the provider with a service principal; it answers every
  //    `secret:azure:` reference.
  TomSecrets.register(
    TomAzureKeyVaultSecretsProvider(
      vaultUri: Uri.parse('https://my-vault.vault.azure.net/'),
      credential: TomAzureClientSecretCredential(
        tenantId: 'my-tenant',
        clientId: 'my-app',
        clientSecret: 'example-secret',
      ),
      httpClient: azure,
    ),
  );

  // 2. The configuration names the secret and field.
  await TomSecrets.load({'dbPassword': 'secret:azure:billing#password'});
  final current = TomSecrets.current('secret:azure:billing#password');
  print('1. dbPassword resolved from Key Vault: $current');
  _check(current == 'pw-1', 'the JSON field is read');

  // 3. Key Vault gets a new version; the next refresh reaches the watcher,
  //    and the cached token is reused rather than fetched again.
  TomSecrets.watch(
    'secret:azure:billing#password',
    (value) => print('2. rotated password arrived: $value'),
  );
  password = 'pw-2';
  final outcome = await TomSecrets.refresh();
  _check(outcome.changed.length == 1, 'one reference changed');
  _check(tokensIssued == 1, 'one token served both reads');

  await TomSecrets.reset();
}

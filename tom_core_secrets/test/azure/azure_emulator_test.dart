/// The provider against Lowkey Vault, an Azure Key Vault emulator, started by
/// `tool/run_azure_emulator_tests.sh`. Skips itself when nothing answers at
/// `AZURE_TEST_VAULT` (default `https://localhost:18443/`).
///
/// Lowkey serves a self-signed certificate, so the client here accepts it; a
/// production provider is built with the default client and verifies.
@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:test/test.dart';
import 'package:tom_core_secrets/azure.dart';
import 'package:tom_core_server/tom_core_server.dart';

final _vault = Uri.parse(
  Platform.environment['AZURE_TEST_VAULT'] ?? 'https://localhost:18443/',
);
final _identity = Uri.parse(
  Platform.environment['AZURE_TEST_IDENTITY'] ??
      'http://localhost:18080/metadata/identity/oauth2/token',
);

http.Client _client() =>
    IOClient(HttpClient()..badCertificateCallback = (_, _, _) => true);

TomAzureKeyVaultSecretsProvider _provider({TomAzureCredential? credential}) =>
    TomAzureKeyVaultSecretsProvider(
      vaultUri: _vault,
      credential:
          credential ?? TomAzureManagedIdentityCredential(endpoint: _identity),
      httpClient: _client(),
    );

Future<bool> _reachable() async {
  final client = _client();
  try {
    final response = await client
        .get(_vault.resolve('secrets/none?api-version=7.4'))
        .timeout(const Duration(seconds: 3));
    return response.statusCode == 401;
  } on Object {
    return false;
  } finally {
    client.close();
  }
}

Matcher _refused(String key) =>
    throwsA(isA<TomSecretsException>().having((e) => e.key, 'key', key));

void main() async {
  final reachable = await _reachable();
  final skip = reachable
      ? null
      : 'No Lowkey Vault at $_vault — run tool/run_azure_emulator_tests.sh';
  final admin = _provider();
  late String firstVersion;

  Future<String> set(String name, String value) async {
    final body = await admin.call(
      'PUT',
      'secrets/$name',
      body: {'value': value},
    );
    final id = body['id'] as String;
    return id.substring(id.lastIndexOf('/') + 1);
  }

  setUpAll(() async {
    if (!reachable) return;
    firstVersion = await set(
      'billing',
      jsonEncode({'password': 'pw-1', 'user': 'billing'}),
    );
    await set('api-token', 'plain-token');
  });

  tearDown(TomSecrets.reset);

  test('reads a plain secret with a managed-identity token', () async {
    final payload = await _provider().fetch('api-token');
    expect(payload.data, 'plain-token');
    expect(payload.version, isNotEmpty);
  }, skip: skip);

  test('reads fields of a JSON secret through TomSecrets', () async {
    TomSecrets.register(_provider());
    await TomSecrets.load({
      'dbPassword': 'secret:azure:billing#password',
      'dbUser': 'secret:azure:billing#user',
    });
    expect(TomSecrets.current('secret:azure:billing#password'), 'pw-1');
    expect(TomSecrets.current('secret:azure:billing#user'), 'billing');
  }, skip: skip);

  test('a rotated secret reaches the watcher; a pinned version does not '
      'move', () async {
    TomSecrets.register(_provider());
    await TomSecrets.load({
      'current': 'secret:azure:billing#password',
      'pinned': 'secret:azure:billing/$firstVersion#password',
    });
    final seen = <String>[];
    TomSecrets.watch('secret:azure:billing#password', seen.add);
    await set('billing', jsonEncode({'password': 'pw-2', 'user': 'billing'}));
    final outcome = await TomSecrets.refresh();
    expect(outcome.changed, ['secret:azure:billing#password']);
    expect(seen, ['pw-2']);
    expect(
      TomSecrets.current('secret:azure:billing/$firstVersion#password'),
      'pw-1',
    );
  }, skip: skip);

  test('a secret the vault does not hold is not_found', () {
    expect(
      _provider().fetch('does-not-exist'),
      _refused('secrets.fetch.not_found'),
    );
  }, skip: skip);

  test('a request without a usable token is refused', () {
    // Lowkey accepts any bearer token, so the refusal tested is the token
    // endpoint's: a managed identity that is not there fails the fetch.
    final provider = _provider(
      credential: TomAzureManagedIdentityCredential(
        endpoint: _identity.resolve('/no-such-endpoint'),
      ),
    );
    expect(provider.fetch('api-token'), _refused('secrets.azure.token_failed'));
  }, skip: skip);
}

/// The Azure Key Vault key-encryption key against Lowkey Vault, an Azure Key
/// Vault emulator, started by `tool/run_azure_emulator_tests.sh`. Skips itself
/// when nothing answers at `AZURE_TEST_VAULT` (default
/// `https://localhost:18443/`).
///
/// Lowkey serves a self-signed certificate, so the client here accepts it; a
/// production provider is built with the default client and verifies.
@Tags(['emulator'])
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:test/test.dart';
import 'package:tom_core_secrets/azure.dart';
import 'package:tom_core_server/tom_core_server.dart';

import '../support/key_encryption_key_contract.dart';

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

void main() async {
  final reachable = await _reachable();
  final skip = reachable
      ? null
      : 'No Lowkey Vault at $_vault — run tool/run_azure_emulator_tests.sh';
  final admin = _provider();

  setUpAll(() async {
    if (!reachable) return;
    await admin.call(
      'POST',
      'keys/field-keys/create',
      body: {
        'kty': 'RSA',
        'key_size': 2048,
        // Key Vault needs only wrapKey and unwrapKey; Lowkey Vault implements
        // wrapping through its encrypt operation and refuses without it.
        'key_ops': ['wrapKey', 'unwrapKey', 'encrypt', 'decrypt'],
      },
    );
  });

  runKeyEncryptionKeyContract(
    'TomAzureKeyVaultKeyEncryptionKey',
    'AKV',
    (id) async => TomAzureKeyVaultKeyEncryptionKey(
      id: id,
      provider: _provider(),
      keyName: 'field-keys',
    ),
    skip: skip,
  );

  test('AKV-4: a key the vault does not hold is refused '
      '(secrets.kek.failed)', () {
    expect(
      TomAzureKeyVaultKeyEncryptionKey(
        id: 'k',
        provider: _provider(),
        keyName: 'no-such-key',
      ).wrap(List.filled(32, 1), keyId: 'd'),
      throwsA(
        isA<TomSecretsException>().having(
          (e) => e.key,
          'key',
          'secrets.kek.failed',
        ),
      ),
    );
  }, skip: skip);
}

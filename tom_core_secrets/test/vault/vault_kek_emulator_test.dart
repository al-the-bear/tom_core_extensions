/// The Vault Transit key-encryption key against a Vault dev server, started by
/// `tool/run_vault_emulator_tests.sh`. Skips itself when no Vault answers at
/// `VAULT_TEST_ADDR` (default `http://127.0.0.1:18200`, root token `root`).
@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tom_core_secrets/vault.dart';

import '../support/key_encryption_key_contract.dart';

final _address = Uri.parse(
  Platform.environment['VAULT_TEST_ADDR'] ?? 'http://127.0.0.1:18200',
);

/// Calls Vault as root — the test's own administration; answers the status.
Future<int> _admin(String method, String path, [Object? body]) async {
  final request = http.Request(method, _address.resolve('/v1/$path'))
    ..headers['x-vault-token'] = 'root';
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode(body);
  }
  return (await request.send()).statusCode;
}

Future<bool> _reachable() async {
  try {
    final response = await http
        .get(_address.resolve('/v1/sys/health'))
        .timeout(const Duration(seconds: 2));
    return response.statusCode == 200;
  } on Object {
    return false;
  }
}

void main() async {
  final reachable = await _reachable();
  final skip = reachable
      ? null
      : 'No Vault at $_address — run tool/run_vault_emulator_tests.sh';

  setUpAll(() async {
    if (!reachable) return;
    // The dev server mounts no Transit engine; a second run finds it mounted.
    await _admin('POST', 'sys/mounts/transit', {'type': 'transit'});
    await _admin('POST', 'transit/keys/field-keys', {'type': 'aes256-gcm96'});
  });

  TomVaultSecretsProvider provider() => TomVaultSecretsProvider(
    address: _address,
    auth: TomVaultTokenAuth('root'),
  );

  runKeyEncryptionKeyContract(
    'TomVaultTransitKeyEncryptionKey',
    'VT',
    (id) async => TomVaultTransitKeyEncryptionKey(
      id: id,
      provider: provider(),
      keyName: 'field-keys',
    ),
    skip: skip,
  );
}

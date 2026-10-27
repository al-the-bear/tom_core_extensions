/// The provider against a real Vault: a dev server in a container, started by
/// `tool/run_vault_emulator_tests.sh`. Skips itself when no Vault answers at
/// `VAULT_TEST_ADDR` (default `http://127.0.0.1:18200`, root token `root`).
@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tom_core_secrets/vault.dart';
import 'package:tom_core_server/tom_core_server.dart';

final _address = Uri.parse(
  Platform.environment['VAULT_TEST_ADDR'] ?? 'http://127.0.0.1:18200',
);

/// Calls Vault as root — the test's own administration, not the provider.
Future<Map<String, Object?>> _admin(
  String method,
  String path, [
  Object? body,
]) async {
  final request = http.Request(method, _address.resolve('/v1/$path'))
    ..headers['x-vault-token'] = 'root';
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode(body);
  }
  final response = await http.Response.fromStream(await request.send());
  if (response.statusCode >= 300) {
    throw StateError('$method $path: ${response.statusCode} ${response.body}');
  }
  return response.body.isEmpty
      ? const {}
      : (jsonDecode(response.body) as Map).cast<String, Object?>();
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
    await _admin('POST', 'secret/data/billing', {
      'data': {'jwt': 'jwt-1', 'db': 'db-1'},
    });
  });

  tearDown(TomSecrets.reset);

  group('with a token', () {
    TomVaultSecretsProvider provider() => TomVaultSecretsProvider(
      address: _address,
      auth: TomVaultTokenAuth('root'),
    );

    test('reads a field of a KV version 2 entry, with its version', () async {
      final payload = await provider().fetch('secret/data/billing');
      expect((payload.data as Map)['jwt'], isNotEmpty);
      expect(payload.version, isNotNull);
    });

    test('resolves configuration references through TomSecrets', () async {
      TomSecrets.register(provider());
      await TomSecrets.load({
        'jwtSharedSecretKey': 'secret:vault:secret/data/billing#jwt',
        'nested': {'db': 'secret:vault:secret/data/billing#db'},
      });
      expect(
        TomSecrets.substitute({'k': 'secret:vault:secret/data/billing#db'}),
        {'k': startsWith('db-')},
      );
    });

    test('a rotated secret reaches the watcher on refresh', () async {
      TomSecrets.register(provider());
      await _admin('POST', 'secret/data/rotating', {
        'data': {'password': 'first'},
      });
      await TomSecrets.load({
        'p': 'secret:vault:secret/data/rotating#password',
      });
      final seen = <String>[];
      TomSecrets.watch('secret:vault:secret/data/rotating#password', seen.add);
      await _admin('POST', 'secret/data/rotating', {
        'data': {'password': 'second'},
      });
      final outcome = await TomSecrets.refresh();
      expect(outcome.changed, ['secret:vault:secret/data/rotating#password']);
      expect(seen, ['second']);
    });

    test('reads a KV version 1 entry', () async {
      await _admin('POST', 'sys/mounts/kv1', {
        'type': 'kv',
        'options': {'version': '1'},
      }).catchError((_) => <String, Object?>{});
      await _admin('POST', 'kv1/app', {'password': 'v1-secret'});
      final payload = await provider().fetch('kv1/app');
      expect(
        payload.valueOf(
          const TomSecretReference('vault', 'kv1/app', 'password'),
        ),
        'v1-secret',
      );
    });

    test('a path Vault does not hold is not_found', () {
      expect(
        provider().fetch('secret/data/does-not-exist'),
        throwsA(
          isA<TomSecretsException>().having(
            (e) => e.key,
            'key',
            'secrets.fetch.not_found',
          ),
        ),
      );
    });
  }, skip: skip);

  group('with AppRole', () {
    late String roleId;
    late String secretId;

    setUpAll(() async {
      if (!reachable) return;
      await _admin('POST', 'sys/auth/approle', {
        'type': 'approle',
      }).catchError((_) => <String, Object?>{});
      await _admin('PUT', 'sys/policies/acl/read-billing', {
        'policy': 'path "secret/data/billing" { capabilities = ["read"] }',
      });
      await _admin('POST', 'auth/approle/role/billing', {
        'token_policies': ['read-billing'],
        'token_ttl': '1h',
      });
      roleId =
          ((await _admin('GET', 'auth/approle/role/billing/role-id'))['data']
                  as Map)['role_id']
              as String;
      secretId =
          ((await _admin('POST', 'auth/approle/role/billing/secret-id'))['data']
                  as Map)['secret_id']
              as String;
    });

    test('logs in and reads what its policy allows', () async {
      final provider = TomVaultSecretsProvider(
        address: _address,
        auth: TomVaultAppRoleAuth(roleId: roleId, secretId: secretId),
      );
      final payload = await provider.fetch('secret/data/billing');
      expect((payload.data as Map).keys, containsAll(['jwt', 'db']));
    });

    test('and is refused what its policy does not', () {
      final provider = TomVaultSecretsProvider(
        address: _address,
        auth: TomVaultAppRoleAuth(roleId: roleId, secretId: secretId),
      );
      expect(
        provider.fetch('secret/data/rotating'),
        throwsA(
          isA<TomSecretsException>().having(
            (e) => e.key,
            'key',
            'secrets.fetch.failed',
          ),
        ),
      );
    });

    test('a wrong secret id cannot log in', () {
      final provider = TomVaultSecretsProvider(
        address: _address,
        auth: TomVaultAppRoleAuth(roleId: roleId, secretId: 'wrong'),
      );
      expect(
        provider.fetch('secret/data/billing'),
        throwsA(isA<TomSecretsException>()),
      );
    });
  }, skip: skip);
}

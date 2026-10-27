/// The Vault provider without a server: configuration, the request it sends,
/// the responses it understands, and the re-login after a refused token.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_core_secrets/vault.dart';
import 'package:tom_core_server/tom_core_server.dart';

Matcher _refused(String key) =>
    throwsA(isA<TomSecretsException>().having((e) => e.key, 'key', key));

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  group('fromConfiguration', () {
    TomServerConfigResourceProvider config(Map<String, Object?> vault) =>
        TomServerConfigResourceProvider.from({
          'secrets': {'vault': vault},
        });

    test('reads address, token and namespace', () {
      final provider = TomVaultSecretsProvider.fromConfiguration(
        config: config({
          'address': 'https://vault.example:8200',
          'token': 't',
          'namespace': 'team-a',
        }),
      );
      expect(provider.address, Uri.parse('https://vault.example:8200'));
      expect(provider.auth, isA<TomVaultTokenAuth>());
      expect(provider.namespace, 'team-a');
    });

    test("falls back to Vault's environment variables", () {
      final provider = TomVaultSecretsProvider.fromConfiguration(
        config: TomServerConfigResourceProvider.from({}),
        environment: {'VAULT_ADDR': 'http://v:8200', 'VAULT_TOKEN': 't'},
      );
      expect(provider.address.host, 'v');
    });

    test('prefers AppRole when a role and secret id are given', () {
      final provider = TomVaultSecretsProvider.fromConfiguration(
        config: config({'address': 'http://v', 'roleId': 'r', 'secretId': 's'}),
      );
      expect(provider.auth, isA<TomVaultAppRoleAuth>());
    });

    test('refuses a missing address or missing credentials by name', () {
      expect(
        () => TomVaultSecretsProvider.fromConfiguration(config: config({})),
        _refused('secrets.vault.config.missing_address'),
      );
      expect(
        () => TomVaultSecretsProvider.fromConfiguration(
          config: config({'address': 'http://v'}),
        ),
        _refused('secrets.vault.config.missing_credentials'),
      );
    });
  });

  test('sends the token and namespace to /v1/<path>', () async {
    late http.Request seen;
    final provider = TomVaultSecretsProvider(
      address: Uri.parse('http://vault:8200/prefix/'),
      auth: TomVaultTokenAuth('tok'),
      namespace: 'team-a',
      httpClient: MockClient((request) async {
        seen = request;
        return _json({
          'data': {'password': 'p'},
        });
      }),
    );
    final payload = await provider.fetch('kv/app');
    expect(seen.url.path, '/prefix/v1/kv/app');
    expect(seen.headers['x-vault-token'], 'tok');
    expect(seen.headers['x-vault-namespace'], 'team-a');
    expect(payload.data, {'password': 'p'});
  });

  test('a refused AppRole token is replaced by a new login, once', () async {
    var logins = 0;
    var reads = 0;
    final provider = TomVaultSecretsProvider(
      address: Uri.parse('http://vault'),
      auth: TomVaultAppRoleAuth(roleId: 'r', secretId: 's'),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          logins++;
          return _json({
            'auth': {'client_token': 'token-$logins', 'lease_duration': 3600},
          });
        }
        reads++;
        // The first token is refused, as an early-expired one would be.
        if (request.headers['x-vault-token'] == 'token-1') {
          return _json({
            'errors': ['permission denied'],
          }, 403);
        }
        return _json({
          'data': {
            'data': {'k': 'v'},
            'metadata': {'version': 3},
          },
        });
      }),
    );
    final payload = await provider.fetch('secret/data/x');
    expect(logins, 2);
    expect(reads, 2);
    expect(payload.version, '3');
  });

  test('an unreachable Vault fails by name, never with the secret', () {
    final provider = TomVaultSecretsProvider(
      address: Uri.parse('http://vault'),
      auth: TomVaultTokenAuth('tok'),
      httpClient: MockClient((_) async => throw http.ClientException('down')),
    );
    expect(provider.fetch('secret/data/x'), _refused('secrets.fetch.failed'));
  });

  test('an AppRole login answered without a token is refused by name', () {
    final provider = TomVaultSecretsProvider(
      address: Uri.parse('http://vault:8200'),
      auth: TomVaultAppRoleAuth(roleId: 'r', secretId: 's'),
      httpClient: MockClient(
        (_) async => http.Response(jsonEncode({'auth': null}), 200),
      ),
    );
    expect(
      provider.fetch('secret/data/app'),
      throwsA(
        isA<TomSecretsException>().having(
          (e) => e.key,
          'key',
          'secrets.vault.login_failed',
        ),
      ),
    );
  });
}

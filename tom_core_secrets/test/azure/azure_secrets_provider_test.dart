/// The Azure provider without a vault: configuration, credentials, and the
/// answers it maps.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_core_secrets/azure.dart';
import 'package:tom_core_server/tom_core_server.dart';

Matcher _refused(String key) =>
    throwsA(isA<TomSecretsException>().having((e) => e.key, 'key', key));

final _vault = Uri.parse('https://my-vault.vault.azure.net/');

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('fromConfiguration', () {
    test('a service principal from the configuration', () {
      final provider = TomAzureKeyVaultSecretsProvider.fromConfiguration(
        config: TomServerConfigResourceProvider.from({
          'secrets': {
            'azure': {
              'vaultUri': 'https://my-vault.vault.azure.net/',
              'tenantId': 't',
              'clientId': 'c',
              'clientSecret': 's',
            },
          },
        }),
      );
      expect(provider.vaultUri, _vault);
      expect(provider.credential, isA<TomAzureClientSecretCredential>());
    });

    test('the Azure variables, and a managed identity on request', () {
      final principal = TomAzureKeyVaultSecretsProvider.fromConfiguration(
        config: TomServerConfigResourceProvider.from({}),
        environment: {
          'AZURE_KEYVAULT_URL': 'https://my-vault.vault.azure.net/',
          'AZURE_TENANT_ID': 't',
          'AZURE_CLIENT_ID': 'c',
          'AZURE_CLIENT_SECRET': 's',
        },
      );
      expect(principal.credential, isA<TomAzureClientSecretCredential>());
      final identity = TomAzureKeyVaultSecretsProvider.fromConfiguration(
        config: TomServerConfigResourceProvider.from({
          'secrets': {
            'azure': {'vaultUri': '$_vault', 'managedIdentity': true},
          },
        }),
      );
      expect(identity.credential, isA<TomAzureManagedIdentityCredential>());
    });

    test('a missing vault or credential is refused by name', () {
      expect(
        () => TomAzureKeyVaultSecretsProvider.fromConfiguration(
          config: TomServerConfigResourceProvider.from({}),
        ),
        _refused('secrets.azure.config.missing_vault'),
      );
      expect(
        () => TomAzureKeyVaultSecretsProvider.fromConfiguration(
          config: TomServerConfigResourceProvider.from({}),
          environment: {'AZURE_KEYVAULT_URL': '$_vault'},
        ),
        _refused('secrets.azure.config.missing_credentials'),
      );
    });
  });

  group('fetch', () {
    test(
      'reads the value and the version from the id, with a bearer',
      () async {
        late http.Request seen;
        final provider = TomAzureKeyVaultSecretsProvider(
          vaultUri: _vault,
          credential: TomAzureStaticTokenCredential('tok'),
          httpClient: MockClient((request) async {
            seen = request;
            return _json({
              'value': '{"password":"pw"}',
              'id': '${_vault}secrets/db/abc123',
            });
          }),
        );
        final payload = await provider.fetch('db');
        expect(seen.url.path, '/secrets/db');
        expect(seen.url.queryParameters['api-version'], '7.4');
        expect(seen.headers['authorization'], 'Bearer tok');
        expect(payload.version, 'abc123');
        expect(
          payload.valueOf(const TomSecretReference('azure', 'db', 'password')),
          'pw',
        );
      },
    );

    test('a 404 is not_found; another failure is failed', () async {
      for (final (status, key) in [
        (404, 'secrets.fetch.not_found'),
        (500, 'secrets.fetch.failed'),
      ]) {
        final provider = TomAzureKeyVaultSecretsProvider(
          vaultUri: _vault,
          credential: TomAzureStaticTokenCredential('tok'),
          httpClient: MockClient((_) async => _json({}, status)),
        );
        await expectLater(provider.fetch('db'), _refused(key));
      }
    });

    test('a 401 drops the token and retries once with a fresh one', () async {
      var tokens = 0;
      final tokensSeen = <String?>[];
      final provider = TomAzureKeyVaultSecretsProvider(
        vaultUri: _vault,
        credential: TomAzureClientSecretCredential(
          tenantId: 't',
          clientId: 'c',
          clientSecret: 's',
        ),
        httpClient: MockClient((request) async {
          if (request.url.host == 'login.microsoftonline.com') {
            expect(request.url.path, '/t/oauth2/v2.0/token');
            expect(request.bodyFields['scope'], tomAzureKeyVaultScope);
            expect(request.bodyFields['grant_type'], 'client_credentials');
            tokens++;
            return _json({'access_token': 'tok-$tokens', 'expires_in': 3600});
          }
          tokensSeen.add(request.headers['authorization']);
          return tokensSeen.length == 1
              ? _json({}, 401)
              : _json({'value': 'v', 'id': '${_vault}secrets/db/1'});
        }),
      );
      expect((await provider.fetch('db')).data, 'v');
      expect(tokensSeen, ['Bearer tok-1', 'Bearer tok-2']);
    });
  });

  group('credentials', () {
    test('a token is reused until shortly before it expires', () async {
      var now = DateTime.utc(2026);
      var fetched = 0;
      final credential = TomAzureClientSecretCredential(
        tenantId: 't',
        clientId: 'c',
        clientSecret: 's',
        clock: () => now,
      );
      final client = MockClient((_) async {
        fetched++;
        return _json({'access_token': 'tok-$fetched', 'expires_in': 3600});
      });
      expect(await credential.token(client), 'tok-1');
      now = now.add(const Duration(minutes: 50));
      expect(await credential.token(client), 'tok-1');
      now = now.add(const Duration(minutes: 6));
      expect(await credential.token(client), 'tok-2');
    });

    test('a managed identity asks the instance metadata endpoint, or App '
        "Service's", () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return _json({'access_token': 'mi', 'expires_on': '9999999999'});
      });
      await TomAzureManagedIdentityCredential(clientId: 'uai').token(client);
      expect(seen.url.host, '169.254.169.254');
      expect(seen.headers['metadata'], 'true');
      expect(seen.url.queryParameters['resource'], tomAzureKeyVaultResource);
      expect(seen.url.queryParameters['client_id'], 'uai');
      await TomAzureManagedIdentityCredential(
        environment: {
          'IDENTITY_ENDPOINT': 'http://localhost:42356/msi/token',
          'IDENTITY_HEADER': 'h',
        },
      ).token(client);
      expect(seen.url.port, 42356);
      expect(seen.headers['x-identity-header'], 'h');
      expect(seen.url.queryParameters['api-version'], '2019-08-01');
    });

    test('a refused or unreachable token endpoint is token_failed', () async {
      final refused = MockClient((_) async => _json({}, 400));
      await expectLater(
        TomAzureManagedIdentityCredential().token(refused),
        _refused('secrets.azure.token_failed'),
      );
      final down = MockClient((_) async => throw const FormatException('x'));
      await expectLater(
        TomAzureManagedIdentityCredential().token(down),
        _refused('secrets.azure.token_failed'),
      );
    });
  });
}

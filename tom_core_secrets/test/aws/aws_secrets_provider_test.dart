/// The AWS provider without a service: configuration, the signed request, and
/// the answers it maps.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_core_secrets/aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

Matcher _refused(String key) =>
    throwsA(isA<TomSecretsException>().having((e) => e.key, 'key', key));

TomAwsSecretsProvider _provider(MockClient client) => TomAwsSecretsProvider(
  region: 'eu-west-1',
  credentials: () async => const TomAwsCredentials(
    accessKeyId: 'AKIDEXAMPLE',
    secretAccessKey: 'secret',
    sessionToken: 'session',
  ),
  httpClient: client,
  clock: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
);

void main() {
  group('fromConfiguration', () {
    test('reads region and keys from the configuration', () {
      final provider = TomAwsSecretsProvider.fromConfiguration(
        config: TomServerConfigResourceProvider.from({
          'secrets': {
            'aws': {
              'region': 'eu-central-1',
              'accessKeyId': 'a',
              'secretAccessKey': 's',
              'endpoint': 'http://localhost:4566',
            },
          },
        }),
      );
      expect(provider.region, 'eu-central-1');
      expect(provider.endpoint.port, 4566);
    });

    test('falls back to the AWS environment variables', () {
      final provider = TomAwsSecretsProvider.fromConfiguration(
        config: TomServerConfigResourceProvider.from({}),
        environment: {
          'AWS_DEFAULT_REGION': 'us-west-2',
          'AWS_ACCESS_KEY_ID': 'a',
          'AWS_SECRET_ACCESS_KEY': 's',
        },
      );
      expect(
        provider.endpoint,
        Uri.parse('https://secretsmanager.us-west-2.amazonaws.com/'),
      );
    });

    test('refuses a missing region or missing keys by name', () {
      expect(
        () => TomAwsSecretsProvider.fromConfiguration(
          config: TomServerConfigResourceProvider.from({}),
          environment: const {},
        ),
        _refused('secrets.aws.config.missing_region'),
      );
      expect(
        () => TomAwsSecretsProvider.fromConfiguration(
          config: TomServerConfigResourceProvider.from({}),
          environment: {'AWS_REGION': 'eu-west-1'},
        ),
        _refused('secrets.aws.config.missing_credentials'),
      );
    });
  });

  test('sends a SigV4-signed GetSecretValue for the secret id', () async {
    late http.Request seen;
    final provider = _provider(
      MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({'SecretString': 's', 'VersionId': 'v1'}),
          200,
        );
      }),
    );
    final payload = await provider.fetch('prod/app');
    expect(seen.method, 'POST');
    expect(seen.headers['x-amz-target'], 'secretsmanager.GetSecretValue');
    expect(jsonDecode(seen.body), {'SecretId': 'prod/app'});
    expect(
      seen.headers['authorization'],
      startsWith(
        'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260102/eu-west-1/'
        'secretsmanager/aws4_request',
      ),
    );
    expect(seen.headers['x-amz-security-token'], 'session');
    expect(seen.headers.containsKey('host'), isFalse);
    expect(payload.version, 'v1');
  });

  test('maps ResourceNotFoundException to not_found, others to failed', () {
    TomAwsSecretsProvider answering(int status, String type) => _provider(
      MockClient(
        (_) async => http.Response(jsonEncode({'__type': type}), status),
      ),
    );
    expect(
      answering(400, 'ResourceNotFoundException').fetch('x'),
      _refused('secrets.fetch.not_found'),
    );
    expect(
      answering(400, 'AccessDeniedException').fetch('x'),
      _refused('secrets.fetch.failed'),
    );
  });

  test('a binary secret that is not text is refused by name', () {
    final provider = _provider(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'SecretBinary': base64.encode([0xff, 0xfe, 0x00]),
          }),
          200,
        ),
      ),
    );
    expect(provider.fetch('x'), _refused('secrets.aws.binary_not_text'));
  });
}

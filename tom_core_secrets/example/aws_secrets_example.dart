/// Wiring AWS Secrets Manager into a Tom server's configuration.
///
/// A real server builds the provider with
/// [TomAwsSecretsProvider.fromConfiguration], which reads `secrets.aws` or the
/// standard `AWS_*` variables; on an instance or task role it passes a
/// credentials source that returns the role's temporary credentials. So that
/// this example runs anywhere, a stand-in answers `GetSecretValue`
/// in-process; against AWS drop the `httpClient` argument.
/// `tool/run_aws_emulator_tests.sh` runs the same flow against LocalStack.
///
/// Run with `dart run example/aws_secrets_example.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_core_secrets/aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

void _check(bool ok, String expectation) {
  if (!ok) throw StateError('example check failed: $expectation');
}

Future<void> main() async {
  // The stand-in Secrets Manager: one JSON secret whose password rotates.
  var password = 'pw-1';
  final secretsManager = MockClient((request) async {
    _check(
      request.headers['x-amz-target'] == 'secretsmanager.GetSecretValue',
      'the GetSecretValue action is called',
    );
    _check(
      request.headers['authorization']!.startsWith('AWS4-HMAC-SHA256'),
      'the request is signed with SigV4',
    );
    final secretId = (jsonDecode(request.body) as Map)['SecretId'];
    if (secretId != 'prod/billing') {
      return http.Response(
        '{"__type":"ResourceNotFoundException","message":"not found"}',
        400,
      );
    }
    return http.Response(
      jsonEncode({
        'SecretString': jsonEncode({'password': password, 'user': 'billing'}),
        'VersionId': 'v-$password',
      }),
      200,
    );
  });

  // 1. Register the provider; it answers every `secret:aws:` reference.
  TomSecrets.register(
    TomAwsSecretsProvider(
      region: 'eu-west-1',
      credentials: () async => const TomAwsCredentials(
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'example-secret',
      ),
      httpClient: secretsManager,
    ),
  );

  // 2. The configuration names the secret by name (or ARN) and field.
  await TomSecrets.load({'dbPassword': 'secret:aws:prod/billing#password'});
  final current = TomSecrets.current('secret:aws:prod/billing#password');
  print('1. dbPassword resolved from Secrets Manager: $current');
  _check(current == 'pw-1', 'the JSON field is read');

  // 3. Secrets Manager rotates the secret; the next refresh reaches the
  //    watcher.
  TomSecrets.watch(
    'secret:aws:prod/billing#password',
    (value) => print('2. rotated password arrived: $value'),
  );
  password = 'pw-2';
  final outcome = await TomSecrets.refresh();
  _check(outcome.changed.length == 1, 'one reference changed');

  await TomSecrets.reset();
}

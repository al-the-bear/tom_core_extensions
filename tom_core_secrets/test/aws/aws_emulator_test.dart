/// The provider against LocalStack's Secrets Manager, started by
/// `tool/run_aws_emulator_tests.sh`. Skips itself when nothing answers at
/// `AWS_TEST_ENDPOINT` (default `http://127.0.0.1:14566/`).
@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tom_core_secrets/aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

final _endpoint = Uri.parse(
  Platform.environment['AWS_TEST_ENDPOINT'] ?? 'http://127.0.0.1:14566/',
);

TomAwsSecretsProvider _provider() => TomAwsSecretsProvider(
  region: 'us-east-1',
  credentials: () async =>
      const TomAwsCredentials(accessKeyId: 'test', secretAccessKey: 'test'),
  endpoint: _endpoint,
);

Future<bool> _reachable() async {
  try {
    final response = await http
        .get(_endpoint.resolve('/_localstack/health'))
        .timeout(const Duration(seconds: 2));
    return response.statusCode == 200;
  } on Object {
    return false;
  }
}

/// An idempotency token, which every SDK adds to a write and the API demands.
String _token() {
  final random = Random();
  return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
}

void main() async {
  final reachable = await _reachable();
  final skip = reachable
      ? null
      : 'No LocalStack at $_endpoint — run tool/run_aws_emulator_tests.sh';
  final admin = _provider();

  setUpAll(() async {
    if (!reachable) return;
    await admin.call('CreateSecret', {
      'Name': 'prod/billing',
      'ClientRequestToken': _token(),
      'SecretString': jsonEncode({'password': 'pw-1', 'user': 'billing'}),
    });
    await admin.call('CreateSecret', {
      'Name': 'prod/token',
      'ClientRequestToken': _token(),
      'SecretString': 'plain-token',
    });
    await admin.call('CreateSecret', {
      'Name': 'prod/binary',
      'ClientRequestToken': _token(),
      'SecretBinary': base64.encode(utf8.encode('binary-text')),
    });
  });

  tearDown(TomSecrets.reset);

  test('reads a plain secret, with its version', () async {
    final payload = await _provider().fetch('prod/token');
    expect(payload.data, 'plain-token');
    expect(payload.version, isNotNull);
  }, skip: skip);

  test('reads a field of a JSON secret through TomSecrets', () async {
    TomSecrets.register(_provider());
    await TomSecrets.load({
      'dbPassword': 'secret:aws:prod/billing#password',
      'dbUser': 'secret:aws:prod/billing#user',
    });
    expect(TomSecrets.current('secret:aws:prod/billing#password'), 'pw-1');
    expect(TomSecrets.current('secret:aws:prod/billing#user'), 'billing');
  }, skip: skip);

  test('reads a binary secret that is text', () async {
    expect((await _provider().fetch('prod/binary')).data, 'binary-text');
  }, skip: skip);

  test('a rotated secret reaches the watcher on refresh', () async {
    TomSecrets.register(_provider());
    await TomSecrets.load({'p': 'secret:aws:prod/billing#password'});
    final seen = <String>[];
    TomSecrets.watch('secret:aws:prod/billing#password', seen.add);
    await admin.call('PutSecretValue', {
      'SecretId': 'prod/billing',
      'ClientRequestToken': _token(),
      'SecretString': jsonEncode({'password': 'pw-2', 'user': 'billing'}),
    });
    final outcome = await TomSecrets.refresh();
    expect(outcome.changed, ['secret:aws:prod/billing#password']);
    expect(seen, ['pw-2']);
  }, skip: skip);

  test('a secret Secrets Manager does not hold is not_found', () {
    expect(
      _provider().fetch('prod/does-not-exist'),
      throwsA(
        isA<TomSecretsException>().having(
          (e) => e.key,
          'key',
          'secrets.fetch.not_found',
        ),
      ),
    );
  }, skip: skip);
}

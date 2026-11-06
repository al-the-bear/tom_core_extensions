/// The AWS KMS key-encryption key against LocalStack's KMS, started by
/// `tool/run_aws_emulator_tests.sh`. Skips itself when nothing answers at
/// `AWS_TEST_ENDPOINT` (default `http://127.0.0.1:14566/`).
@Tags(['emulator'])
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tom_core_secrets/aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

import '../support/key_encryption_key_contract.dart';

final _endpoint = Uri.parse(
  Platform.environment['AWS_TEST_ENDPOINT'] ?? 'http://127.0.0.1:14566/',
);

TomAwsKmsKeyEncryptionKey _kek(String id, String kmsKeyId) =>
    TomAwsKmsKeyEncryptionKey(
      id: id,
      kmsKeyId: kmsKeyId,
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
    return response.statusCode == 200 && response.body.contains('"kms"');
  } on Object {
    return false;
  }
}

void main() async {
  final reachable = await _reachable();
  final skip = reachable
      ? null
      : 'No LocalStack KMS at $_endpoint — run tool/run_aws_emulator_tests.sh';
  late String kmsKeyId;

  setUpAll(() async {
    if (!reachable) return;
    // The test's own administration, through the same signed client.
    final created = await _kek('admin', 'none').call('CreateKey', {
      'Description': 'tom_core_secrets field-encryption test key',
    });
    kmsKeyId = (created['KeyMetadata']! as Map)['KeyId']! as String;
  });

  runKeyEncryptionKeyContract(
    'TomAwsKmsKeyEncryptionKey',
    'KMS',
    (id) async => _kek(id, kmsKeyId),
    skip: skip,
  );

  test(
    'KMS-4: a KMS key KMS does not hold is refused (secrets.kek.failed)',
    () {
      expect(
        _kek('k', 'alias/no-such-key').wrap(List.filled(32, 1), keyId: 'd'),
        throwsA(
          isA<TomSecretsException>().having(
            (e) => e.key,
            'key',
            'secrets.kek.failed',
          ),
        ),
      );
    },
    skip: skip,
  );
}

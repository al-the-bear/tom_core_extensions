/// The package example runs to the end against LocalStack: its checks
/// throw on a violated expectation, so exit code 0 is the verification.
///
/// `@Tags(['aws'])`: run by `tool/run_aws_tests.sh`.
@Tags(['aws'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final url = Platform.environment['TOM_AWS_TEST_ENDPOINT'];
  test(
    'example/aws_message_bus_example.dart runs green',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'example/aws_message_bus_example.dart'],
        environment: {'TOM_AWS_TEST_ENDPOINT': url!},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('2. dead-lettered: no printer'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: url == null ? 'TOM_AWS_TEST_ENDPOINT is not set' : null,
  );
}

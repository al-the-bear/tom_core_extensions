/// The package example runs to the end against a RabbitMQ broker: its checks
/// throw on a violated expectation, so exit code 0 is the verification.
///
/// `@Tags(['rabbitmq'])`: run by `tool/run_rabbitmq_tests.sh`.
@Tags(['rabbitmq'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final url = Platform.environment['TOM_RABBITMQ_TEST_URL'];
  test(
    'example/rabbitmq_message_bus_example.dart runs green',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'example/rabbitmq_message_bus_example.dart'],
        environment: {'TOM_RABBITMQ_TEST_URL': url!},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('2. dead-lettered: no printer'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: url == null ? 'TOM_RABBITMQ_TEST_URL is not set' : null,
  );
}

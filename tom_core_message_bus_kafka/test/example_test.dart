/// The package example runs to the end against a Kafka REST proxy: its checks
/// throw on a violated expectation, so exit code 0 is the verification.
///
/// `@Tags(['kafka'])`: run by `tool/run_kafka_tests.sh`.
@Tags(['kafka'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final url = Platform.environment['TOM_KAFKA_REST_TEST_URL'];
  test(
    'example/kafka_message_bus_example.dart runs green',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'example/kafka_message_bus_example.dart'],
        environment: {'TOM_KAFKA_REST_TEST_URL': url!},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('2. dead-lettered: no printer'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: url == null ? 'TOM_KAFKA_REST_TEST_URL is not set' : null,
  );
}

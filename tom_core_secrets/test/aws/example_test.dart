/// The package example runs to the end: its checks throw on a violated
/// expectation, so exit code 0 is the verification.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'example/aws_secrets_example.dart runs green',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'example/aws_secrets_example.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('2. rotated password arrived: pw-2'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

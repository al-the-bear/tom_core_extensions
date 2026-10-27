/// Every example runs green and prints every step it promises.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'example/tom_core_openapi_example.dart runs its four steps',
    () async {
      final run = await Process.run(Platform.resolvedExecutable, [
        'run',
        'example/tom_core_openapi_example.dart',
      ]);
      expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
      final steps = RegExp(
        r'^(\d+)\. ',
        multiLine: true,
      ).allMatches('${run.stdout}').map((m) => int.parse(m[1]!)).toList();
      expect(steps, [1, 2, 3, 4]);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

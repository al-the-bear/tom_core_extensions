/// The example runs green against the emulator.
@Tags(['azure'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final connection = Platform.environment['TOM_AZURE_SB_CONNECTION'];
  test(
    'example/azure_message_bus_example.dart runs green',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'example/azure_message_bus_example.dart'],
        environment: {
          'TOM_AZURE_SB_CONNECTION': connection!,
          for (final name in [
            'TOM_AZURE_SB_AMQP_PORT',
            'TOM_AZURE_SB_HTTP_PORT',
          ])
            name: ?Platform.environment[name],
        },
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('2. dead-lettered: no printer'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: connection == null ? 'TOM_AZURE_SB_CONNECTION is not set' : null,
  );
}

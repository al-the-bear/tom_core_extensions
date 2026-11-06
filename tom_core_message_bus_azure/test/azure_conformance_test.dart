/// The bus's conformance suite against the Azure Service Bus emulator, and the
/// server's bus relay publishing through it.
///
/// Tagged `azure`: `tool/run_azure_tests.sh` starts the emulator and sets
/// `TOM_AZURE_SB_CONNECTION` (with `TOM_AZURE_SB_AMQP_PORT` and
/// `TOM_AZURE_SB_HTTP_PORT`); without it the tests skip themselves.
@Tags(['azure'])
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_core_message_bus/conformance.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_azure/tom_core_message_bus_azure.dart';
import 'package:tom_core_server/tom_core_server.dart';

final String? _connection = Platform.environment['TOM_AZURE_SB_CONNECTION'];

TomServiceBusMessageBus emulatorBus({bool claimsBased = false}) =>
    TomServiceBusMessageBus.fromConnectionString(
      _connection!,
      claimsBased: claimsBased,
      amqpPort: int.tryParse(
        Platform.environment['TOM_AZURE_SB_AMQP_PORT'] ?? '',
      ),
      managementPort: int.tryParse(
        Platform.environment['TOM_AZURE_SB_HTTP_PORT'] ?? '',
      ),
    );

void main() {
  final skip = _connection == null
      ? 'TOM_AZURE_SB_CONNECTION is not set — run tool/run_azure_tests.sh'
      : null;

  group('TomServiceBusMessageBus conformance', () {
    tomMessageBusConformance(
      create: () async => emulatorBus(),
      timeout: const Duration(seconds: 30),
      quiet: const Duration(seconds: 2),
    );
  }, skip: skip);

  group('TomServiceBusMessageBus conformance, authorized through claims-based '
      'security', () {
    tomMessageBusConformance(
      create: () async => emulatorBus(claimsBased: true),
      timeout: const Duration(seconds: 30),
      quiet: const Duration(seconds: 2),
    );
  }, skip: skip);

  group('the bus relay through Service Bus', () {
    test('ZB-I1: a message queued on the relay reaches a Service Bus consumer '
        'once, under its id', () async {
      final bus = emulatorBus();
      addTearDown(bus.close);
      final relay = TomBusRelay(bus: bus);
      addTearDown(relay.close);
      final topic = 'relay-${Random().nextInt(1 << 32).toRadixString(16)}';
      final received = <TomBusDelivery<Object?>>[];
      await bus.subscribe<Object?>(
        topic,
        group: 'billing',
        handler: received.add,
      );

      final id = await relay.publish(topic, {'order': 'o-1'}, key: 'c-7');
      await relay.tick();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (received.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(received, hasLength(1));
      expect(received.single.message.id, id);
      expect(received.single.message.key, 'c-7');
      expect(received.single.payload, {'order': 'o-1'});
    });
  }, skip: skip);
}

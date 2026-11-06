/// The bus's conformance suite against the Pub/Sub emulator, and the
/// server's bus relay publishing through the adapter.
///
/// `@Tags(['gcp'])`, self-skipping unless `tool/run_gcp_tests.sh` started
/// the emulator and named it in `TOM_PUBSUB_TEST_ENDPOINT`.
@Tags(['gcp'])
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_core_message_bus/conformance.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_gcp/tom_core_message_bus_gcp.dart';
import 'package:tom_core_server/tom_core_server.dart';

final String? _endpoint = Platform.environment['TOM_PUBSUB_TEST_ENDPOINT'];

/// A bus on the emulator, which needs no token.
TomPubSubMessageBus emulatorBus() =>
    TomPubSubMessageBus(projectId: 'tom-test', endpoint: Uri.parse(_endpoint!));

void main() {
  final skip = _endpoint == null
      ? 'TOM_PUBSUB_TEST_ENDPOINT is not set — run tool/run_gcp_tests.sh'
      : null;

  group('TomPubSubMessageBus conformance', () {
    tomMessageBusConformance(
      create: () async => emulatorBus(),
      timeout: const Duration(seconds: 30),
      quiet: const Duration(seconds: 2),
    );
  }, skip: skip);

  group('the bus relay through Pub/Sub', () {
    test(
      'GB-I1: a message queued on the relay reaches a Pub/Sub consumer once, '
      'under its id',
      () async {
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
      },
    );
  }, skip: skip);
}

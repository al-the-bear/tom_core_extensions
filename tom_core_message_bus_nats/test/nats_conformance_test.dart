/// The bus's conformance suite against a NATS server with JetStream, and the
/// server's bus relay publishing through the adapter.
///
/// `@Tags(['nats'])`, self-skipping unless `tool/run_nats_tests.sh` started a
/// server and named it in `TOM_NATS_TEST_URL`.
@Tags(['nats'])
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_core_message_bus/conformance.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart';
import 'package:tom_core_server/tom_core_server.dart';

final String? _url = Platform.environment['TOM_NATS_TEST_URL'];

void main() {
  final skip = _url == null
      ? 'TOM_NATS_TEST_URL is not set — run tool/run_nats_tests.sh'
      : null;

  Future<TomNatsMessageBus> connect() =>
      TomNatsMessageBus.connect(Uri.parse(_url!));

  group('TomNatsMessageBus conformance', () {
    tomMessageBusConformance(
      create: connect,
      timeout: const Duration(seconds: 20),
      quiet: const Duration(seconds: 2),
    );
  }, skip: skip);

  group('the bus relay through NATS', () {
    test('NB-I1: a message queued on the relay reaches a NATS consumer once, '
        'under its id', () async {
      final bus = await connect();
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
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (received.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(received, hasLength(1));
      expect(received.single.message.id, id);
      expect(received.single.message.key, 'c-7');
      expect(received.single.payload, {'order': 'o-1'});
    });

    test('NB-I2: a publish the relay repeats is dropped by the server '
        '(Nats-Msg-Id)', () async {
      final bus = await connect();
      addTearDown(bus.close);
      final topic = 'dedupe-${Random().nextInt(1 << 32).toRadixString(16)}';
      final received = <String>[];
      await bus.subscribe<Object?>(
        topic,
        group: 'billing',
        handler: (d) => received.add(d.message.id),
      );
      await bus.publish(topic, {'n': 1}, id: 'm-1');
      await bus.publish(topic, {'n': 1}, id: 'm-1');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(received, ['m-1']);
    });
  }, skip: skip);
}

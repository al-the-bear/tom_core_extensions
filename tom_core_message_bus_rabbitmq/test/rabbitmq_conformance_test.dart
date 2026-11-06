/// The bus's conformance suite against a RabbitMQ broker, and the server's bus
/// relay publishing through the adapter.
///
/// `@Tags(['rabbitmq'])`, self-skipping unless `tool/run_rabbitmq_tests.sh`
/// started a broker and named it in `TOM_RABBITMQ_TEST_URL`.
@Tags(['rabbitmq'])
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_core_message_bus/conformance.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_rabbitmq/tom_core_message_bus_rabbitmq.dart';
import 'package:tom_core_server/tom_core_server.dart';

final String? _url = Platform.environment['TOM_RABBITMQ_TEST_URL'];

void main() {
  final skip = _url == null
      ? 'TOM_RABBITMQ_TEST_URL is not set — run tool/run_rabbitmq_tests.sh'
      : null;

  Future<TomRabbitMqMessageBus> connect() =>
      TomRabbitMqMessageBus.connect(Uri.parse(_url!));

  group('TomRabbitMqMessageBus conformance', () {
    tomMessageBusConformance(
      create: connect,
      timeout: const Duration(seconds: 20),
      quiet: const Duration(seconds: 1),
    );
  }, skip: skip);

  group('the bus relay through RabbitMQ', () {
    test('RB-I1: a message queued on the relay reaches a RabbitMQ consumer '
        'once, under its id', () async {
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

    test('RB-I2: a burst of publishes is confirmed in full', () async {
      final bus = await connect();
      addTearDown(bus.close);
      final topic = 'burst-${Random().nextInt(1 << 32).toRadixString(16)}';
      final received = <String>{};
      await bus.subscribe<int>(
        topic,
        group: 'counting',
        handler: (d) => received.add(d.message.id),
      );
      final ids = await Future.wait([
        for (var i = 0; i < 500; i++) bus.publish(topic, i),
      ]);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (received.length < 500 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received, ids.toSet());
    });
  }, skip: skip);
}

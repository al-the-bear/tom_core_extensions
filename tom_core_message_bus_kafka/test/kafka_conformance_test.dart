/// The bus's conformance suite against a Kafka REST proxy, and the server's bus
/// relay publishing through the adapter.
///
/// `@Tags(['kafka'])`, self-skipping unless `tool/run_kafka_tests.sh`
/// started a proxy and named it in `TOM_KAFKA_REST_TEST_URL`.
@Tags(['kafka'])
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_core_message_bus/conformance.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_kafka/tom_core_message_bus_kafka.dart';
import 'package:tom_core_server/tom_core_server.dart';

final String? _url = Platform.environment['TOM_KAFKA_REST_TEST_URL'];

void main() {
  final skip = _url == null
      ? 'TOM_KAFKA_REST_TEST_URL is not set — run tool/run_kafka_tests.sh'
      : null;

  Future<TomKafkaMessageBus> connect() =>
      TomKafkaMessageBus.connect(Uri.parse(_url!));

  group('TomKafkaMessageBus conformance', () {
    tomMessageBusConformance(
      create: connect,
      timeout: const Duration(seconds: 20),
      quiet: const Duration(seconds: 1),
    );
  }, skip: skip);

  group('the bus relay through Kafka', () {
    test('KB-I1: a message queued on the relay reaches a Kafka consumer '
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

    test('KB-I2: two consumers of a group share its partitions, each record '
        'handled once', () async {
      final bus = await connect();
      addTearDown(bus.close);
      final topic = 'shared-${Random().nextInt(1 << 32).toRadixString(16)}';
      final byConsumer = <int, List<String>>{0: [], 1: []};
      for (final consumer in [0, 1]) {
        await bus.subscribe<int>(
          topic,
          group: 'counting',
          handler: (d) => byConsumer[consumer]!.add(d.message.id),
        );
      }
      final ids = [
        for (var i = 0; i < 60; i++) await bus.publish(topic, i, key: 'k$i'),
      ];
      List<String> all() => [...byConsumer[0]!, ...byConsumer[1]!];
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (all().length < ids.length && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(all(), unorderedEquals(ids));
      expect(
        byConsumer.values.every((handled) => handled.isNotEmpty),
        isTrue,
        reason: 'sixty keys over three partitions reach both consumers',
      );
    });
  }, skip: skip);
}

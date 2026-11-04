/// The adapter's refusals against a NATS server, keyed.
///
/// `@Tags(['nats'])`, self-skipping unless `tool/run_nats_tests.sh` started a
/// server and named it in `TOM_NATS_TEST_URL`.
@Tags(['nats'])
library;

import 'dart:io';
import 'dart:math';

import 'package:dart_nats/dart_nats.dart';
import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart';

final String? _url = Platform.environment['TOM_NATS_TEST_URL'];

Matcher _keyed(String key) =>
    throwsA(isA<TomBusException>().having((e) => e.key, 'key', key));

String _unique(String name) =>
    '$name-${Random().nextInt(1 << 32).toRadixString(16)}';

void main() {
  group(
    'refusals',
    () {
      late Client raw;

      setUp(() async {
        raw = Client();
        await raw.connect(Uri.parse(_url!), retry: false);
      });
      tearDown(() => raw.close());

      test(
        'NB-E1: a closed bus refuses to publish (message_bus.closed)',
        () async {
          final bus = await TomNatsMessageBus.connect(Uri.parse(_url!));
          await bus.close();
          await expectLater(
            bus.publish(_unique('t'), 'x'),
            _keyed('message_bus.closed'),
          );
        },
      );

      test('NB-E2: a topic whose subject another stream holds has no stream '
          '(message_bus.nats.stream_failed)', () async {
        final topic = _unique('taken');
        await JetStream(raw).createStream(
          StreamConfig(name: _unique('OTHER'), subjects: ['tombus.$topic']),
        );
        final bus = await TomNatsMessageBus.connect(Uri.parse(_url!));
        addTearDown(bus.close);
        await expectLater(
          bus.publish(topic, 'x'),
          _keyed('message_bus.nats.stream_failed'),
        );
      });

      test(
        'NB-E3: a group whose durable consumer exists with another '
        'configuration is refused (message_bus.nats.consumer_failed)',
        () async {
          final bus = await TomNatsMessageBus.connect(Uri.parse(_url!));
          addTearDown(bus.close);
          final topic = _unique('orders');
          await bus.publish(topic, 'creates the stream');
          await JetStream(raw).createConsumer<dynamic>(
            TomNatsMessageBus.streamOf(topic),
            ConsumerConfig(
              durable: TomNatsMessageBus.consumerOf('billing'),
              filterSubject: 'tombus.$topic',
              deliverPolicy: 'all',
            ),
          );
          await expectLater(
            bus.subscribe<Object?>(topic, group: 'billing', handler: (_) {}),
            _keyed('message_bus.nats.consumer_failed'),
          );
        },
      );

      test('NB-E4: a publish over a lost connection is refused '
          '(message_bus.nats.publish_failed)', () async {
        final client = Client();
        await client.connect(Uri.parse(_url!), retry: false);
        final bus = TomNatsMessageBus(client);
        final topic = _unique('orders');
        await bus.publish(topic, 'creates the stream');
        await client.close();
        await expectLater(
          bus.publish(topic, 'lost'),
          _keyed('message_bus.nats.publish_failed'),
        );
      });
    },
    skip: _url == null
        ? 'TOM_NATS_TEST_URL is not set — run tool/run_nats_tests.sh'
        : null,
  );
}

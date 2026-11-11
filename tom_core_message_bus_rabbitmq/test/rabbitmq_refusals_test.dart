/// The adapter's refusals against a RabbitMQ broker, keyed.
///
/// `@Tags(['rabbitmq'])`, self-skipping unless `tool/run_rabbitmq_tests.sh`
/// started a broker and named it in `TOM_RABBITMQ_TEST_URL`.
@Tags(['rabbitmq'])
library;

import 'dart:io';
import 'dart:math';

import 'package:tom_dart_amqp/tom_dart_amqp.dart';
import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_rabbitmq/tom_core_message_bus_rabbitmq.dart';

final String? _url = Platform.environment['TOM_RABBITMQ_TEST_URL'];

Matcher _keyed(String key) =>
    throwsA(isA<TomBusException>().having((e) => e.key, 'key', key));

String _unique(String name) =>
    '$name-${Random().nextInt(1 << 32).toRadixString(16)}';

void main() {
  group(
    'refusals',
    () {
      late Client raw;
      late Channel channel;

      setUp(() async {
        raw = Client(
          settings: TomRabbitMqMessageBus.settingsOf(Uri.parse(_url!)),
        );
        channel = await raw.channel();
      });
      tearDown(() => raw.close());

      Future<TomRabbitMqMessageBus> connect() =>
          TomRabbitMqMessageBus.connect(Uri.parse(_url!));

      test(
        'RB-E1: a closed bus refuses to publish (message_bus.closed)',
        () async {
          final bus = await connect();
          await bus.close();
          await expectLater(
            bus.publish(_unique('t'), 'x'),
            _keyed('message_bus.closed'),
          );
        },
      );

      test('RB-E2: a topic whose exchange exists as another type cannot be '
          'published to (message_bus.rabbitmq.publish_failed)', () async {
        final topic = _unique('taken');
        await channel.exchange(
          TomRabbitMqMessageBus.exchangeOf('tombus', topic),
          ExchangeType.DIRECT,
          durable: true,
        );
        final bus = await connect();
        addTearDown(bus.close);
        await expectLater(
          bus.publish(topic, 'x'),
          _keyed('message_bus.rabbitmq.publish_failed'),
        );
      });

      test("RB-E3: a group whose queue exists with other properties is refused "
          '(message_bus.rabbitmq.consumer_failed)', () async {
        final topic = _unique('orders');
        await channel.queue(
          TomRabbitMqMessageBus.queueOf('tombus', topic, 'billing'),
          durable: false,
        );
        final bus = await connect();
        addTearDown(bus.close);
        await expectLater(
          bus.subscribe<Object?>(topic, group: 'billing', handler: (_) {}),
          _keyed('message_bus.rabbitmq.consumer_failed'),
        );
      });

      test('RB-E4: a broker refusing the login is unreachable '
          '(message_bus.rabbitmq.unreachable)', () async {
        final uri = Uri.parse(_url!).replace(userInfo: 'nobody:wrong');
        await expectLater(
          TomRabbitMqMessageBus.connect(uri),
          _keyed('message_bus.rabbitmq.unreachable'),
        );
      });
    },
    skip: _url == null
        ? 'TOM_RABBITMQ_TEST_URL is not set — run tool/run_rabbitmq_tests.sh'
        : null,
  );
}

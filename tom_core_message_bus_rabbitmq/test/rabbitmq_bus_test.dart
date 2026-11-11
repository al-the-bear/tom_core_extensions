/// What the adapter decides without a broker: the names it gives exchanges and
/// queues, and the connection settings a URI names.
library;

import 'package:tom_dart_amqp/tom_dart_amqp.dart';
import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_rabbitmq/tom_core_message_bus_rabbitmq.dart';

void main() {
  test('RB-U1: an exchange and a queue are named after their topic and '
      'group, kept apart by a hash', () {
    expect(
      TomRabbitMqMessageBus.exchangeOf('tombus', 'orders'),
      startsWith('tombus.orders_'),
    );
    expect(
      TomRabbitMqMessageBus.queueOf('tombus', 'orders', 'billing'),
      startsWith('tombus.orders.billing_'),
    );
    // Two names the sanitising maps alike still get two exchanges.
    expect(
      TomRabbitMqMessageBus.exchangeOf('tombus', 'a b'),
      isNot(TomRabbitMqMessageBus.exchangeOf('tombus', 'a_b')),
    );
    // A topic and group split differently still get two queues.
    expect(
      TomRabbitMqMessageBus.queueOf('tombus', 'a.b', 'c'),
      isNot(TomRabbitMqMessageBus.queueOf('tombus', 'a', 'b.c')),
    );
    expect(
      TomRabbitMqMessageBus.queueOf('tombus', 'x' * 300, 'y' * 300).length,
      lessThan(255),
      reason: 'AMQP names end at 255 bytes; long names are cut',
    );
  });

  test('RB-U2: a URI names the connection settings', () {
    final settings = TomRabbitMqMessageBus.settingsOf(
      Uri.parse('amqp://app:s%3Acret@broker.internal:5673/orders'),
    );
    expect(settings.host, 'broker.internal');
    expect(settings.port, 5673);
    expect(settings.virtualHost, 'orders');
    final auth = settings.authProvider as PlainAuthenticator;
    expect(auth.userName, 'app');
    expect(auth.password, 's:cret');

    final defaults = TomRabbitMqMessageBus.settingsOf(
      Uri.parse('amqp://localhost'),
    );
    expect(defaults.port, 5672);
    expect(defaults.virtualHost, '/');
    expect((defaults.authProvider as PlainAuthenticator).userName, 'guest');
    expect(
      TomRabbitMqMessageBus.settingsOf(
        Uri.parse('amqp://localhost/%2F'),
      ).virtualHost,
      '/',
    );
  });

  test('RB-U3: an unreachable broker is refused at connect '
      '(message_bus.rabbitmq.unreachable)', () async {
    await expectLater(
      TomRabbitMqMessageBus.connect(Uri.parse('amqp://127.0.0.1:1')),
      throwsA(
        isA<TomBusException>().having(
          (e) => e.key,
          'key',
          'message_bus.rabbitmq.unreachable',
        ),
      ),
    );
  });
}

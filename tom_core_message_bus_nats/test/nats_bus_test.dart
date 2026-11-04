/// What the adapter decides without a server: the names it gives streams and
/// consumers, the subjects it accepts, and the attempt it reads from a reply
/// subject.
library;

import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart';

void main() {
  test('NB-U1: a stream and a consumer are named after their topic and '
      'group, kept apart by a hash', () {
    expect(TomNatsMessageBus.streamOf('orders'), startsWith('TOMBUS_orders_'));
    expect(
      TomNatsMessageBus.streamOf('orders.dlq'),
      startsWith('TOMBUS_orders_dlq_'),
    );
    // Two topics the sanitising maps alike still get two streams.
    expect(
      TomNatsMessageBus.streamOf('a.b'),
      isNot(TomNatsMessageBus.streamOf('a_b')),
    );
    expect(TomNatsMessageBus.consumerOf('billing'), startsWith('billing_'));
    expect(
      TomNatsMessageBus.streamOf('x' * 100).length,
      lessThan(60),
      reason: 'long names are cut, the hash keeps them unique',
    );
  });

  test('NB-U2: the attempt is the delivered count of the reply subject', () {
    expect(
      TomNatsMessageBus.deliveredCount(
        r'$JS.ACK.TOMBUS_orders_1.billing_2.3.17.9.1730000000000000000.0',
      ),
      3,
    );
    expect(
      TomNatsMessageBus.deliveredCount(
        r'$JS.ACK.hub.ACCHASH.TOMBUS_orders_1.billing_2.2.17.9.1730000000.0.tok',
      ),
      2,
    );
    expect(TomNatsMessageBus.deliveredCount(null), 1);
    expect(TomNatsMessageBus.deliveredCount('_INBOX.x'), 1);
  });

  test('NB-U3: a topic that is no NATS subject is refused '
      '(message_bus.nats.invalid_topic)', () {
    for (final topic in ['orders new', 'orders.*', 'orders.>', '.orders']) {
      expect(
        () => TomNatsMessageBus.validSubject('tombus', topic),
        throwsA(
          isA<TomBusException>().having(
            (e) => e.key,
            'key',
            'message_bus.nats.invalid_topic',
          ),
        ),
        reason: topic,
      );
    }
    expect(
      TomNatsMessageBus.validSubject('tombus', 'orders.dlq'),
      'tombus.orders.dlq',
    );
  });

  test('NB-U4: an unreachable server is refused at connect '
      '(message_bus.nats.unreachable)', () async {
    await expectLater(
      TomNatsMessageBus.connect(Uri.parse('nats://127.0.0.1:1')),
      throwsA(
        isA<TomBusException>().having(
          (e) => e.key,
          'key',
          'message_bus.nats.unreachable',
        ),
      ),
    );
  });
}

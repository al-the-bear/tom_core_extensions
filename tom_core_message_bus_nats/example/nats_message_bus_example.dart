// ignore_for_file: avoid_print
/// The message bus over NATS JetStream: two consumer groups receiving every
/// order, and a message no consumer can handle dead-lettered.
///
/// Needs a NATS server with JetStream at `TOM_NATS_TEST_URL` (default
/// `nats://127.0.0.1:4222`) — `docker run -p 4222:4222 nats:2.10-alpine -js`.
/// Run with `dart run example/nats_message_bus_example.dart`; every step
/// checks its own result.
library;

import 'dart:io';
import 'dart:math';

import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart';

void check(bool ok, String expectation) {
  if (!ok) throw StateError('example check failed: $expectation');
}

Future<void> until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main() async {
  final url =
      Platform.environment['TOM_NATS_TEST_URL'] ?? 'nats://127.0.0.1:4222';
  final bus = await TomNatsMessageBus.connect(Uri.parse(url));
  // Topics of this run's own, so a server kept between runs stays tidy.
  final run = Random().nextInt(1 << 32).toRadixString(16);
  final orders = 'orders-$run';

  // 1. Two groups each receive every order.
  final billed = <Object?>[];
  final shipped = <Object?>[];
  await bus.subscribe<Map<String, Object?>>(
    orders,
    group: 'billing',
    handler: (d) => billed.add(d.payload['order']),
  );
  await bus.subscribe<Map<String, Object?>>(
    orders,
    group: 'shipping',
    handler: (d) => shipped.add(d.payload['order']),
  );
  await bus.publish(orders, {'order': 'o-1'});
  await until(() => billed.isNotEmpty && shipped.isNotEmpty);
  print('1. billing $billed, shipping $shipped');
  check(billed.single == 'o-1' && shipped.single == 'o-1', 'both groups');

  // 2. A message rejected for good lands on `<topic>.dlq`.
  final invoices = 'invoices-$run';
  final dead = <TomBusDelivery<Object?>>[];
  await bus.subscribe<Object?>(
    tomDeadLetterTopic(invoices),
    group: 'operators',
    handler: dead.add,
  );
  await bus.subscribe<Object?>(
    invoices,
    group: 'printing',
    handler: (d) => d.reject(requeue: false, reason: 'no printer'),
  );
  await bus.publish(invoices, {'invoice': 'i-9'});
  await until(() => dead.isNotEmpty);
  final reason = dead.single.message.headers[TomBusHeaders.deadLetterReason];
  print('2. dead-lettered: $reason');
  check(reason == 'no printer', 'the rejection reaches the dead-letter topic');

  await bus.close();
}

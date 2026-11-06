/// The bus's conformance suite against LocalStack's SNS and SQS, and the
/// server's bus relay publishing through the adapter.
///
/// `@Tags(['aws'])`, self-skipping unless `tool/run_aws_tests.sh` started
/// LocalStack and named it in `TOM_AWS_TEST_ENDPOINT`.
@Tags(['aws'])
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_core_message_bus/conformance.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_aws/tom_core_message_bus_aws.dart';
import 'package:tom_core_server/tom_core_server.dart';

final String? _endpoint = Platform.environment['TOM_AWS_TEST_ENDPOINT'];

/// A bus on LocalStack, which accepts any key.
TomAwsMessageBus localStackBus() => TomAwsMessageBus.withKeys(
  region: 'us-east-1',
  accessKeyId: 'test',
  secretAccessKey: 'test',
  endpoint: Uri.parse(_endpoint!),
);

void main() {
  final skip = _endpoint == null
      ? 'TOM_AWS_TEST_ENDPOINT is not set — run tool/run_aws_tests.sh'
      : null;

  group('TomAwsMessageBus conformance', () {
    tomMessageBusConformance(
      create: () async => localStackBus(),
      timeout: const Duration(seconds: 30),
      quiet: const Duration(seconds: 2),
    );
  }, skip: skip);

  group('the bus relay through SNS and SQS', () {
    test('AB-I1: a message queued on the relay reaches an SQS consumer once, '
        'under its id', () async {
      final bus = localStackBus();
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

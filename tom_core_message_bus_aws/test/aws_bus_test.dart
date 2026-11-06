/// What the adapter decides without AWS: the names it gives topics and queues,
/// the message envelope, the queue policy, and its refusals, against SNS and
/// SQS played by a mock client.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_aws/tom_core_message_bus_aws.dart';
import 'package:tom_core_server/tom_core_server.dart' show TomAwsCredentials;

Matcher _keyed(String key) =>
    throwsA(isA<TomBusException>().having((e) => e.key, 'key', key));

TomAwsMessageBus _bus(MockClient client) => TomAwsMessageBus(
  region: 'eu-central-1',
  credentials: () async =>
      const TomAwsCredentials(accessKeyId: 'a', secretAccessKey: 's'),
  httpClient: client,
);

const _topicXml =
    '<CreateTopicResponse><CreateTopicResult><TopicArn>'
    'arn:aws:sns:eu-central-1:000000000000:t</TopicArn></CreateTopicResult>'
    '</CreateTopicResponse>';

String _error(String code) =>
    '<ErrorResponse><Error><Code>$code</Code><Message>no</Message></Error>'
    '</ErrorResponse>';

void main() {
  test('AB-U1: topics and queues are named after their topic and group, kept '
      'apart by a hash, queues within 80 characters', () {
    expect(
      TomAwsMessageBus.topicNameOf('tombus', 'orders.dlq'),
      startsWith('tombus-orders_dlq-'),
    );
    expect(
      TomAwsMessageBus.topicNameOf('tombus', 'a.b'),
      isNot(TomAwsMessageBus.topicNameOf('tombus', 'a_b')),
    );
    expect(
      TomAwsMessageBus.queueNameOf('tombus', 'orders', 'billing'),
      startsWith('tombus-orders-billing-'),
    );
    for (final prefix in ['tombus', 'p' * 100]) {
      expect(
        TomAwsMessageBus.queueNameOf(
          prefix,
          'x' * 300,
          'y' * 300,
          suffix: 'abcdef0123',
        ).length,
        lessThanOrEqualTo(80),
        reason: 'prefix of ${prefix.length}',
      );
    }
  });

  test('AB-U2: a message survives its envelope; a foreign body is none', () {
    final message = TomBusMessage(
      id: 'm-1',
      topic: 'orders',
      key: 'c-7',
      payload: {'n': 1},
      headers: const {'x-tenant': 'acme'},
      publishedAt: DateTime.utc(2026, 11, 6, 12),
    );
    final back = TomAwsMessageBus.messageOf(
      'orders',
      jsonEncode(TomAwsMessageBus.envelopeOf(message)),
    )!;
    expect(back.id, 'm-1');
    expect(back.key, 'c-7');
    expect(back.payload, {'n': 1});
    expect(back.headers, {'x-tenant': 'acme'});
    expect(back.publishedAt, DateTime.utc(2026, 11, 6, 12));
    expect(TomAwsMessageBus.messageOf('orders', 'not json'), isNull);
    expect(TomAwsMessageBus.messageOf('orders', '{"other":1}'), isNull);
  });

  test('AB-U3: the queue policy lets the one topic, and nothing else, send to '
      'the queue', () {
    final policy = TomAwsMessageBus.queuePolicy('arn:q', 'arn:t');
    final statement = (policy['Statement']! as List).single as Map;
    expect(statement['Principal'], {'Service': 'sns.amazonaws.com'});
    expect(statement['Action'], 'sqs:SendMessage');
    expect(statement['Resource'], 'arn:q');
    expect(statement['Condition'], {
      'ArnEquals': {'aws:SourceArn': 'arn:t'},
    });
  });

  test('AB-U4: an XML value is read and unescaped', () {
    expect(
      TomAwsMessageBus.xmlValue('<a><B>x &amp; &lt;y&gt;</B></a>', 'B'),
      'x & <y>',
    );
    expect(TomAwsMessageBus.xmlValue('<a/>', 'B'), isNull);
  });

  test('AB-U5: a topic SNS does not create is refused '
      '(message_bus.aws.topic_failed)', () async {
    final bus = _bus(
      MockClient((_) async => http.Response(_error('AuthorizationError'), 403)),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.publish('orders', 'x'),
      _keyed('message_bus.aws.topic_failed'),
    );
  });

  test('AB-U6: a publish SNS refuses is refused '
      '(message_bus.aws.publish_failed)', () async {
    final bus = _bus(
      MockClient((request) async {
        final action = Uri.splitQueryString(request.body)['Action'];
        return action == 'CreateTopic'
            ? http.Response(_topicXml, 200)
            : http.Response(_error('KMSDisabled'), 400);
      }),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.publish('orders', 'x'),
      _keyed('message_bus.aws.publish_failed'),
    );
  });

  test('AB-U7: a queue SQS does not create is refused '
      '(message_bus.aws.consumer_failed)', () async {
    final bus = _bus(
      MockClient((request) async {
        if (request.headers['x-amz-target'] != null) {
          return http.Response(
            '{"__type":"com.amazonaws.sqs#QueueDeletedRecently",'
            '"message":"wait"}',
            400,
          );
        }
        return http.Response(_topicXml, 200);
      }),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.subscribe<Object?>('orders', group: 'billing', handler: (_) {}),
      _keyed('message_bus.aws.consumer_failed'),
    );
  });

  test('AB-U8: a closed bus refuses to publish (message_bus.closed)', () async {
    final bus = _bus(MockClient((_) async => http.Response('', 200)));
    await bus.close();
    await expectLater(bus.publish('orders', 'x'), _keyed('message_bus.closed'));
  });

  test('AB-U9: every request is signed for its service', () async {
    final scopes = <String>{};
    final bus = _bus(
      MockClient((request) async {
        final auth = request.headers['authorization']!;
        scopes.add(RegExp(r'/eu-central-1/(\w+)/').firstMatch(auth)!.group(1)!);
        if (request.headers['x-amz-target'] == 'AmazonSQS.CreateQueue') {
          return http.Response('{"QueueUrl":"http://q/1"}', 200);
        }
        if (request.headers['x-amz-target'] == 'AmazonSQS.GetQueueAttributes') {
          return http.Response('{"Attributes":{"QueueArn":"arn:q"}}', 200);
        }
        if (request.headers['x-amz-target'] != null) {
          return http.Response('{}', 200);
        }
        final action = Uri.splitQueryString(request.body)['Action'];
        if (action == 'Subscribe') {
          return http.Response('<SubscriptionArn>arn:s</SubscriptionArn>', 200);
        }
        return http.Response(_topicXml, 200);
      }),
    );
    addTearDown(bus.close);
    final subscription = await bus.subscribe<Object?>(
      'orders',
      group: 'billing',
      handler: (_) {},
    );
    await subscription.cancel();
    expect(scopes, {'sns', 'sqs'});
  });
}

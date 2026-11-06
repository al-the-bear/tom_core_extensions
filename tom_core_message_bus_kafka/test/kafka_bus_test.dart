/// What the adapter decides without a cluster: topic names, the record
/// envelope, and its refusals, against a REST proxy played by a mock client.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_kafka/tom_core_message_bus_kafka.dart';

Matcher _keyed(String key) =>
    throwsA(isA<TomBusException>().having((e) => e.key, 'key', key));

/// A proxy that names its cluster, creates topics, and answers the rest with
/// [rest].
MockClient _proxy(Future<http.Response> Function(http.Request) rest) =>
    MockClient((request) async {
      final path = request.url.path;
      if (path == '/v3/clusters') {
        return http.Response(
          jsonEncode({
            'data': [
              {'cluster_id': 'c-1'},
            ],
          }),
          200,
        );
      }
      if (path == '/v3/clusters/c-1/topics' && request.method == 'POST') {
        return http.Response('{}', 201);
      }
      return rest(request);
    });

TomKafkaMessageBus _bus(MockClient client) =>
    TomKafkaMessageBus(Uri.parse('http://proxy:8082'), client: client);

void main() {
  test('KB-U1: a topic that is no Kafka topic name is refused '
      '(message_bus.kafka.invalid_topic)', () {
    for (final topic in ['orders new', 'orders/1', '.', '..', 'x' * 250]) {
      expect(
        () => TomKafkaMessageBus.validTopic(topic),
        _keyed('message_bus.kafka.invalid_topic'),
        reason: topic,
      );
    }
    expect(TomKafkaMessageBus.validTopic('orders.dlq'), 'orders.dlq');
  });

  test('KB-U2: a message survives its record envelope', () {
    final message = TomBusMessage(
      id: 'm-1',
      topic: 'orders',
      key: 'c-7',
      payload: {'n': 1},
      headers: const {'x-tenant': 'acme'},
      publishedAt: DateTime.utc(2026, 11, 6, 12),
    );
    final back = TomKafkaMessageBus.messageOf(
      'orders',
      'c-7',
      jsonDecode(jsonEncode(TomKafkaMessageBus.envelopeOf(message))),
    )!;
    expect(back.id, 'm-1');
    expect(back.key, 'c-7');
    expect(back.payload, {'n': 1});
    expect(back.headers, {'x-tenant': 'acme'});
    expect(back.publishedAt, DateTime.utc(2026, 11, 6, 12));
    expect(
      TomKafkaMessageBus.messageOf('orders', null, 'not an envelope'),
      isNull,
    );
  });

  test('KB-U3: an unreachable proxy is refused at connect '
      '(message_bus.kafka.unreachable)', () async {
    await expectLater(
      TomKafkaMessageBus.connect(Uri.parse('http://127.0.0.1:1')),
      _keyed('message_bus.kafka.unreachable'),
    );
  });

  test('KB-U4: a topic the cluster refuses to create is refused '
      '(message_bus.kafka.topic_failed)', () async {
    final bus = _bus(
      MockClient((request) async {
        if (request.url.path == '/v3/clusters') {
          return http.Response('{"data":[{"cluster_id":"c-1"}]}', 200);
        }
        if (request.method == 'POST') {
          return http.Response(
            '{"error_code":40002,"message":"Partitions count must be '
            'greater than 0"}',
            400,
          );
        }
        // The topic does not exist: the refusal was not "already created".
        return http.Response('{"error_code":40403}', 404);
      }),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.publish('orders', 'x'),
      _keyed('message_bus.kafka.topic_failed'),
    );
  });

  test('KB-U5: a topic that exists already is taken as it is', () async {
    var produced = 0;
    final bus = _bus(
      MockClient((request) async {
        final path = request.url.path;
        if (path == '/v3/clusters') {
          return http.Response('{"data":[{"cluster_id":"c-1"}]}', 200);
        }
        if (path == '/v3/clusters/c-1/topics') {
          return http.Response(
            '{"error_code":40002,"message":"The topic has already been '
            'created"}',
            400,
          );
        }
        if (path == '/v3/clusters/c-1/topics/orders') {
          return http.Response('{"topic_name":"orders"}', 200);
        }
        produced++;
        return http.Response(
          '{"offsets":[{"partition":0,"offset":7,"error_code":null}]}',
          200,
        );
      }),
    );
    addTearDown(bus.close);
    await bus.publish('orders', 'x');
    expect(produced, 1);
  });

  test('KB-U6: a record the cluster does not take is refused '
      '(message_bus.kafka.publish_failed)', () async {
    final bus = _bus(
      _proxy(
        (_) async => http.Response(
          '{"offsets":[{"partition":0,"offset":-1,"error_code":2,'
          '"error":"NOT_ENOUGH_REPLICAS"}]}',
          200,
        ),
      ),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.publish('orders', 'x'),
      _keyed('message_bus.kafka.publish_failed'),
    );
  });

  test('KB-U7: a consumer instance the proxy refuses is refused '
      '(message_bus.kafka.consumer_failed)', () async {
    final bus = _bus(
      _proxy(
        (_) async => http.Response(
          '{"error_code":40902,"message":"Consumer with specified consumer '
          'ID already exists"}',
          409,
        ),
      ),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.subscribe<Object?>('orders', group: 'billing', handler: (_) {}),
      _keyed('message_bus.kafka.consumer_failed'),
    );
  });

  test('KB-U8: a closed bus refuses to publish (message_bus.closed)', () async {
    final bus = _bus(_proxy((_) async => http.Response('{}', 200)));
    await bus.close();
    await expectLater(bus.publish('orders', 'x'), _keyed('message_bus.closed'));
  });

  test('KB-U9: ordering per key is declared', () {
    expect(
      _bus(
        _proxy((_) async => http.Response('{}', 200)),
      ).capabilities.orderedPerKey,
      isTrue,
    );
  });
}

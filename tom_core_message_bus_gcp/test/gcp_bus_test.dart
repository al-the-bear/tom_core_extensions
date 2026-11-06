/// What the adapter decides without Pub/Sub: the names it gives topics and
/// subscriptions, the message envelope, the token it sends, and its refusals,
/// against Pub/Sub played by a mock client.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_gcp/tom_core_message_bus_gcp.dart';

Matcher _keyed(String key) =>
    throwsA(isA<TomBusException>().having((e) => e.key, 'key', key));

TomPubSubMessageBus _bus(MockClient client, {TomGcpTokenSource? token}) =>
    TomPubSubMessageBus(projectId: 'p', token: token, httpClient: client);

http.Response _error(int status, String code) => http.Response(
  jsonEncode({
    'error': {'code': status, 'status': code, 'message': 'no'},
  }),
  status,
);

void main() {
  test('GB-U1: topics and subscriptions are named after their topic and '
      'group, kept apart by a hash, starting with a letter', () {
    expect(
      TomPubSubMessageBus.topicIdOf('tombus', 'orders.dlq'),
      startsWith('tombus-orders.dlq-'),
    );
    expect(
      TomPubSubMessageBus.topicIdOf('tombus', 'a b'),
      isNot(TomPubSubMessageBus.topicIdOf('tombus', 'a_b')),
    );
    expect(
      TomPubSubMessageBus.subscriptionIdOf('tombus', 'orders', 'billing'),
      startsWith('tombus-orders-billing-'),
    );
    expect(
      TomPubSubMessageBus.subscriptionIdOf(
        'tombus',
        'x' * 300,
        'y' * 300,
      ).length,
      lessThanOrEqualTo(255),
    );
  });

  test('GB-U2: a message survives its envelope; foreign data is none', () {
    final message = TomBusMessage(
      id: 'm-1',
      topic: 'orders',
      key: 'c-7',
      payload: {'n': 1},
      headers: const {'x-tenant': 'acme'},
      publishedAt: DateTime.utc(2026, 11, 6, 12),
    );
    final data = base64.encode(
      utf8.encode(jsonEncode(TomPubSubMessageBus.envelopeOf(message))),
    );
    final back = TomPubSubMessageBus.messageOf('orders', data)!;
    expect(back.id, 'm-1');
    expect(back.key, 'c-7');
    expect(back.payload, {'n': 1});
    expect(back.headers, {'x-tenant': 'acme'});
    expect(back.publishedAt, DateTime.utc(2026, 11, 6, 12));
    expect(TomPubSubMessageBus.messageOf('orders', 'not base64!'), isNull);
    expect(
      TomPubSubMessageBus.messageOf('orders', base64.encode([1, 2])),
      isNull,
    );
  });

  test('GB-U3: every request carries the token; a keyed message its '
      'ordering key', () async {
    final requests = <http.Request>[];
    final bus = _bus(
      MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
      token: () async => 'tok-1',
    );
    addTearDown(bus.close);
    await bus.publish('orders', 'x', key: 'c-7');
    expect(requests.map((r) => r.headers['Authorization']).toSet(), {
      'Bearer tok-1',
    });
    final publish = requests.last;
    expect(publish.url.path, endsWith(':publish'));
    final sent = (jsonDecode(publish.body) as Map)['messages'] as List;
    expect((sent.single as Map)['orderingKey'], 'c-7');
  });

  test('GB-U4: a topic Pub/Sub has already is taken as it is', () async {
    var published = 0;
    final bus = _bus(
      MockClient((request) async {
        if (request.method == 'PUT') return _error(409, 'ALREADY_EXISTS');
        published++;
        return http.Response('{"messageIds":["1"]}', 200);
      }),
    );
    addTearDown(bus.close);
    await bus.publish('orders', 'x');
    expect(published, 1);
  });

  test('GB-U5: a topic Pub/Sub does not create is refused '
      '(message_bus.pubsub.topic_failed)', () async {
    final bus = _bus(MockClient((_) async => _error(403, 'PERMISSION_DENIED')));
    addTearDown(bus.close);
    await expectLater(
      bus.publish('orders', 'x'),
      _keyed('message_bus.pubsub.topic_failed'),
    );
  });

  test('GB-U6: a publish Pub/Sub refuses is refused '
      '(message_bus.pubsub.publish_failed)', () async {
    final bus = _bus(
      MockClient(
        (request) async => request.method == 'PUT'
            ? http.Response('{}', 200)
            : _error(400, 'INVALID_ARGUMENT'),
      ),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.publish('orders', 'x'),
      _keyed('message_bus.pubsub.publish_failed'),
    );
  });

  test('GB-U7: a subscription Pub/Sub does not create is refused '
      '(message_bus.pubsub.consumer_failed)', () async {
    final bus = _bus(
      MockClient((request) async {
        if (request.url.path.contains('/subscriptions/')) {
          return _error(400, 'FAILED_PRECONDITION');
        }
        return http.Response('{}', 200);
      }),
    );
    addTearDown(bus.close);
    await expectLater(
      bus.subscribe<Object?>('orders', group: 'billing', handler: (_) {}),
      _keyed('message_bus.pubsub.consumer_failed'),
    );
  });

  test('GB-U8: a closed bus refuses to publish (message_bus.closed)', () async {
    final bus = _bus(MockClient((_) async => http.Response('{}', 200)));
    await bus.close();
    await expectLater(bus.publish('orders', 'x'), _keyed('message_bus.closed'));
  });

  test('GB-U9: a key file without a project needs one '
      '(message_bus.pubsub.no_project)', () {
    // A throwaway key generated for this test, read and never used to sign.
    final pem = File(
      'test/fixtures/throwaway_rsa_private.pem',
    ).readAsStringSync();
    final key = jsonEncode({
      'client_email': 'bus@p.iam.gserviceaccount.com',
      'private_key': pem,
    });
    expect(
      () => TomPubSubMessageBus.serviceAccount(key),
      _keyed('message_bus.pubsub.no_project'),
    );
    final bus = TomPubSubMessageBus.serviceAccount(key, projectId: 'p');
    expect(bus.projectId, 'p');
    expect(
      TomPubSubMessageBus.serviceAccountCredential(key).scope,
      TomPubSubMessageBus.pubsubScope,
    );
  });

  test('GB-U10: the metadata server token is cached until a minute before it '
      'expires; a refusal is keyed (message_bus.pubsub.no_token)', () async {
    var now = DateTime.utc(2026, 11, 6, 12);
    var asked = 0;
    final source = TomPubSubMessageBus.metadataServer(
      clock: () => now,
      httpClient: MockClient((request) async {
        expect(request.headers['Metadata-Flavor'], 'Google');
        asked++;
        return http.Response(
          jsonEncode({'access_token': 't$asked', 'expires_in': 3600}),
          200,
        );
      }),
    );
    expect(await source(), 't1');
    now = now.add(const Duration(minutes: 58));
    expect(await source(), 't1');
    now = now.add(const Duration(minutes: 2));
    expect(await source(), 't2');

    final refused = TomPubSubMessageBus.metadataServer(
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await expectLater(refused(), _keyed('message_bus.pubsub.no_token'));
  });
}

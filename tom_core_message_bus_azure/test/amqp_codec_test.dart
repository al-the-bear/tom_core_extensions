/// The AMQP 1.0 codec, the message format, the shared access signature and the
/// names the bus gives Service Bus entities — everything that needs no broker.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_azure/tom_core_message_bus_azure.dart';

Object? _roundTrip(Object? value) => amqpDecode(amqpEncode(value));

void main() {
  group('the type codec', () {
    test('ZB-U1: primitive values read back as written', () {
      final values = <Object?>[
        null,
        true,
        false,
        0,
        -1,
        127,
        -128,
        1 << 40,
        -(1 << 40),
        3.25,
        'Grüße',
        'x' * 300,
        Uint8List.fromList([1, 2, 3]),
        DateTime.utc(2026, 11, 6, 12, 30, 15, 250),
        const AmqpSymbol('amqp:accepted:list'),
        const AmqpUbyte(200),
        const AmqpUshort(65000),
        const AmqpUint(0),
        const AmqpUint(255),
        const AmqpUint(4000000000),
        const AmqpUlong(0),
        const AmqpUlong(17),
        const AmqpUlong(1 << 50),
        AmqpUuid(List.generate(16, (i) => i * 7)),
      ];
      for (final value in values) {
        expect(_roundTrip(value), value, reason: '$value');
      }
    });

    test('ZB-U2: the compact encodings are used where they fit', () {
      expect(amqpEncode(null), [0x40]);
      expect(amqpEncode(true), [0x41]);
      expect(amqpEncode(const AmqpUint(0)), [0x43]);
      expect(amqpEncode(const AmqpUint(5)), [0x52, 5]);
      expect(amqpEncode(const AmqpUlong(0x10)), [0x53, 0x10]);
      expect(amqpEncode(5), [0x55, 5]);
      expect(amqpEncode(<Object?>[]), [0x45]);
      expect(amqpEncode('ab'), [0xa1, 2, 0x61, 0x62]);
      expect(amqpEncode(const AmqpSymbol('PLAIN')), [
        0xa3,
        5,
        ...ascii.encode('PLAIN'),
      ]);
    });

    test('ZB-U3: lists, maps and described values nest, small and large', () {
      final small = AmqpDescribed(const AmqpUlong(0x10), [
        'container',
        null,
        const AmqpUint(65536),
        {const AmqpSymbol('k'): 'v', 'n': 1},
      ]);
      expect(_roundTrip(small), small);
      expect(amqpEncode(small).take(3), [0x00, 0x53, 0x10]);
      final large = [
        for (var i = 0; i < 100; i++) {'key-$i': 'value-$i'},
      ];
      final encoded = amqpEncode(large);
      expect(encoded.first, 0xd0, reason: 'list32 for a large list');
      expect(_roundTrip(large), large);
    });

    test('ZB-U4: an array is written with one constructor and reads back as '
        'its elements', () {
      final array = AmqpArray('symbol', [
        const AmqpSymbol('PLAIN'),
        const AmqpSymbol('ANONYMOUS'),
      ]);
      final bytes = amqpEncode(array);
      expect(bytes.first, 0xf0);
      expect(amqpDecode(bytes), [
        const AmqpSymbol('PLAIN'),
        const AmqpSymbol('ANONYMOUS'),
      ]);
      // As a server sends it: an 8-bit array of 8-bit symbols.
      expect(
        amqpDecode(
          Uint8List.fromList([0xe0, 7, 1, 0xa3, 5, ...ascii.encode('PLAIN')]),
        ),
        [const AmqpSymbol('PLAIN')],
      );
    });

    test('ZB-U5: bytes that end early or use an unknown constructor are '
        'refused', () {
      expect(
        () => amqpDecode(Uint8List.fromList([0xa1, 5, 0x61])),
        throwsA(isA<AmqpCodecException>()),
      );
      expect(
        () => amqpDecode(Uint8List.fromList([0x3f])),
        throwsA(isA<AmqpCodecException>()),
      );
      expect(() => amqpEncode(Object()), throwsA(isA<AmqpCodecException>()));
    });
  });

  group('the message format', () {
    test('ZB-U6: a message reads back with its sections', () {
      final message = AmqpMessage(
        data: Uint8List.fromList(utf8.encode('{"a":1}')),
        messageId: 'm-1',
        to: 'topic',
        subject: 'subject',
        replyTo: 'reply',
        correlationId: 'c-1',
        contentType: 'application/json',
        creationTime: DateTime.utc(2026, 11, 6),
        applicationProperties: {'x-tenant': 'acme', 'n': 3},
        messageAnnotations: {const AmqpSymbol('x-opt-key'): 'k'},
        deliveryCount: 2,
      );
      final read = AmqpMessage.decode(message.encode());
      expect(utf8.decode(read.data!), '{"a":1}');
      expect(read.messageId, 'm-1');
      expect(read.to, 'topic');
      expect(read.subject, 'subject');
      expect(read.replyTo, 'reply');
      expect(read.correlationId, 'c-1');
      expect(read.contentType, 'application/json');
      expect(read.creationTime, DateTime.utc(2026, 11, 6));
      expect(read.applicationProperties, {'x-tenant': 'acme', 'n': 3});
      expect(read.messageAnnotations, {const AmqpSymbol('x-opt-key'): 'k'});
      expect(read.deliveryCount, 2);
      expect(read.durable, isTrue);
    });

    test('ZB-U7: an amqp-value body, and the outcomes as dispositions', () {
      final read = AmqpMessage.decode(AmqpMessage(value: 'token').encode());
      expect(read.data, isNull);
      expect(read.value, 'token');
      expect(const AmqpAccepted().encoded.code, AmqpCodes.accepted);
      expect(const AmqpReleased().encoded.code, AmqpCodes.released);
      expect(const AmqpModified().encoded.value, [true]);
      final rejected = const AmqpRejected(
        condition: 'amqp:internal-error',
        description: 'why',
      ).encoded;
      expect(rejected.code, AmqpCodes.rejected);
      expect(
        AmqpException.of((rejected.value! as List).single)?.condition,
        'amqp:internal-error',
      );
    });
  });

  group('the shared access signature', () {
    test('ZB-U8: an HMAC-SHA256 over the encoded resource and the expiry', () {
      const key = TomServiceBusSasKey('RootManageSharedAccessKey', 'secret');
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final token = key.signature(
        Uri.parse('https://ns.servicebus.windows.net/Topic'),
        validFor: const Duration(seconds: 3600),
        now: now,
      );
      const resource = 'https%3A%2F%2Fns.servicebus.windows.net%2Ftopic';
      final mac = Hmac(
        sha256,
        utf8.encode('secret'),
      ).convert(utf8.encode('$resource\n1700003600'));
      expect(
        token,
        'SharedAccessSignature sr=$resource'
        '&sig=${Uri.encodeQueryComponent(base64.encode(mac.bytes))}'
        '&se=1700003600&skn=RootManageSharedAccessKey',
      );
    });
  });

  group('names and the connection string', () {
    test('ZB-U9: subscription names stay within 50 characters and apart', () {
      final long = 'g' * 80;
      final a = TomServiceBusMessageBus.subscriptionNameOf(long);
      final b = TomServiceBusMessageBus.subscriptionNameOf('${long}x');
      final ephemeral = TomServiceBusMessageBus.subscriptionNameOf(
        long,
        suffix: 'abcdef12',
      );
      expect(a.length, lessThanOrEqualTo(50));
      expect(ephemeral.length, lessThanOrEqualTo(50));
      expect(a, isNot(b));
      expect(
        TomServiceBusMessageBus.topicNameOf('tombus', 'orders/eu'),
        startsWith('tombus-orders_eu-'),
      );
    });

    test('ZB-U10: an emulator connection string addresses the emulator, a '
        'namespace one Service Bus, and one without a key is refused', () {
      final emulator = TomServiceBusMessageBus.fromConnectionString(
        'Endpoint=sb://localhost;SharedAccessKeyName=Root;'
        'SharedAccessKey=k;UseDevelopmentEmulator=true;',
        amqpPort: 15672,
        managementPort: 15300,
      );
      expect(emulator.host, 'localhost');
      expect(emulator.amqpPort, 15672);
      expect(emulator.secure, isFalse);
      expect(emulator.managementEndpoint, Uri.parse('http://localhost:15300/'));
      final azure = TomServiceBusMessageBus.fromConnectionString(
        'Endpoint=sb://ns.servicebus.windows.net/;SharedAccessKeyName=Root;'
        'SharedAccessKey=k',
      );
      expect(azure.amqpPort, 5671);
      expect(azure.secure, isTrue);
      expect(
        azure.managementEndpoint,
        Uri.parse('https://ns.servicebus.windows.net/'),
      );
      expect(
        () => TomServiceBusMessageBus.fromConnectionString(
          'Endpoint=sb://ns.servicebus.windows.net/',
        ),
        throwsA(
          isA<TomBusException>().having(
            (e) => e.key,
            'key',
            'message_bus.azure.connection_string_invalid',
          ),
        ),
      );
      expect(
        TomServiceBusMessageBus.isoDuration(const Duration(seconds: 30)),
        'PT30S',
      );
    });
  });

  group('the management API', () {
    test('ZB-U14: a request carries a shared access signature for its '
        'resource, or an Entra ID bearer token', () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return http.Response('', 201);
      });
      final sas = TomServiceBusMessageBus(
        host: 'ns.servicebus.windows.net',
        credential: const TomServiceBusSasKey('Root', 'k'),
        httpClient: client,
      );
      expect(await sas.management('PUT', 'topic', body: '<entry/>'), 201);
      final signed = seen.single;
      expect(
        signed.url.toString(),
        'https://ns.servicebus.windows.net/topic?api-version=2021-05',
      );
      expect(
        signed.headers['authorization'],
        startsWith(
          'SharedAccessSignature '
          'sr=https%3A%2F%2Fns.servicebus.windows.net%2Ftopic&sig=',
        ),
      );
      expect(
        signed.headers['content-type'],
        startsWith('application/atom+xml'),
      );

      seen.clear();
      final entra = TomServiceBusMessageBus(
        host: 'ns.servicebus.windows.net',
        credential: TomServiceBusTokenCredential(() async => 'entra-token'),
        httpClient: client,
      );
      await entra.management('DELETE', 'topic/subscriptions/g');
      expect(seen.single.headers['authorization'], 'Bearer entra-token');
    });

    test('ZB-U15: a refusal other than an accepted status is a '
        'management failure', () async {
      final bus = TomServiceBusMessageBus(
        host: 'ns.servicebus.windows.net',
        credential: const TomServiceBusSasKey('Root', 'k'),
        httpClient: MockClient((_) async => http.Response('<Error/>', 409)),
      );
      expect(await bus.management('PUT', 'topic', accept: const {409}), 409);
      await expectLater(
        bus.management('PUT', 'topic'),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('message_bus.azure.management_failed'),
          ),
        ),
      );
    });
  });

  group('failures without a broker', () {
    Matcher keyed(String key) =>
        throwsA(isA<TomBusException>().having((e) => e.key, 'key', key));

    test('ZB-U16: a closed bus refuses to publish', () async {
      final bus = TomServiceBusMessageBus(
        host: 'ns.servicebus.windows.net',
        credential: const TomServiceBusSasKey('Root', 'k'),
        httpClient: MockClient((_) async => http.Response('', 201)),
      );
      await bus.close();
      await expectLater(
        bus.publish('orders', {'n': 1}),
        keyed('message_bus.closed'),
      );
    });

    test('ZB-U17: a send that cannot reach the broker is a publish '
        'failure', () async {
      // The topic is created; the AMQP port has nothing listening.
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      final bus = TomServiceBusMessageBus(
        host: '127.0.0.1',
        credential: const TomServiceBusSasKey('Root', 'k'),
        amqpPort: port,
        secure: false,
        httpClient: MockClient((_) async => http.Response('', 201)),
      );
      await expectLater(
        bus.publish('orders', {'n': 1}),
        keyed('message_bus.azure.publish_failed'),
      );
      await bus.close();
    });

    test('ZB-U18: a subscription the management API cannot be reached for '
        'is a consumer failure', () async {
      final bus = TomServiceBusMessageBus(
        host: 'ns.servicebus.windows.net',
        credential: const TomServiceBusSasKey('Root', 'k'),
        httpClient: MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      await expectLater(
        bus.subscribe<Map<String, Object?>>(
          'orders',
          group: 'billing',
          handler: (_) {},
        ),
        keyed('message_bus.azure.consumer_failed'),
      );
      await bus.close();
    });
  });
}

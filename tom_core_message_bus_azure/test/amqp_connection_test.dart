/// The AMQP connection against a scripted peer in this process: the opening
/// handshake, a send settled by the peer's disposition, a receiver granted
/// credit, and links the peer numbers with handles of its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_core_message_bus_azure/tom_core_message_bus_azure.dart';

/// A peer that answers a client's frames: SASL, open, begin, attach (with a
/// handle of its own, [peerHandleBase] up), and to a transfer a disposition.
class _ScriptedPeer {
  _ScriptedPeer._(this._server);

  final ServerSocket _server;
  Socket? _client;
  final List<AmqpDescribed> received = [];
  final List<AmqpMessage> cbsRequests = [];
  final BytesBuilder _buffer = BytesBuilder();
  bool _header = true;
  final Map<int, int> peerHandleOf = {};

  /// Each link's address at the peer, by the client's handle.
  final Map<int, String> addressOf = {};

  /// The status the peer answers a `put-token` with.
  int cbsStatus = 200;

  /// The handle the peer gives its first link; later ones count up from it.
  int peerHandleBase = 7;

  static Future<_ScriptedPeer> start() async {
    final peer = _ScriptedPeer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    peer._server.listen(peer._accept);
    return peer;
  }

  int get port => _server.port;

  void _accept(Socket client) {
    _client = client;
    client.listen(_onData, onError: (Object _) {});
  }

  void _send(int type, AmqpDescribed body, [Uint8List? payload]) {
    final encoded = amqpEncode(body);
    final header = ByteData(8)
      ..setUint32(0, 8 + encoded.length + (payload?.length ?? 0))
      ..setUint8(4, 2)
      ..setUint8(5, type);
    _client!
      ..add(header.buffer.asUint8List())
      ..add(encoded);
    if (payload != null) _client!.add(payload);
  }

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    var offset = 0;
    while (true) {
      if (_header) {
        if (bytes.length - offset < 8) break;
        final sasl = bytes[offset + 4] == 3;
        offset += 8;
        _header = false;
        _client!.add([0x41, 0x4d, 0x51, 0x50, sasl ? 3 : 0, 1, 0, 0]);
        if (sasl) {
          _send(
            1,
            const AmqpDescribed(AmqpUlong(0x40), [
              AmqpArray('symbol', [AmqpSymbol('PLAIN')]),
            ]),
          );
        }
        continue;
      }
      if (bytes.length - offset < 8) break;
      final size = ByteData.sublistView(bytes, offset).getUint32(0);
      if (bytes.length - offset < size) break;
      final reader = AmqpReader(
        Uint8List.fromList(bytes.sublist(offset + 8, offset + size)),
      );
      offset += size;
      if (reader.isAtEnd) continue;
      final body = reader.read()! as AmqpDescribed;
      received.add(body);
      _answer(body, Uint8List.sublistView(reader.bytes, reader.offset));
    }
    if (offset < bytes.length) _buffer.add(bytes.sublist(offset));
    bytes = Uint8List(0);
  }

  void _answer(AmqpDescribed body, Uint8List payload) {
    final fields = body.value! as List<Object?>;
    switch (body.code) {
      case 0x41: // sasl-init
        _send(1, const AmqpDescribed(AmqpUlong(0x44), [AmqpUbyte(0)]));
        _header = true;
      case 0x10: // open
        _send(0, const AmqpDescribed(AmqpUlong(0x10), ['peer']));
      case 0x11: // begin
        _send(
          0,
          const AmqpDescribed(AmqpUlong(0x11), [
            AmqpUshort(0),
            AmqpUint(0),
            AmqpUint(5000),
            AmqpUint(5000),
          ]),
        );
      case 0x12: // attach: answered under a handle of the peer's own
        final ours = (fields[1]! as AmqpUint).value;
        final theirs = peerHandleBase + peerHandleOf.length;
        peerHandleOf[ours] = theirs;
        final role = fields[2] == true;
        final terminus = (role ? fields[5] : fields[6])! as AmqpDescribed;
        addressOf[ours] = (terminus.value! as List)[0]! as String;
        _send(
          0,
          AmqpDescribed(const AmqpUlong(0x12), [
            fields[0],
            AmqpUint(theirs),
            !role,
            fields[3],
            fields[4],
            fields[5],
            fields[6],
          ]),
        );
        if (!role) {
          // A sender: give it credit, under the peer's handle.
          _send(
            0,
            AmqpDescribed(const AmqpUlong(0x13), [
              const AmqpUint(0),
              const AmqpUint(5000),
              const AmqpUint(0),
              const AmqpUint(5000),
              AmqpUint(theirs),
              const AmqpUint(0),
              const AmqpUint(10),
            ]),
          );
        }
      case 0x13: // flow: a receiver's credit — send it one message
        final handle = fields.length > 4 ? fields[4] : null;
        if (handle is! AmqpUint) return;
        if (addressOf[handle.value] == r'$cbs') return;
        _send(
          0,
          AmqpDescribed(const AmqpUlong(0x14), [
            AmqpUint(peerHandleOf[handle.value]!),
            const AmqpUint(0),
            Uint8List.fromList([1]),
            const AmqpUint(0),
            false,
          ]),
          AmqpMessage(
            data: Uint8List.fromList(utf8.encode('from the peer')),
            messageId: 'p-1',
            deliveryCount: 2,
          ).encode(),
        );
      case 0x14: // transfer: accept it; a put-token is answered on $cbs
        final ours = (fields[0]! as AmqpUint).value;
        if (addressOf[ours] == r'$cbs') {
          final request = AmqpMessage.decode(payload);
          final reply = addressOf.entries
              .firstWhere((e) => e.value == r'$cbs' && e.key != ours)
              .key;
          _send(
            0,
            AmqpDescribed(const AmqpUlong(0x14), [
              AmqpUint(peerHandleOf[reply]!),
              const AmqpUint(1),
              Uint8List.fromList([2]),
              const AmqpUint(0),
              false,
            ]),
            AmqpMessage(
              value: null,
              correlationId: request.messageId,
              applicationProperties: {
                'status-code': cbsStatus,
                'status-description': cbsStatus == 200 ? 'OK' : 'Unauthorized',
              },
            ).encode(),
          );
          cbsRequests.add(request);
        }
        _send(
          0,
          AmqpDescribed(const AmqpUlong(0x15), [
            true,
            fields[1],
            fields[1],
            true,
            const AmqpAccepted().encoded,
          ]),
        );
      case 0x16: // detach
        final ours = (fields[0]! as AmqpUint).value;
        _send(
          0,
          AmqpDescribed(const AmqpUlong(0x16), [
            AmqpUint(peerHandleOf[ours]!),
            true,
          ]),
        );
      case 0x17: // end
        _send(0, const AmqpDescribed(AmqpUlong(0x17), []));
      case 0x18: // close
        _send(0, const AmqpDescribed(AmqpUlong(0x18), []));
    }
  }

  Future<void> close() async {
    await _client?.close();
    await _server.close();
  }
}

void main() {
  late _ScriptedPeer peer;

  setUp(() async => peer = await _ScriptedPeer.start());
  tearDown(() => peer.close());

  Future<AmqpConnection> connect() => AmqpConnection.connect(
    '127.0.0.1',
    peer.port,
    sasl: const AmqpSasl.plain('user', 'secret'),
    timeout: const Duration(seconds: 5),
  );

  test('ZB-U11: SASL PLAIN, open and begin, and a send the peer accepts '
      'under a handle of its own', () async {
    final connection = await connect();
    addTearDown(connection.close);
    final sasl = peer.received.firstWhere((b) => b.code == 0x41);
    final initial = (sasl.value! as List)[1] as Uint8List;
    expect(utf8.decode(initial), '\u0000user\u0000secret');

    final sender = await connection.attachSender('topic');
    final outcome = await sender
        .send(AmqpMessage(value: 'hello', messageId: 'm-1'))
        .timeout(const Duration(seconds: 5));
    expect((outcome! as AmqpDescribed).code, AmqpCodes.accepted);
    expect(peer.peerHandleOf, {0: 7});
  });

  test('ZB-U12: a link attached after another was detached gets its credit '
      'and its deliveries by the peer\'s handle, not by its own', () async {
    final connection = await connect();
    addTearDown(connection.close);
    final first = await connection.attachReceiver('queue');
    await first.close();
    peer.peerHandleBase = 0; // the peer reuses its handle 0 from here on
    peer.peerHandleOf.clear();
    final sender = await connection.attachSender('topic');
    // Our handle 1 is the peer's 0; the credit arrives under 0.
    expect(peer.peerHandleOf, {1: 0});
    final outcome = await sender
        .send(AmqpMessage(value: 'after a detach'))
        .timeout(const Duration(seconds: 5));
    expect((outcome! as AmqpDescribed).code, AmqpCodes.accepted);

    final receiver = await connection.attachReceiver('queue');
    final delivery = receiver.deliveries.first;
    receiver.grant(1);
    final got = await delivery.timeout(const Duration(seconds: 5));
    expect(utf8.decode(got.message.data!), 'from the peer');
    expect(got.message.deliveryCount, 2);
    got.settle(const AmqpAccepted());
    for (var i = 0; i < 100 && !peer.received.any((b) => b.code == 0x15); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final disposition = peer.received.lastWhere((b) => b.code == 0x15);
    expect(
      ((disposition.value! as List)[4]! as AmqpDescribed).code,
      AmqpCodes.accepted,
    );
  });

  test('ZB-U13: a token put on \$cbs is answered by the peer, and a refused '
      'one fails with its status', () async {
    final connection = await connect();
    addTearDown(connection.close);
    await connection
        .putToken(
          audience: 'sb://ns/topic',
          token: 'the-token',
          type: 'jwt',
          expiresAt: DateTime.utc(2026, 11, 7, 12),
        )
        .timeout(const Duration(seconds: 5));
    final request = peer.cbsRequests.single;
    expect(request.value, 'the-token');
    expect(request.applicationProperties, {
      'operation': 'put-token',
      'type': 'jwt',
      'name': 'sb://ns/topic',
      'expiration': DateTime.utc(2026, 11, 7, 12),
    });
    expect(request.replyTo, isNotNull);

    peer.cbsStatus = 401;
    await expectLater(
      connection.putToken(
        audience: 'sb://ns/other',
        token: 'stale',
        type: 'jwt',
      ),
      throwsA(
        isA<AmqpException>().having(
          (e) => e.condition,
          'condition',
          'amqp:unauthorized-access',
        ),
      ),
    );
  });
}

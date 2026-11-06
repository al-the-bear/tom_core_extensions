/// An AMQP 1.0 client connection (OASIS AMQP 1.0, part 2 and part 5): the
/// frames, SASL, one session, and sending and receiving links.
///
/// Deliberately the part of the protocol a message bus needs and nothing more:
/// one session per connection, links that send unsettled and settle on the
/// peer's outcome, receivers that grant credit and settle each delivery with an
/// outcome, SASL `PLAIN` and `ANONYMOUS`, heartbeats against the peer's idle
/// timeout. No transactions, no link recovery, no multiplexed sessions.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'amqp_message.dart';
import 'amqp_types.dart';

/// The performative codes of the connection, session and link frames.
abstract final class AmqpPerformative {
  /// `open`.
  static const open = 0x10;

  /// `begin`.
  static const begin = 0x11;

  /// `attach`.
  static const attach = 0x12;

  /// `flow`.
  static const flow = 0x13;

  /// `transfer`.
  static const transfer = 0x14;

  /// `disposition`.
  static const disposition = 0x15;

  /// `detach`.
  static const detach = 0x16;

  /// `end`.
  static const end = 0x17;

  /// `close`.
  static const close = 0x18;

  /// `sasl-mechanisms`.
  static const saslMechanisms = 0x40;

  /// `sasl-init`.
  static const saslInit = 0x41;

  /// `sasl-outcome`.
  static const saslOutcome = 0x44;

  /// `source`.
  static const source = 0x28;

  /// `target`.
  static const target = 0x29;
}

/// A failure of an AMQP connection, session or link: the peer's error
/// [condition] and [description], or a local one.
class AmqpException implements Exception {
  /// A failure saying [description] under [condition].
  const AmqpException(this.condition, this.description);

  /// The error condition, e.g. `amqp:not-found`.
  final String condition;

  /// What went wrong.
  final String description;

  @override
  String toString() => 'AmqpException($condition): $description';

  /// The error an AMQP `error` value [value] carries, or `null`.
  static AmqpException? of(Object? value) {
    if (value is! AmqpDescribed || value.value is! List) return null;
    final fields = value.value! as List<Object?>;
    final condition = fields.isEmpty ? null : fields[0];
    final description = fields.length > 1 ? fields[1] : null;
    return AmqpException(
      condition is AmqpSymbol ? condition.name : '$condition',
      description is String ? description : '',
    );
  }
}

/// How a connection authenticates in SASL.
sealed class AmqpSasl {
  const AmqpSasl();

  /// `PLAIN` with [username] and [password].
  const factory AmqpSasl.plain(String username, String password) = _SaslPlain;

  /// `ANONYMOUS`.
  const factory AmqpSasl.anonymous() = _SaslAnonymous;

  String get _mechanism;

  Uint8List? get _initialResponse;
}

final class _SaslPlain extends AmqpSasl {
  const _SaslPlain(this.username, this.password);

  final String username;
  final String password;

  @override
  String get _mechanism => 'PLAIN';

  @override
  Uint8List get _initialResponse => Uint8List.fromList([
    0,
    ...utf8.encode(username),
    0,
    ...utf8.encode(password),
  ]);
}

final class _SaslAnonymous extends AmqpSasl {
  const _SaslAnonymous();

  @override
  String get _mechanism => 'ANONYMOUS';

  @override
  Uint8List? get _initialResponse => null;
}

/// One frame read from the wire: its [type] (0 AMQP, 1 SASL), [channel], the
/// performative [body] and the [payload] after it.
class _Frame {
  _Frame(this.type, this.channel, this.body, this.payload);

  final int type;
  final int channel;
  final AmqpDescribed? body;
  final Uint8List payload;
}

/// An open AMQP connection with one session.
///
/// [connect] opens the socket, authenticates, exchanges `open` and begins the
/// session; [attachSender] and [attachReceiver] attach links on it; [close]
/// ends the session and closes the connection. A connection the peer closes,
/// or whose socket fails, fails every pending operation and every link with
/// the cause, and [done] completes.
class AmqpConnection {
  AmqpConnection._(this._socket, this.containerId, this.hostname);

  final Socket _socket;

  /// The container id this side announced.
  final String containerId;

  /// The host name announced in `open`.
  final String hostname;

  /// Told of every frame sent (`>> `) and received (`<< `), when set — a
  /// debugging aid.
  static void Function(String frame)? frameLog;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final Map<int, AmqpLink> _links = {};

  /// The links by the handle the peer gave them: incoming frames name the
  /// peer's handle, which need not be this side's.
  final Map<int, AmqpLink> _remote = {};
  final Map<int, Completer<void>> _peerDetached = {};
  final Map<String, Completer<AmqpLink>> _attaching = {};
  final Completer<void> _done = Completer<void>();
  Completer<_Frame>? _awaitingFrame;
  final List<_Frame> _early = [];
  bool _saslPhase = true;
  bool _opened = false;
  bool _headerPending = true;
  Timer? _heartbeat;
  int _nextHandle = 0;
  int _nextOutgoingId = 0;
  int _nextDeliveryId = 0;
  int _maxFrameSize = 65536;
  Object? _failure;
  bool _closing = false;

  /// Completes when the connection has ended, with the failure that ended it
  /// as an error, if any.
  Future<void> get done => _done.future;

  /// Whether the connection is open.
  bool get isOpen => _failure == null && !_closing;

  /// Opens a connection to [host]:[port] — over TLS when [secure] — and
  /// authenticates with [sasl].
  static Future<AmqpConnection> connect(
    String host,
    int port, {
    required AmqpSasl sasl,
    bool secure = false,
    String? hostname,
    String? containerId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final socket = secure
        ? await SecureSocket.connect(host, port, timeout: timeout)
        : await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final connection = AmqpConnection._(
      socket,
      containerId ?? 'tom-${DateTime.now().microsecondsSinceEpoch}',
      hostname ?? host,
    );
    try {
      await connection._open(sasl).timeout(timeout);
    } on Object {
      await socket.close().catchError((_) {});
      socket.destroy();
      rethrow;
    }
    return connection;
  }

  Future<void> _open(AmqpSasl sasl) async {
    _socket.listen(
      _onData,
      onError: (Object error) => _fail(error),
      onDone: () => _fail(
        const AmqpException('amqp:connection:forced', 'The socket closed.'),
      ),
      cancelOnError: true,
    );
    // SASL: header, mechanisms, init, outcome.
    _socket.add(const [0x41, 0x4d, 0x51, 0x50, 3, 1, 0, 0]);
    final mechanisms = await _nextFrame();
    if (mechanisms.body?.code != AmqpPerformative.saslMechanisms) {
      throw AmqpException(
        'amqp:not-implemented',
        'Expected sasl-mechanisms, got ${mechanisms.body}.',
      );
    }
    _send(
      1,
      0,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.saslInit), [
        AmqpSymbol(sasl._mechanism),
        sasl._initialResponse,
        hostname,
      ]),
    );
    final outcome = await _nextFrame();
    final code = (outcome.body?.value as List?)?.firstOrNull;
    if (outcome.body?.code != AmqpPerformative.saslOutcome ||
        code is! AmqpUbyte ||
        code.value != 0) {
      throw AmqpException(
        'amqp:unauthorized-access',
        'SASL ${sasl._mechanism} was refused (code $code).',
      );
    }
    _saslPhase = false;
    _headerPending = true;
    _socket.add(const [0x41, 0x4d, 0x51, 0x50, 0, 1, 0, 0]);
    _send(
      0,
      0,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.open), [
        containerId,
        hostname,
        AmqpUint(_maxFrameSize),
        const AmqpUshort(0),
        const AmqpUint(120000),
      ]),
    );
    final open = await _nextFrame();
    if (open.body?.code != AmqpPerformative.open) {
      throw AmqpException(
        'amqp:not-implemented',
        'Expected open, got ${open.body}.',
      );
    }
    final fields = open.body!.value! as List<Object?>;
    final peerFrame = fields.length > 2 ? fields[2] : null;
    if (peerFrame is AmqpUint && peerFrame.value < _maxFrameSize) {
      _maxFrameSize = peerFrame.value;
    }
    final idle = fields.length > 4 ? fields[4] : null;
    if (idle is AmqpUint && idle.value > 0) {
      final every = Duration(milliseconds: idle.value ~/ 2);
      _heartbeat = Timer.periodic(every, (_) {
        if (isOpen) _socket.add(const [0, 0, 0, 8, 2, 0, 0, 0]);
      });
    }
    _send(
      0,
      0,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.begin), [
        null,
        const AmqpUint(0),
        const AmqpUint(0x7fffffff),
        const AmqpUint(0x7fffffff),
        const AmqpUint(0xffff),
      ]),
    );
    final begin = await _nextFrame();
    if (begin.body?.code != AmqpPerformative.begin) {
      throw AmqpException(
        'amqp:not-implemented',
        'Expected begin, got ${begin.body}.',
      );
    }
    _opened = true;
  }

  /// The next frame while the connection is being opened.
  Future<_Frame> _nextFrame() {
    if (_early.isNotEmpty) return Future.value(_early.removeAt(0));
    if (_failure != null) return Future.error(_failure!);
    return (_awaitingFrame = Completer<_Frame>()).future;
  }

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    final bytes = _buffer.takeBytes();
    var offset = 0;
    if (_headerPending) {
      if (bytes.length < 8) {
        _buffer.add(bytes);
        return;
      }
      offset = 8;
      _headerPending = false;
    }
    while (bytes.length - offset >= 8) {
      final data = ByteData.sublistView(bytes, offset);
      final size = data.getUint32(0);
      if (bytes.length - offset < size) break;
      final doff = bytes[offset + 4] * 4;
      final type = bytes[offset + 5];
      final channel = data.getUint16(6);
      final frame = Uint8List.sublistView(bytes, offset + doff, offset + size);
      offset += size;
      if (frame.isEmpty) continue; // A heartbeat.
      final reader = AmqpReader(Uint8List.fromList(frame));
      final body = reader.read();
      final payload = Uint8List.sublistView(reader.bytes, reader.offset);
      _onFrame(
        _Frame(type, channel, body is AmqpDescribed ? body : null, payload),
      );
      if (_saslPhase &&
          body is AmqpDescribed &&
          body.code == AmqpPerformative.saslOutcome) {
        // The AMQP header that follows a successful outcome is read as the
        // next protocol header, not as a frame.
        _headerPending = true;
        if (bytes.length - offset >= 8) {
          offset += 8;
          _headerPending = false;
        }
      }
    }
    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
  }

  void _onFrame(_Frame frame) {
    frameLog?.call('<< ${frame.body}');
    final pending = _awaitingFrame;
    final code = frame.body?.code;
    final fields = (frame.body?.value as List?) ?? const <Object?>[];
    if (pending != null) {
      _awaitingFrame = null;
      pending.complete(frame);
      return;
    }
    if (!_opened) {
      _early.add(frame);
      return;
    }
    switch (code) {
      case AmqpPerformative.attach:
        final name = fields[0] as String;
        final waiting = _attaching.remove(name);
        final link = _links.values.where((l) => l.name == name).firstOrNull;
        if (link == null) return;
        final source = fields.length > 5 ? fields[5] : null;
        final target = fields.length > 6 ? fields[6] : null;
        _remote[(fields[1] as AmqpUint).value] = link;
        if ((link.isReceiver && source == null) ||
            (!link.isReceiver && target == null)) {
          // A refused attach: the detach that follows carries the error.
          return;
        }
        waiting?.complete(link);
      case AmqpPerformative.flow:
        final handle = fields.length > 4 ? fields[4] : null;
        if (handle is! AmqpUint) return;
        final link = _remote[handle.value];
        if (link is AmqpSender) link._onFlow(fields);
      case AmqpPerformative.transfer:
        final handle = fields[0] as AmqpUint;
        final link = _remote[handle.value];
        if (link is AmqpReceiver) link._onTransfer(fields, frame.payload);
      case AmqpPerformative.disposition:
        _onDisposition(fields);
      case AmqpPerformative.detach:
        final handle = fields[0] as AmqpUint;
        final link = _remote.remove(handle.value);
        if (link == null) return;
        final answered = _peerDetached[link.handle];
        if (answered != null && !answered.isCompleted) answered.complete();
        _links.remove(link.handle);
        final error =
            AmqpException.of(fields.length > 2 ? fields[2] : null) ??
            const AmqpException('amqp:link:detach-forced', 'Detached.');
        final waiting = _attaching.remove(link.name);
        if (waiting != null && !waiting.isCompleted) {
          waiting.completeError(error);
        }
        link._onDetached(error);
        if (!link._detachSent) {
          link._detachSent = true;
          _send(
            0,
            0,
            AmqpDescribed(const AmqpUlong(AmqpPerformative.detach), [
              AmqpUint(link.handle),
              true,
            ]),
          );
        }
      case AmqpPerformative.end:
      case AmqpPerformative.close:
        _fail(
          AmqpException.of(fields.isEmpty ? null : fields[0]) ??
              const AmqpException('amqp:connection:forced', 'Closed by peer.'),
        );
      default:
        break;
    }
  }

  void _onDisposition(List<Object?> fields) {
    final role = fields[0] == true; // true: the receiver settled.
    final first = (fields[1] as AmqpUint).value;
    final last = fields.length > 2 && fields[2] is AmqpUint
        ? (fields[2] as AmqpUint).value
        : first;
    final state = fields.length > 4 ? fields[4] : null;
    if (!role) return;
    for (final link in _links.values.whereType<AmqpSender>()) {
      link._onSettled(first, last, state);
    }
  }

  void _fail(Object error) {
    if (_failure != null) return;
    _failure = error;
    _heartbeat?.cancel();
    final pending = _awaitingFrame;
    _awaitingFrame = null;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
    for (final waiting in _attaching.values) {
      if (!waiting.isCompleted) waiting.completeError(error);
    }
    _attaching.clear();
    for (final link in List.of(_links.values)) {
      link._onDetached(error);
    }
    _links.clear();
    _socket.destroy();
    if (!_done.isCompleted) {
      if (_closing) {
        _done.complete();
      } else {
        _done.completeError(error);
        // The connection's owner reads [done]; an unobserved failure must not
        // surface as an uncaught error.
        _done.future.catchError((_) {});
      }
    }
  }

  void _send(int type, int channel, AmqpDescribed body, [Uint8List? payload]) {
    frameLog?.call('>> $body');
    if (_failure != null) throw _failure!;
    final encoded = amqpEncode(body);
    final size = 8 + encoded.length + (payload?.length ?? 0);
    final header = ByteData(8)
      ..setUint32(0, size)
      ..setUint8(4, 2)
      ..setUint8(5, type)
      ..setUint16(6, channel);
    _socket.add(header.buffer.asUint8List());
    _socket.add(encoded);
    if (payload != null) _socket.add(payload);
  }

  void _requireOpen() {
    if (_failure != null) throw _failure!;
    if (_closing) {
      throw const AmqpException('amqp:connection:forced', 'Closed.');
    }
  }

  Future<T> _attach<T extends AmqpLink>(T link, AmqpDescribed attach) {
    _requireOpen();
    _links[link.handle] = link;
    final waiting = _attaching[link.name] = Completer<AmqpLink>();
    _send(0, 0, attach);
    return waiting.future.then((value) => value as T);
  }

  /// Attaches a link sending to [address]: messages are sent unsettled, and
  /// [AmqpSender.send] completes with the peer's outcome.
  Future<AmqpSender> attachSender(
    String address, {
    String? name,
    Map<AmqpSymbol, Object?>? properties,
  }) {
    final handle = _nextHandle++;
    final linkName = name ?? '$containerId-sender-$handle';
    final sender = AmqpSender._(this, linkName, handle, address);
    return _attach(
      sender,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.attach), [
        linkName,
        AmqpUint(handle),
        false,
        const AmqpUbyte(0), // snd-settle-mode: unsettled
        const AmqpUbyte(0), // rcv-settle-mode: first
        AmqpDescribed(const AmqpUlong(AmqpPerformative.source), [
          '$containerId-$handle',
        ]),
        AmqpDescribed(const AmqpUlong(AmqpPerformative.target), [address]),
        null,
        null,
        const AmqpUint(0),
        null,
        null,
        null,
        properties,
      ]),
    );
  }

  /// Attaches a link receiving from [address]. [target] names this side's
  /// terminus (a reply address); deliveries arrive unsettled, one per credit
  /// the receiver grants, and are settled with an [AmqpOutcome].
  Future<AmqpReceiver> attachReceiver(
    String address, {
    String? name,
    String? target,
    Map<AmqpSymbol, Object?>? filter,
    Map<AmqpSymbol, Object?>? properties,
  }) {
    final handle = _nextHandle++;
    final linkName = name ?? '$containerId-receiver-$handle';
    final receiver = AmqpReceiver._(this, linkName, handle, address);
    return _attach(
      receiver,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.attach), [
        linkName,
        AmqpUint(handle),
        true,
        const AmqpUbyte(0), // snd-settle-mode: unsettled
        const AmqpUbyte(0), // rcv-settle-mode: first
        AmqpDescribed(const AmqpUlong(AmqpPerformative.source), [
          address,
          null,
          null,
          null,
          null,
          null,
          null,
          filter,
        ]),
        AmqpDescribed(const AmqpUlong(AmqpPerformative.target), [
          target ?? '$containerId-$handle',
        ]),
        null,
        null,
        null,
        null,
        null,
        null,
        properties,
      ]),
    );
  }

  int _transfer(AmqpSender link, Uint8List message, int deliveryTag) {
    final id = _nextDeliveryId++;
    final tag = ByteData(8)..setUint64(0, deliveryTag);
    final room = _maxFrameSize - 256;
    var offset = 0;
    do {
      final end = (offset + room < message.length)
          ? offset + room
          : message.length;
      final first = offset == 0;
      final more = end < message.length;
      _send(
        0,
        0,
        AmqpDescribed(const AmqpUlong(AmqpPerformative.transfer), [
          AmqpUint(link.handle),
          if (first) AmqpUint(id) else null,
          if (first) tag.buffer.asUint8List() else null,
          if (first) const AmqpUint(0) else null,
          false,
          more,
        ]),
        Uint8List.sublistView(message, offset, end),
      );
      offset = end;
    } while (offset < message.length);
    _nextOutgoingId++;
    return id;
  }

  void _flow(AmqpReceiver link) {
    _send(
      0,
      0,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.flow), [
        AmqpUint(link._nextIncomingId),
        const AmqpUint(0x7fffffff),
        AmqpUint(_nextOutgoingId),
        const AmqpUint(0x7fffffff),
        AmqpUint(link.handle),
        AmqpUint(link._deliveryCount),
        AmqpUint(link._credit),
      ]),
    );
  }

  void _settle(int deliveryId, AmqpOutcome outcome) {
    _send(
      0,
      0,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.disposition), [
        true,
        AmqpUint(deliveryId),
        AmqpUint(deliveryId),
        true,
        outcome.encoded,
      ]),
    );
  }

  Future<void> _detach(AmqpLink link) async {
    if (_failure != null || !_links.containsKey(link.handle)) return;
    link._detachSent = true;
    _peerDetached[link.handle] = Completer<void>();
    _send(
      0,
      0,
      AmqpDescribed(const AmqpUlong(AmqpPerformative.detach), [
        AmqpUint(link.handle),
        true,
      ]),
    );
    // The link ends here, whatever the peer does: its deliveries stop now, and
    // the peer's answering detach is awaited only for so long.
    link._onDetached(
      const AmqpException('amqp:link:detach-forced', 'Detached by this side.'),
    );
    await _peerDetached[link.handle]?.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
    _links.remove(link.handle);
    _peerDetached.remove(link.handle);
  }

  /// Ends the session and closes the connection.
  Future<void> close() async {
    if (_closing || _failure != null) return;
    _closing = true;
    _heartbeat?.cancel();
    try {
      _send(0, 0, const AmqpDescribed(AmqpUlong(AmqpPerformative.end), []));
      _send(0, 0, const AmqpDescribed(AmqpUlong(AmqpPerformative.close), []));
      await _done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    } on Object {
      // Closed already.
    }
    _fail(const AmqpException('amqp:connection:forced', 'Closed.'));
    await _socket.close().catchError((_) => null);
  }
}

/// A link attached on an [AmqpConnection].
sealed class AmqpLink {
  AmqpLink._(this._connection, this.name, this.handle, this.address);

  final AmqpConnection _connection;

  /// The link name.
  final String name;

  /// The link handle.
  final int handle;

  /// The address at the peer.
  final String address;

  /// Whether this link receives (it sends otherwise).
  bool get isReceiver;

  bool _detachSent = false;
  final Completer<AmqpException> _detached = Completer<AmqpException>();

  /// Completes with the error the link was detached with.
  Future<AmqpException> get detached => _detached.future;

  /// Whether the link is attached.
  bool get isAttached => !_detached.isCompleted;

  void _onDetached(Object error) {
    if (_detached.isCompleted) return;
    _detached.complete(
      error is AmqpException
          ? error
          : AmqpException('amqp:link:detach-forced', '$error'),
    );
  }

  /// Detaches the link.
  Future<void> close() => _connection._detach(this);
}

/// A link sending messages.
final class AmqpSender extends AmqpLink {
  AmqpSender._(super.connection, super.name, super.handle, super.address)
    : super._();

  @override
  bool get isReceiver => false;

  int _credit = 0;
  int _deliveryCount = 0;
  int _tags = 0;
  final Map<int, Completer<Object?>> _unsettled = {};
  final List<Completer<void>> _waitingForCredit = [];

  void _onFlow(List<Object?> fields) {
    final count = fields.length > 5 ? fields[5] : null;
    final credit = fields.length > 6 ? fields[6] : null;
    if (credit is! AmqpUint) return;
    final peerCount = count is AmqpUint ? count.value : _deliveryCount;
    _credit = peerCount + credit.value - _deliveryCount;
    while (_credit > 0 && _waitingForCredit.isNotEmpty) {
      _waitingForCredit.removeAt(0).complete();
      _credit--;
    }
  }

  void _onSettled(int first, int last, Object? state) {
    for (var id = first; id <= last; id++) {
      final waiting = _unsettled.remove(id);
      if (waiting == null || waiting.isCompleted) continue;
      if (state is AmqpDescribed && state.code == AmqpCodes.rejected) {
        final fields = state.value as List?;
        waiting.completeError(
          AmqpException.of(
                fields == null || fields.isEmpty ? null : fields[0],
              ) ??
              const AmqpException('amqp:rejected', 'The message was rejected.'),
        );
      } else {
        waiting.complete(state);
      }
    }
  }

  @override
  void _onDetached(Object error) {
    super._onDetached(error);
    for (final waiting in _unsettled.values) {
      if (!waiting.isCompleted) waiting.completeError(error);
    }
    _unsettled.clear();
    for (final waiting in _waitingForCredit) {
      if (!waiting.isCompleted) waiting.completeError(error);
    }
    _waitingForCredit.clear();
  }

  /// Sends [message] and completes with the peer's outcome (the `state` of
  /// its disposition); a rejection or a detach completes it with an
  /// [AmqpException].
  Future<Object?> send(AmqpMessage message) async {
    if (!isAttached) throw await detached;
    if (_credit > 0) {
      _credit--;
    } else {
      final waiting = Completer<void>();
      _waitingForCredit.add(waiting);
      await waiting.future;
    }
    _deliveryCount++;
    final settled = Completer<Object?>();
    final id = _connection._transfer(this, message.encode(), _tags++);
    _unsettled[id] = settled;
    return settled.future;
  }
}

/// One message a receiver was given, to be settled with an [AmqpOutcome].
class AmqpDelivery {
  AmqpDelivery._(this._receiver, this.deliveryId, this.message);

  final AmqpReceiver _receiver;

  /// The delivery id within the session.
  final int deliveryId;

  /// The message.
  final AmqpMessage message;

  bool _settled = false;

  /// Settles the delivery with [outcome]; a second call does nothing.
  void settle(AmqpOutcome outcome) {
    if (_settled || !_receiver.isAttached) return;
    _settled = true;
    _receiver._connection._settle(deliveryId, outcome);
  }
}

/// A link receiving messages.
final class AmqpReceiver extends AmqpLink {
  AmqpReceiver._(super.connection, super.name, super.handle, super.address)
    : super._();

  @override
  bool get isReceiver => true;

  int _credit = 0;
  int _deliveryCount = 0;
  int _nextIncomingId = 0;
  int? _partialId;
  BytesBuilder? _partial;
  final StreamController<AmqpDelivery> _deliveries =
      StreamController<AmqpDelivery>();

  /// The deliveries, in the order they arrive.
  Stream<AmqpDelivery> get deliveries => _deliveries.stream;

  /// Grants the sender [credit] more messages.
  void grant(int credit) {
    _credit += credit;
    _connection._flow(this);
  }

  void _onTransfer(List<Object?> fields, Uint8List payload) {
    final id = fields.length > 1 ? fields[1] : null;
    final more = fields.length > 5 && fields[5] == true;
    if (id is AmqpUint) {
      _partialId = id.value;
      _partial = BytesBuilder(copy: true);
    }
    _partial?.add(payload);
    if (more) return;
    final bytes = _partial!.takeBytes();
    final deliveryId = _partialId!;
    _partial = null;
    _nextIncomingId = deliveryId + 1;
    _deliveryCount++;
    if (_credit > 0) _credit--;
    _deliveries.add(
      AmqpDelivery._(this, deliveryId, AmqpMessage.decode(bytes)),
    );
  }

  @override
  void _onDetached(Object error) {
    super._onDetached(error);
    if (!_deliveries.isClosed) {
      _deliveries.addError(error);
      unawaited(_deliveries.close());
    }
  }
}

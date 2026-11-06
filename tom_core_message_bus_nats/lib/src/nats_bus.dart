/// The NATS JetStream adapter of the Tom message bus.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_nats/dart_nats.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';

/// A [TomMessageBus] over a NATS server with JetStream.
///
/// ## How the contract maps onto JetStream
///
/// | Contract | JetStream |
/// | -------- | --------- |
/// | A topic | A stream of its own, `TOMBUS_<topic>_<hash>`, holding the subject `<subjectPrefix>.<topic>` |
/// | A consumer group | A durable pull consumer of that stream, created with the deliver policy `new` |
/// | Consumers of a group | Pull loops on the same durable consumer, each fetching one message at a time |
/// | Acknowledge | `+ACK` |
/// | Reject, redelivered | `-NAK`: the server delivers it again at once |
/// | Dead letter | Published to `<topic>.dlq`, then `+TERM`ed on the topic |
/// | The attempt | The delivered count of the JetStream reply subject |
/// | Message id | `Nats-Msg-Id`, so the server drops a repeated publish within its duplicate window |
///
/// A group created by its first subscription receives the messages published
/// after it — the deliver policy `new` — and keeps them while none of its
/// consumers is subscribed: the durable consumer remembers its position.
/// Messages are retained in a stream for [retention], a week by default.
/// Ordering per key is not declared: a NAK redelivers one message while the
/// next is already with another consumer.
///
/// The message travels as JSON in the NATS payload; its id, key and
/// publication time travel in NATS headers (`Tom-Bus-*`) beside the
/// message's own.
class TomNatsMessageBus implements TomMessageBus {
  /// A bus over [client], connected to a NATS server with JetStream.
  ///
  /// [subjectPrefix] prefixes every subject the bus publishes to; [retention]
  /// is how long a stream keeps a message; [fetchWait] is how long one pull
  /// waits for a message before the consumer asks again — and so the longest a
  /// [TomBusSubscription.cancel] waits. With [ownsClient] the bus closes
  /// [client] on [close].
  TomNatsMessageBus(
    this.client, {
    this.subjectPrefix = 'tombus',
    this.retention = const Duration(days: 7),
    this.fetchWait = const Duration(milliseconds: 500),
    this.ownsClient = false,
    DateTime Function()? clock,
  }) : _js = JetStream(client),
       _clock = clock ?? DateTime.now;

  /// Connects to the NATS server at [uri] and answers a bus owning the
  /// connection. Throws `message_bus.nats.unreachable` when the server cannot
  /// be reached.
  static Future<TomNatsMessageBus> connect(
    Uri uri, {
    String subjectPrefix = 'tombus',
    Duration retention = const Duration(days: 7),
    Duration fetchWait = const Duration(milliseconds: 500),
  }) async {
    final client = Client();
    try {
      await client.connect(uri, retry: false, timeout: 5);
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.nats.unreachable',
        'The NATS server at $uri could not be reached: $error',
        parameters: {'uri': '$uri'},
        rootException: error,
        stack: stack,
      );
    }
    return TomNatsMessageBus(
      client,
      subjectPrefix: subjectPrefix,
      retention: retention,
      fetchWait: fetchWait,
      ownsClient: true,
    );
  }

  /// The NATS connection.
  final Client client;

  /// The first token of every subject the bus uses.
  final String subjectPrefix;

  /// How long a stream keeps a message.
  final Duration retention;

  /// How long one pull waits for a message.
  final Duration fetchWait;

  /// Whether [close] closes [client].
  final bool ownsClient;

  final JetStream _js;
  final DateTime Function() _clock;
  final Map<String, Future<String>> _streams = {};
  final Set<_NatsConsumer> _consumers = {};
  final Random _random = Random.secure();
  bool _closed = false;
  Future<void>? _closing;

  /// The headers carrying the message's own fields.
  static const String idHeader = 'Tom-Bus-Id';

  /// The ordering key, when the message has one.
  static const String keyHeader = 'Tom-Bus-Key';

  /// When the message was published, ISO 8601 in UTC.
  static const String publishedAtHeader = 'Tom-Bus-Published-At';

  static final RegExp _topicPattern = RegExp(
    r'^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)*$',
  );

  @override
  TomBusCapabilities get capabilities => const TomBusCapabilities();

  void _requireOpen() {
    if (_closed) {
      throw TomBusException(
        'message_bus.closed',
        'The message bus has been closed.',
      );
    }
  }

  /// The subject of [topic].
  String subjectOf(String topic) => validSubject(subjectPrefix, topic);

  /// `<prefix>.<topic>`, refusing (`message_bus.nats.invalid_topic`) a topic
  /// that is not a NATS subject.
  static String validSubject(String prefix, String topic) {
    if (!_topicPattern.hasMatch(topic)) {
      throw TomBusException(
        'message_bus.nats.invalid_topic',
        "The topic '$topic' is not a NATS subject: letters, digits, '_' and "
            "'-' in tokens separated by '.'.",
        parameters: {'topic': topic},
      );
    }
    return '$prefix.$topic';
  }

  /// The stream holding [topic].
  static String streamOf(String topic) =>
      'TOMBUS_${_safe(topic)}_${_hash(topic)}';

  /// The durable consumer of [group].
  static String consumerOf(String group) => '${_safe(group)}_${_hash(group)}';

  static String _safe(String name) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return safe.length > 40 ? safe.substring(0, 40) : safe;
  }

  /// FNV-1a over [name]: two names the sanitising maps alike stay apart.
  static String _hash(String name) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(name)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Creates [topic]'s stream once; answers its name.
  Future<String> _stream(String topic) {
    final subject = subjectOf(topic);
    return _streams[topic] ??= () async {
      final name = streamOf(topic);
      try {
        await _js.createOrUpdateStream(
          StreamConfig(name: name, subjects: [subject], maxAge: retention),
        );
      } on Object catch (error, stack) {
        _streams.remove(topic);
        throw TomBusException(
          'message_bus.nats.stream_failed',
          "The stream of '$topic' could not be created: $error",
          parameters: {'topic': topic, 'stream': name},
          rootException: error,
          stack: stack,
        );
      }
      return name;
    }();
  }

  String _newId() {
    final buffer = StringBuffer('msg-');
    for (var i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return '$buffer';
  }

  @override
  Future<String> publish<T>(
    String topic,
    T payload, {
    String? key,
    Map<String, String> headers = const {},
    String? id,
    TomBusCodec<T>? codec,
  }) async {
    _requireOpen();
    final json = (codec ?? TomBusCodec<T>.reflected()).encode(payload);
    final messageId = id ?? _newId();
    return TomBusTrace.publishing(topic, headers, (sent) async {
      await _send(
        TomBusMessage(
          id: messageId,
          topic: topic,
          key: key,
          payload: json,
          headers: sent,
          publishedAt: _clock(),
        ),
      );
      return messageId;
    });
  }

  /// Publishes [message] as it is, to its topic's stream.
  Future<void> _send(TomBusMessage message) async {
    await _stream(message.topic);
    final header = Header();
    message.headers.forEach(header.add);
    header
      ..add(idHeader, message.id)
      ..add(publishedAtHeader, message.publishedAt.toUtc().toIso8601String());
    if (message.key != null) header.add(keyHeader, message.key!);
    try {
      await _js.publish(
        subjectOf(message.topic),
        Uint8List.fromList(utf8.encode(jsonEncode(message.payload))),
        header: header,
        opts: PubOpts(msgId: message.id),
      );
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.nats.publish_failed',
        "The message ${message.id} could not be published to "
            "'${message.topic}': $error",
        parameters: {'topic': message.topic, 'message': message.id},
        rootException: error,
        stack: stack,
      );
    }
  }

  @override
  Future<TomBusSubscription> subscribe<T>(
    String topic, {
    required String group,
    required TomBusHandler<T> handler,
    TomBusCodec<T>? codec,
    int maxDeliveries = 5,
    bool ephemeral = false,
  }) async {
    _requireOpen();
    tomCheckSubscription(topic, group, maxDeliveries);
    final stream = await _stream(topic);
    final String name;
    try {
      name = ephemeral
          ? await _ephemeralConsumer(stream, topic, group)
          : await _durableConsumer(stream, topic, group);
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.nats.consumer_failed',
        "The consumer of group '$group' on '$topic' could not be created: "
            '$error',
        parameters: {'topic': topic, 'group': group},
        rootException: error,
        stack: stack,
      );
    }
    final effective = codec ?? TomBusCodec<T>.reflected();
    final consumer = _NatsConsumer(
      this,
      topic,
      group,
      _js.consumer<dynamic>(stream, name),
      maxDeliveries,
      (message, attempt) => tomDispatch(
        message,
        attempt: attempt,
        group: group,
        codec: effective,
        handler: handler,
      ),
    );
    if (ephemeral) {
      consumer.onLastCancel = () => _releaseEphemeral(stream, topic, group);
      _ephemeralUsers[_ephemeralKey(topic, group)] =
          (_ephemeralUsers[_ephemeralKey(topic, group)] ?? 0) + 1;
    }
    _consumers.add(consumer);
    consumer.start();
    return consumer;
  }

  /// The group's durable consumer, created if it does not exist.
  Future<String> _durableConsumer(
    String stream,
    String topic,
    String group,
  ) async {
    final durable = consumerOf(group);
    await _js.createConsumer<dynamic>(
      stream,
      ConsumerConfig(
        durable: durable,
        filterSubject: subjectOf(topic),
        deliverPolicy: 'new',
        ackPolicy: 'explicit',
      ),
    );
    return durable;
  }

  /// How long the server keeps an ephemeral group's consumer that nobody pulls
  /// from — a process that stopped without cancelling leaves it this long.
  static const Duration ephemeralInactivity = Duration(seconds: 30);

  final Map<String, Future<String>> _ephemeral = {};
  final Map<String, int> _ephemeralUsers = {};

  static String _ephemeralKey(String topic, String group) =>
      '$topic\u0000$group';

  /// The ephemeral group's consumer: one unnamed consumer per group in this
  /// bus, shared by the group's subscribers here, removed by the server after
  /// [ephemeralInactivity] without a pull.
  Future<String> _ephemeralConsumer(String stream, String topic, String group) {
    final key = _ephemeralKey(topic, group);
    return _ephemeral[key] ??= () async {
      try {
        final consumer = await _js.createConsumer<dynamic>(
          stream,
          ConsumerConfig(
            filterSubject: subjectOf(topic),
            deliverPolicy: 'new',
            ackPolicy: 'explicit',
            inactiveThreshold: ephemeralInactivity,
          ),
        );
        return consumer.name;
      } on Object {
        _ephemeral.remove(key);
        rethrow;
      }
    }();
  }

  /// The last subscriber of an ephemeral group in this bus cancelled: the
  /// group's consumer goes, and with it what waited for it.
  Future<void> _releaseEphemeral(
    String stream,
    String topic,
    String group,
  ) async {
    final key = _ephemeralKey(topic, group);
    final users = (_ephemeralUsers[key] ?? 1) - 1;
    if (users > 0) {
      _ephemeralUsers[key] = users;
      return;
    }
    _ephemeralUsers.remove(key);
    final name = await _ephemeral.remove(key);
    if (name == null) return;
    try {
      await _js.deleteConsumer(stream, name);
    } on Object catch (error) {
      // The server removes it after its inactivity threshold anyway.
      tomLog.warn(
        'The consumer of ephemeral group $group was not deleted: $error',
      );
    }
  }

  /// [received] as the message it carries.
  TomBusMessage _messageOf(String topic, Message<dynamic> received) {
    final headers = <String, String>{...?received.header?.headers};
    final id = headers.remove(idHeader) ?? '';
    final key = headers.remove(keyHeader);
    final publishedAt = headers.remove(publishedAtHeader);
    // NATS' own headers are the transport's, not the message's.
    headers.removeWhere((name, _) => name.startsWith('Nats-'));
    return TomBusMessage(
      id: id,
      topic: topic,
      key: key,
      payload: received.byte.isEmpty ? null : jsonDecode(received.string),
      headers: headers,
      publishedAt: publishedAt == null ? _clock() : DateTime.parse(publishedAt),
    );
  }

  /// The delivered count JetStream writes into a message's reply subject:
  /// `$JS.ACK.<stream>.<consumer>.<delivered>…`, or with a domain and an
  /// account hash before the stream.
  static int deliveredCount(String? replyTo) {
    final parts = (replyTo ?? '').split('.');
    if (parts.length < 9 || parts[0] != r'$JS' || parts[1] != 'ACK') return 1;
    final index = parts.length == 9 ? 4 : 6;
    return int.tryParse(parts[index]) ?? 1;
  }

  Future<void> _deadLetter(
    TomBusMessage message,
    String group,
    String reason,
    int attempts,
  ) => _send(
    tomDeadLetter(message, group: group, reason: reason, attempts: attempts),
  );

  @override
  Future<void> close() => _closing ??= _shutDown();

  Future<void> _shutDown() async {
    _closed = true;
    await Future.wait([for (final c in List.of(_consumers)) c.cancel()]);
    if (ownsClient) await client.close();
  }
}

/// One consumer of a group: a loop fetching one message at a time from the
/// group's durable consumer.
class _NatsConsumer implements TomBusSubscription {
  _NatsConsumer(
    this._bus,
    this.topic,
    this.group,
    this._consumer,
    this._maxDeliveries,
    this._handle,
  );

  final TomNatsMessageBus _bus;
  final Consumer<dynamic> _consumer;
  final int _maxDeliveries;
  final Future<(TomBusOutcome, String?)> Function(
    TomBusMessage message,
    int attempt,
  )
  _handle;

  @override
  final String topic;

  @override
  final String group;

  bool _active = true;
  Future<void>? _loop;

  /// Runs once this consumer has stopped — an ephemeral group's release.
  Future<void> Function()? onLastCancel;

  void start() => _loop = _run();

  Future<void> _run() async {
    while (_active) {
      final List<Message<dynamic>> fetched;
      try {
        fetched = await _consumer.fetch(timeout: _bus.fetchWait);
      } on Object catch (error) {
        if (!_active) return;
        tomLog.warn('Fetching from $topic for $group failed: $error');
        await Future<void>.delayed(_bus.fetchWait);
        continue;
      }
      for (final received in fetched) {
        if (!_active) {
          // Taken after the consumer was cancelled: back to the group.
          await _settle(received.nakSync);
          continue;
        }
        await _process(received);
      }
    }
  }

  Future<void> _process(Message<dynamic> received) async {
    final attempt = TomNatsMessageBus.deliveredCount(received.replyTo);
    final TomBusMessage message;
    try {
      message = _bus._messageOf(topic, received);
    } on Object {
      // Not a message of this bus: nothing could ever handle it.
      await _settle(received.termSync);
      return;
    }
    final (outcome, reason) = await _handle(message, attempt);
    switch (outcome) {
      case TomBusOutcome.acknowledged:
        await _settle(received.ackSync);
      case TomBusOutcome.deadLettered:
        await _bus._deadLetter(message, group, reason ?? 'rejected', attempt);
        await _settle(received.termSync);
      case TomBusOutcome.requeued:
        if (attempt >= _maxDeliveries) {
          await _bus._deadLetter(message, group, 'max-deliveries', attempt);
          await _settle(received.termSync);
        } else {
          await _settle(received.nakSync);
        }
    }
  }

  /// Sends an acknowledgement; one the server did not confirm is logged — the
  /// message is then delivered again after its acknowledgement wait, which is
  /// what at least once allows.
  Future<void> _settle(Future<void> Function({Duration timeout}) send) async {
    try {
      await send(timeout: const Duration(seconds: 5));
    } on Object catch (error) {
      tomLog.warn(
        'A settlement on $topic for $group was not confirmed: $error',
      );
    }
  }

  @override
  Future<void> cancel() async {
    if (!_active) return;
    _active = false;
    _bus._consumers.remove(this);
    await _loop;
    await onLastCancel?.call();
  }
}

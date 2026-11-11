/// The RabbitMQ adapter of the Tom message bus.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:tom_dart_amqp/tom_dart_amqp.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';

/// A [TomMessageBus] over a RabbitMQ broker (AMQP 0-9-1).
///
/// ## How the contract maps onto RabbitMQ
///
/// | Contract | RabbitMQ |
/// | -------- | -------- |
/// | A topic | A durable fanout exchange of its own, `<namePrefix>.<topic>_<hash>` |
/// | A consumer group | A durable queue bound to the topic's exchange, `<namePrefix>.<topic>.<group>_<hash>` |
/// | An ephemeral group | An exclusive, auto-deleted queue of this bus's connection, deleted by the broker when its last consumer cancels |
/// | Consumers of a group | Consumers of that queue, each on a channel of its own with a prefetch of one |
/// | Publish | A persistent message, confirmed by the broker (publisher confirms) before [publish] answers |
/// | Acknowledge | `basic.ack` |
/// | Reject, redelivered | The message is published again to the group's queue with the next attempt, confirmed, and the delivery acknowledged |
/// | Dead letter | Published to `<topic>.dlq`'s exchange, confirmed, and the delivery acknowledged |
/// | The attempt | The `Tom-Bus-Attempt` header the redelivery writes |
/// | Message id | The AMQP `message-id` property |
///
/// A redelivery goes to the back of the group's queue rather than through
/// `basic.reject`: RabbitMQ's classic queues count no deliveries, and the
/// contract's attempt has to come from somewhere. The copy is confirmed before
/// the delivery is acknowledged, so a failure between the two repeats the
/// message rather than losing it — at least once.
///
/// A group created by its first subscription receives the messages published
/// after its queue is bound, and its queue keeps them while none of its
/// consumers is subscribed. A message published to a topic with no queue
/// bound is dropped by the exchange. Ordering per key is not declared: a
/// redelivery goes behind the messages after it.
///
/// The message travels as JSON in the AMQP body; its key, publication time and
/// attempt travel in AMQP headers (`Tom-Bus-*`) beside the message's own.
class TomRabbitMqMessageBus implements TomMessageBus {
  TomRabbitMqMessageBus._(
    this.client, {
    required this.namePrefix,
    required this.confirmTimeout,
    required this.ownsClient,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// A bus over [client], connected or not.
  ///
  /// [namePrefix] prefixes every exchange and queue the bus declares;
  /// [confirmTimeout] is how long a publish waits for the broker's
  /// confirmation. With [ownsClient] the bus closes [client] on [close].
  factory TomRabbitMqMessageBus(
    Client client, {
    String namePrefix = 'tombus',
    Duration confirmTimeout = const Duration(seconds: 10),
    bool ownsClient = false,
    DateTime Function()? clock,
  }) => TomRabbitMqMessageBus._(
    client,
    namePrefix: namePrefix,
    confirmTimeout: confirmTimeout,
    ownsClient: ownsClient,
    clock: clock,
  );

  /// Connects to the broker at [uri] — `amqp://user:password@host:port/vhost`,
  /// the user `guest` and the virtual host `/` by default — and answers a bus
  /// owning the connection. Throws `message_bus.rabbitmq.unreachable` when the
  /// broker cannot be reached or refuses the login.
  static Future<TomRabbitMqMessageBus> connect(
    Uri uri, {
    String namePrefix = 'tombus',
    Duration confirmTimeout = const Duration(seconds: 10),
  }) async {
    final client = Client(settings: settingsOf(uri));
    try {
      await client.connect();
    } on Object catch (error, stack) {
      await client.close().catchError((_) {});
      throw TomBusException(
        'message_bus.rabbitmq.unreachable',
        'The RabbitMQ broker at ${_redacted(uri)} could not be reached: '
            '$error',
        parameters: {'uri': _redacted(uri)},
        rootException: error,
        stack: stack,
      );
    }
    return TomRabbitMqMessageBus(
      client,
      namePrefix: namePrefix,
      confirmTimeout: confirmTimeout,
      ownsClient: true,
    );
  }

  /// The connection settings [uri] names: host, port (5672 by default), the
  /// user and password of its user info (`guest` / `guest` by default) and the
  /// virtual host of its path (`/` by default; `/%2F` is `/` as well).
  static ConnectionSettings settingsOf(Uri uri) {
    final userInfo = uri.userInfo.split(':');
    final user = userInfo.first.isEmpty
        ? 'guest'
        : Uri.decodeComponent(userInfo.first);
    final password = userInfo.length > 1
        ? Uri.decodeComponent(userInfo.sublist(1).join(':'))
        : 'guest';
    final path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
    return ConnectionSettings(
      host: uri.host.isEmpty ? '127.0.0.1' : uri.host,
      port: uri.hasPort ? uri.port : 5672,
      virtualHost: path.isEmpty ? '/' : Uri.decodeComponent(path),
      authProvider: PlainAuthenticator(user, password),
      connectTimeout: const Duration(seconds: 5),
    );
  }

  static String _redacted(Uri uri) =>
      uri.userInfo.isEmpty ? '$uri' : '${uri.replace(userInfo: '***')}';

  /// The AMQP connection.
  final Client client;

  /// The first part of every exchange and queue name the bus declares.
  final String namePrefix;

  /// How long a publish waits for the broker's confirmation.
  final Duration confirmTimeout;

  /// Whether [close] closes [client].
  final bool ownsClient;

  final DateTime Function() _clock;
  final Set<_RabbitConsumer> _consumers = {};
  final Set<String> _exchanges = {};
  final Map<String, _Confirm> _pending = {};
  final Random _random = Random.secure();
  late final String _busId = _hex(4);
  Future<Channel>? _publishChannel;
  var _published = 0;
  bool _closed = false;
  Future<void>? _closing;

  /// The ordering key, when the message has one.
  static const String keyHeader = 'Tom-Bus-Key';

  /// When the message was published, ISO 8601 in UTC.
  static const String publishedAtHeader = 'Tom-Bus-Published-At';

  /// The attempt a delivery of this copy is, from 1.
  static const String attemptHeader = 'Tom-Bus-Attempt';

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

  /// The exchange of [topic] under [prefix].
  static String exchangeOf(String prefix, String topic) =>
      '$prefix.${_safe(topic)}_${_hash(topic)}';

  /// The durable queue of [group] on [topic] under [prefix].
  static String queueOf(String prefix, String topic, String group) =>
      '$prefix.${_safe(topic)}.${_safe(group)}_${_hash('$topic\u0000$group')}';

  static String _safe(String name) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_\-.]'), '_');
    return safe.length > 80 ? safe.substring(0, 80) : safe;
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

  String _hex(int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return '$buffer';
  }

  /// The channel publishes go out on, with publisher confirms; opened again
  /// after the broker closed it.
  Future<Channel> _publisher() => _publishChannel ??= () async {
    try {
      final channel = await client.channel();
      await channel.confirmPublishedMessages();
      channel.publishNotifier(_confirmed);
      return channel;
    } on Object {
      _publishChannel = null;
      rethrow;
    }
  }();

  void _confirmed(PublishNotification notification) {
    final confirm = _pending.remove(notification.properties?.corellationId);
    if (confirm == null || confirm.done.isCompleted) return;
    if (notification.published) {
      confirm.done.complete();
    } else {
      confirm.done.completeError(StateError('the broker refused the message'));
    }
  }

  /// Declares [topic]'s exchange once.
  Future<void> _declareExchange(Channel channel, String topic) async {
    if (_exchanges.contains(topic)) return;
    await channel.exchange(
      exchangeOf(namePrefix, topic),
      ExchangeType.FANOUT,
      durable: true,
    );
    _exchanges.add(topic);
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
    final messageId = id ?? 'msg-${_hex(16)}';
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

  /// Publishes [message] to its topic's exchange, or with [queue] straight to
  /// that queue, and waits for the broker's confirmation.
  Future<void> _send(
    TomBusMessage message, {
    String? queue,
    int attempt = 1,
  }) async {
    final tag = '$_busId-${++_published}';
    final confirm = _Confirm();
    try {
      final channel = await _publisher();
      if (queue == null) await _declareExchange(channel, message.topic);
      final properties = MessageProperties.persistentMessage()
        ..messageId = message.id
        ..corellationId = tag
        ..contentType = 'application/json'
        ..headers = <String, Object?>{
          ...message.headers,
          publishedAtHeader: message.publishedAt.toUtc().toIso8601String(),
          attemptHeader: '$attempt',
          if (message.key != null) keyHeader: message.key,
        };
      _pending[tag] = confirm;
      final body = Uint8List.fromList(utf8.encode(jsonEncode(message.payload)));
      if (queue == null) {
        final exchange = await channel.exchange(
          exchangeOf(namePrefix, message.topic),
          ExchangeType.FANOUT,
          declare: false,
        );
        exchange.publish(body, '', properties: properties);
      } else {
        // Straight to the group's queue, through the default exchange.
        final target = await channel.queue(queue, declare: false);
        target.publish(body, properties: properties);
      }
      await confirm.done.future.timeout(confirmTimeout);
    } on Object catch (error, stack) {
      _pending.remove(tag);
      if (error is! TimeoutException) _publishChannel = null;
      if (error is ChannelException || error is ExchangeNotFoundException) {
        _exchanges.remove(message.topic);
      }
      throw TomBusException(
        'message_bus.rabbitmq.publish_failed',
        "The message ${message.id} could not be published to "
            "'${queue ?? message.topic}': $error",
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
    // An ephemeral group's queue is this connection's own: the bus id keeps
    // two buses of one process apart, as the contract's "in this bus" says.
    final queueName = ephemeral
        ? '${queueOf(namePrefix, topic, group)}.$_busId'
        : queueOf(namePrefix, topic, group);
    Channel? channel;
    final Consumer amqpConsumer;
    try {
      final publisher = await _publisher();
      await _declareExchange(publisher, topic);
      channel = await client.channel();
      await channel.qos(0, 1, global: false);
      final exchange = await channel.exchange(
        exchangeOf(namePrefix, topic),
        ExchangeType.FANOUT,
        declare: false,
      );
      final queue = await channel.queue(
        queueName,
        durable: !ephemeral,
        exclusive: ephemeral,
        autoDelete: ephemeral,
      );
      await queue.bind(exchange, '');
      amqpConsumer = await queue.consume(noAck: false);
    } on Object catch (error, stack) {
      await channel?.close().catchError((_) => channel!);
      throw TomBusException(
        'message_bus.rabbitmq.consumer_failed',
        "The consumer of group '$group' on '$topic' could not be created: "
            '$error',
        parameters: {'topic': topic, 'group': group},
        rootException: error,
        stack: stack,
      );
    }
    final effective = codec ?? TomBusCodec<T>.reflected();
    final consumer = _RabbitConsumer(
      this,
      topic,
      group,
      queueName,
      channel,
      amqpConsumer,
      maxDeliveries,
      (message, attempt) => tomDispatch(
        message,
        attempt: attempt,
        group: group,
        codec: effective,
        handler: handler,
      ),
    );
    _consumers.add(consumer);
    consumer.start();
    return consumer;
  }

  /// [received] as the message it carries and the attempt of this delivery.
  (TomBusMessage, int) _messageOf(String topic, AmqpMessage received) {
    final properties = received.properties;
    final headers = <String, String>{
      for (final entry in (properties?.headers ?? const {}).entries)
        if (entry.value != null) entry.key: '${entry.value}',
    };
    final key = headers.remove(keyHeader);
    final publishedAt = headers.remove(publishedAtHeader);
    final attempt = int.tryParse(headers.remove(attemptHeader) ?? '') ?? 1;
    final body = received.payload;
    return (
      TomBusMessage(
        id: properties?.messageId ?? '',
        topic: topic,
        key: key,
        payload: body == null || body.isEmpty
            ? null
            : jsonDecode(utf8.decode(body)),
        headers: headers,
        publishedAt: publishedAt == null
            ? _clock()
            : DateTime.parse(publishedAt),
      ),
      attempt,
    );
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
    final publisher = _publishChannel;
    _publishChannel = null;
    if (publisher != null) {
      try {
        await (await publisher).close();
      } on Object {
        // Closed with its connection already.
      }
    }
    if (ownsClient) await client.close();
  }
}

class _Confirm {
  final Completer<void> done = Completer<void>();
}

/// One consumer of a group: an AMQP consumer on a channel of its own, handling
/// one delivery at a time.
class _RabbitConsumer implements TomBusSubscription {
  _RabbitConsumer(
    this._bus,
    this.topic,
    this.group,
    this._queue,
    this._channel,
    this._consumer,
    this._maxDeliveries,
    this._handle,
  );

  final TomRabbitMqMessageBus _bus;
  final String _queue;
  final Channel _channel;
  final Consumer _consumer;
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
  StreamSubscription<AmqpMessage>? _listening;
  Future<void> _work = Future<void>.value();

  void start() {
    _listening = _consumer.listen(
      (received) {
        // One delivery at a time: the prefetch of one holds the next at the
        // broker until this one is settled.
        _work = _work.then((_) => _process(received));
      },
      onError: (Object error) =>
          tomLog.warn('Consuming $topic for $group: $error'),
    );
  }

  Future<void> _process(AmqpMessage received) async {
    if (!_active) {
      // Taken after the consumer was cancelled: back to the group's queue.
      _settle(() => received.reject(true));
      return;
    }
    final TomBusMessage message;
    final int attempt;
    try {
      (message, attempt) = _bus._messageOf(topic, received);
    } on Object {
      // Not a message of this bus: nothing could ever handle it.
      _settle(() => received.reject(false));
      return;
    }
    final (outcome, reason) = await _handle(message, attempt);
    try {
      switch (outcome) {
        case TomBusOutcome.acknowledged:
          break;
        case TomBusOutcome.deadLettered:
          await _bus._deadLetter(message, group, reason ?? 'rejected', attempt);
        case TomBusOutcome.requeued:
          if (attempt >= _maxDeliveries) {
            await _bus._deadLetter(message, group, 'max-deliveries', attempt);
          } else {
            await _bus._send(message, queue: _queue, attempt: attempt + 1);
          }
      }
    } on Object catch (error) {
      // The copy was not confirmed: the broker delivers this one again.
      tomLog.warn('Settling ${message.id} on $topic for $group: $error');
      // A pause before the broker hands it back, so a broker refusing every
      // copy is not asked again at once.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      _settle(() => received.reject(true));
      return;
    }
    _settle(received.ack);
  }

  void _settle(void Function() send) {
    try {
      send();
    } on Object catch (error) {
      // The channel is gone: the broker hands the delivery to the group again.
      tomLog.warn('A settlement on $topic for $group failed: $error');
    }
  }

  @override
  Future<void> cancel() async {
    if (!_active) return;
    _active = false;
    _bus._consumers.remove(this);
    try {
      await _consumer.cancel();
    } on Object catch (error) {
      tomLog.warn('Cancelling the consumer of $group on $topic: $error');
    }
    await _work;
    await _listening?.cancel();
    try {
      await _channel.close();
    } on Object {
      // Closed with its connection already.
    }
  }
}

/// The Azure adapter of the Tom message bus, over Azure Service Bus.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:tom_core_kernel/tom_core_kernel.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';

import 'amqp/amqp_connection.dart';
import 'amqp/amqp_message.dart';

/// How a [TomServiceBusMessageBus] authenticates: a shared access key, used
/// for SASL `PLAIN` on the AMQP connection and for shared access signatures on
/// the management API.
class TomServiceBusSasKey {
  /// The key [key] of the shared access policy [keyName].
  const TomServiceBusSasKey(this.keyName, this.key);

  /// The policy's name, e.g. `RootManageSharedAccessKey`.
  final String keyName;

  /// The policy's key.
  final String key;

  /// A shared access signature for [resource], valid for [validFor] from
  /// [now]: `SharedAccessSignature sr=...&sig=...&se=...&skn=...`, the
  /// signature an HMAC-SHA256 over the URL-encoded resource and the expiry.
  String signature(
    Uri resource, {
    Duration validFor = const Duration(hours: 1),
    DateTime? now,
  }) {
    final expiry =
        (now ?? DateTime.now()).add(validFor).millisecondsSinceEpoch ~/ 1000;
    final encoded = Uri.encodeQueryComponent('$resource'.toLowerCase());
    final mac = Hmac(
      sha256,
      utf8.encode(key),
    ).convert(utf8.encode('$encoded\n$expiry'));
    return 'SharedAccessSignature sr=$encoded'
        '&sig=${Uri.encodeQueryComponent(base64.encode(mac.bytes))}'
        '&se=$expiry&skn=$keyName';
  }
}

/// A [TomMessageBus] over Azure Service Bus: messages over AMQP 1.0 — through
/// this package's own AMQP client, since Dart has no maintained AMQP 1.0
/// library — and topics and subscriptions through the management API.
///
/// ## How the contract maps onto Service Bus
///
/// | Contract | Service Bus |
/// | -------- | ----------- |
/// | A topic | A topic, `<namePrefix>-<topic>-<hash>` |
/// | A consumer group | A subscription of the topic, `<group>-<hash>` |
/// | An ephemeral group | A subscription of this bus's own, created on subscription and deleted when its last consumer cancels (and deleted by Service Bus after [ephemeralIdle] without a consumer) |
/// | Consumers of a group | Receiver links on the subscription, each granted one message at a time |
/// | Acknowledge | `accepted` (complete) |
/// | Reject, redelivered | `modified` with `delivery-failed` (abandon): delivered again at once, its delivery count raised |
/// | Dead letter | Published to `<topic>.dlq`'s topic, then completed |
/// | The attempt | The message header's `delivery-count`, plus one |
/// | Message id | `message-id` of the message's properties, and in its envelope |
///
/// A subscription keeps what is published while none of its consumers is
/// attached; a message published to a topic without subscriptions reaches no
/// one. A received message is locked for [lockDuration]: a handler that runs
/// longer sees its message delivered again — at least once. Service Bus
/// dead-letters a message into the subscription's own dead-letter queue after
/// [maxDeliveryCount] deliveries, so the subscription is created with
/// [maxDeliveryCount] above the `maxDeliveries` a consumer passes: a consumer
/// asking for more deliveries than [maxDeliveryCount] gets at most that many.
/// Ordering per key is not declared (it would need sessions).
///
/// The message travels as one JSON envelope in a `data` section: `{"id",
/// "key", "publishedAt", "headers", "payload"}`, as the other adapters'
/// messages do.
class TomServiceBusMessageBus implements TomMessageBus {
  /// A bus on the namespace at [host] (`<namespace>.servicebus.windows.net`),
  /// authenticating with [credential].
  ///
  /// The AMQP connection goes to [amqpPort] (5671, over TLS when [secure]);
  /// the management API to [managementEndpoint] (`https://<host>/` by
  /// default). [namePrefix] begins every topic name; [lockDuration] is how
  /// long a received message stays locked to its consumer;
  /// [maxDeliveryCount] the subscription's own delivery limit (at most 10 on
  /// the emulator, 2000 on Service Bus); [ephemeralIdle] how long Service Bus
  /// keeps an ephemeral group's subscription after its consumers went away
  /// without cancelling (at least five minutes). [httpClient] sends the
  /// management requests; a [TomResilientClient] by default, closed by
  /// [close].
  TomServiceBusMessageBus({
    required this.host,
    required this.credential,
    this.amqpPort = 5671,
    this.secure = true,
    Uri? managementEndpoint,
    this.namePrefix = 'tombus',
    this.lockDuration = const Duration(seconds: 30),
    this.maxDeliveryCount = 10,
    this.ephemeralIdle = const Duration(minutes: 5),
    this.retryDelay = const Duration(seconds: 1),
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : managementEndpoint = managementEndpoint ?? Uri.parse('https://$host/'),
       _http = httpClient ?? TomResilientClient(),
       _ownsClient = httpClient == null,
       _clock = clock ?? DateTime.now;

  /// A bus from a Service Bus connection string:
  /// `Endpoint=sb://<host>/;SharedAccessKeyName=<name>;SharedAccessKey=<key>`.
  ///
  /// With `UseDevelopmentEmulator=true` it addresses the emulator: AMQP
  /// without TLS on [amqpPort] (5672 by default) and the management API over
  /// HTTP on [managementPort] (5300 by default) — the ports a test maps the
  /// emulator's to.
  factory TomServiceBusMessageBus.fromConnectionString(
    String connectionString, {
    int? amqpPort,
    int? managementPort,
    String namePrefix = 'tombus',
  }) {
    final parts = <String, String>{};
    for (final part in connectionString.split(';')) {
      final at = part.indexOf('=');
      if (at > 0) {
        parts[part.substring(0, at).trim().toLowerCase()] = part
            .substring(at + 1)
            .trim();
      }
    }
    final endpoint = parts['endpoint'];
    final keyName = parts['sharedaccesskeyname'];
    final key = parts['sharedaccesskey'];
    if (endpoint == null || keyName == null || key == null) {
      throw TomBusException(
        'message_bus.azure.connection_string_invalid',
        'A Service Bus connection string needs Endpoint, '
            'SharedAccessKeyName and SharedAccessKey.',
      );
    }
    final host = Uri.parse(endpoint).host;
    final emulator = parts['usedevelopmentemulator']?.toLowerCase() == 'true';
    return TomServiceBusMessageBus(
      host: host,
      credential: TomServiceBusSasKey(keyName, key),
      amqpPort: amqpPort ?? (emulator ? 5672 : 5671),
      secure: !emulator,
      managementEndpoint: emulator
          ? Uri.parse('http://$host:${managementPort ?? 5300}/')
          : null,
      namePrefix: namePrefix,
    );
  }

  /// The namespace's host name.
  final String host;

  /// The shared access key the bus authenticates with.
  final TomServiceBusSasKey credential;

  /// The AMQP port.
  final int amqpPort;

  /// Whether the AMQP connection is over TLS.
  final bool secure;

  /// The management API's base address.
  final Uri managementEndpoint;

  /// The first part of every topic name.
  final String namePrefix;

  /// How long a received message stays locked to its consumer.
  final Duration lockDuration;

  /// The delivery limit the subscriptions are created with.
  final int maxDeliveryCount;

  /// How long an ephemeral group's subscription outlives its last consumer
  /// when that consumer went away without cancelling.
  final Duration ephemeralIdle;

  /// How long a consumer waits before attaching again after its link or
  /// connection failed.
  final Duration retryDelay;

  final http.Client _http;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final Map<String, Future<void>> _topics = {};
  final Map<String, Future<void>> _durable = {};
  final Map<String, Future<String>> _ephemeral = {};
  final Map<String, int> _ephemeralUsers = {};
  final Map<String, Future<AmqpSender>> _senders = {};
  final Set<_ServiceBusConsumer> _consumers = {};
  final Random _random = Random.secure();
  late final String _busId = _hex(3);
  Future<AmqpConnection>? _connection;
  bool _closed = false;
  Future<void>? _closing;

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

  // ---------------------------------------------------------------------------
  // Names
  // ---------------------------------------------------------------------------

  /// The Service Bus topic name of [topic] under [prefix].
  static String topicNameOf(String prefix, String topic) =>
      '${_safe(prefix, 40)}-${_safe(topic, 160)}-${_hash(topic)}';

  /// The subscription name of [group], with [suffix] for an ephemeral group's
  /// own subscription: at most 50 characters, as Service Bus requires.
  static String subscriptionNameOf(String group, {String? suffix}) {
    final tail = '-${_hash(group)}${suffix == null ? '' : '-$suffix'}';
    return '${_safe(group, 50 - tail.length)}$tail';
  }

  static String _safe(String name, int max) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_\-.]'), '_');
    return safe.length > max ? safe.substring(0, max) : safe;
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

  // ---------------------------------------------------------------------------
  // The management API
  // ---------------------------------------------------------------------------

  static const String _apiVersion = '2021-05';
  static const String _ns =
      'http://schemas.microsoft.com/netservices/2010/10/servicebus/connect';

  Uri _managementUri(String path) => managementEndpoint.replace(
    path: '${managementEndpoint.path.replaceAll(RegExp(r'/$'), '')}/$path',
    queryParameters: {'api-version': _apiVersion},
  );

  /// Sends [method] to the management API's [path] with [body]; answers the
  /// status. A status of 300 or above other than one of [accept] throws.
  Future<int> management(
    String method,
    String path, {
    String? body,
    Set<int> accept = const {},
  }) async {
    final uri = _managementUri(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = credential.signature(
        managementEndpoint.replace(path: '/$path', query: ''),
        now: _clock(),
      );
    if (body != null) {
      request.headers['content-type'] =
          'application/atom+xml;type=entry;charset=utf-8';
      request.body = body;
    }
    final response = await http.Response.fromStream(await _http.send(request));
    if (response.statusCode >= 300 && !accept.contains(response.statusCode)) {
      throw TomBusException(
        'message_bus.azure.management_failed',
        '$method $path answered ${response.statusCode}: '
            '${response.body.length > 300 ? response.body.substring(0, 300) : response.body}',
        parameters: {'path': path, 'status': response.statusCode},
      );
    }
    return response.statusCode;
  }

  static String _entry(String description, String content) =>
      '<entry xmlns="http://www.w3.org/2005/Atom"><content '
      'type="application/xml"><$description xmlns="$_ns" '
      'xmlns:i="http://www.w3.org/2001/XMLSchema-instance">$content'
      '</$description></content></entry>';

  /// [duration] as an ISO 8601 duration of whole seconds.
  static String isoDuration(Duration duration) =>
      'PT${duration.inSeconds < 1 ? 1 : duration.inSeconds}S';

  /// [topic]'s Service Bus topic, created once; one that exists already is
  /// taken as it is.
  Future<void> _topic(String topic) => _topics[topic] ??= () async {
    try {
      await management(
        'PUT',
        topicNameOf(namePrefix, topic),
        body: _entry('TopicDescription', ''),
        accept: const {409},
      );
    } on Object {
      _topics.remove(topic);
      rethrow;
    }
  }();

  Future<void> _subscription(
    String topic,
    String name, {
    Duration? autoDeleteOnIdle,
  }) async {
    await _topic(topic);
    await management(
      'PUT',
      '${topicNameOf(namePrefix, topic)}/subscriptions/$name',
      body: _entry(
        'SubscriptionDescription',
        '<LockDuration>${isoDuration(lockDuration)}</LockDuration>'
            '${autoDeleteOnIdle == null ? '' : '<AutoDeleteOnIdle>${isoDuration(autoDeleteOnIdle)}</AutoDeleteOnIdle>'}'
            '<MaxDeliveryCount>$maxDeliveryCount</MaxDeliveryCount>',
      ),
      accept: const {409},
    );
  }

  static String _key(String topic, String group) => '$topic\u0000$group';

  /// The durable group's subscription name, created once.
  Future<String> _durableSubscription(String topic, String group) async {
    final name = subscriptionNameOf(group);
    final key = _key(topic, group);
    await (_durable[key] ??= () async {
      try {
        await _subscription(topic, name);
      } on Object {
        _durable.remove(key);
        rethrow;
      }
    }());
    return name;
  }

  /// The ephemeral group's subscription in this bus, created for its first
  /// subscriber.
  Future<String> _ephemeralSubscription(String topic, String group) {
    final key = _key(topic, group);
    return _ephemeral[key] ??= () async {
      try {
        // A name of its own each time: a subscription just deleted may linger.
        final name = subscriptionNameOf(group, suffix: '$_busId${_hex(2)}');
        await _subscription(topic, name, autoDeleteOnIdle: ephemeralIdle);
        return name;
      } on Object {
        _ephemeral.remove(key);
        rethrow;
      }
    }();
  }

  Future<void> _releaseEphemeral(String topic, String group) async {
    final key = _key(topic, group);
    final users = (_ephemeralUsers[key] ?? 1) - 1;
    if (users > 0) {
      _ephemeralUsers[key] = users;
      return;
    }
    _ephemeralUsers.remove(key);
    final name = await _ephemeral.remove(key);
    if (name == null) return;
    try {
      await management(
        'DELETE',
        '${topicNameOf(namePrefix, topic)}/subscriptions/$name',
        accept: const {404},
      );
    } on Object catch (error) {
      tomLog.warn(
        'The subscription of ephemeral group $group on $topic was not '
        'removed: $error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // The AMQP connection
  // ---------------------------------------------------------------------------

  /// The shared connection, opened on first use and again after it failed.
  Future<AmqpConnection> _amqp() {
    final current = _connection;
    if (current != null) {
      return current.then((c) async {
        if (c.isOpen) return c;
        if (identical(_connection, current)) _connection = null;
        return _amqp();
      });
    }
    final opening = AmqpConnection.connect(
      host,
      amqpPort,
      secure: secure,
      hostname: host,
      sasl: AmqpSasl.plain(credential.keyName, credential.key),
    );
    _connection = opening;
    opening.then(
      (c) => c.done.catchError((_) {}).whenComplete(() {
        if (identical(_connection, opening)) _connection = null;
        _senders.clear();
      }),
      onError: (_) {
        if (identical(_connection, opening)) _connection = null;
      },
    );
    return opening;
  }

  Future<AmqpSender> _sender(String topic) async {
    final cached = _senders[topic];
    if (cached != null) {
      try {
        final sender = await cached;
        if (sender.isAttached) return sender;
      } on Object {
        // Failed to attach: attached afresh below.
      }
      if (identical(_senders[topic], cached)) _senders.remove(topic);
    }
    final attaching = () async {
      await _topic(topic);
      final connection = await _amqp();
      return connection.attachSender(topicNameOf(namePrefix, topic));
    }();
    _senders[topic] = attaching;
    try {
      return await attaching;
    } on Object {
      _senders.remove(topic);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Publish
  // ---------------------------------------------------------------------------

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

  /// [message] as the envelope a message body carries.
  static Map<String, Object?> envelopeOf(TomBusMessage message) => {
    'id': message.id,
    'key': ?message.key,
    'publishedAt': message.publishedAt.toUtc().toIso8601String(),
    'headers': message.headers,
    'payload': message.payload,
  };

  /// The message the body [body] of a message on [topic] carries; `null` when
  /// it is no envelope of this bus.
  static TomBusMessage? messageOf(String topic, List<int> body) {
    Object? value;
    try {
      value = jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
    if (value is! Map || value['id'] is! String) return null;
    final headers = value['headers'];
    final publishedAt = value['publishedAt'];
    return TomBusMessage(
      id: value['id']! as String,
      topic: topic,
      key: value['key'] as String?,
      payload: value['payload'],
      headers: {
        if (headers is Map)
          for (final entry in headers.entries) '${entry.key}': '${entry.value}',
      },
      publishedAt: publishedAt is String
          ? DateTime.parse(publishedAt)
          : DateTime.now(),
    );
  }

  Future<void> _send(TomBusMessage message) async {
    try {
      final amqp = AmqpMessage(
        data: Uint8List.fromList(utf8.encode(jsonEncode(envelopeOf(message)))),
        messageId: message.id,
        contentType: 'application/json',
        creationTime: message.publishedAt,
      );
      try {
        await (await _sender(message.topic)).send(amqp);
      } on AmqpException catch (error) {
        // A link or connection that failed under the send: once more, afresh.
        if (error.condition.startsWith('amqp:link') ||
            error.condition.startsWith('amqp:connection')) {
          _senders.remove(message.topic);
          await (await _sender(message.topic)).send(amqp);
        } else {
          rethrow;
        }
      }
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.azure.publish_failed',
        "The message ${message.id} could not be published to "
            "'${message.topic}': $error",
        parameters: {'topic': message.topic, 'message': message.id},
        rootException: error,
        stack: stack,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Subscribe
  // ---------------------------------------------------------------------------

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
    final String subscription;
    try {
      subscription = ephemeral
          ? await _ephemeralSubscription(topic, group)
          : await _durableSubscription(topic, group);
    } on Object catch (error, stack) {
      if (error is TomBusException) rethrow;
      throw TomBusException(
        'message_bus.azure.consumer_failed',
        "The subscription of group '$group' on '$topic' could not be "
            'created: $error',
        parameters: {'topic': topic, 'group': group},
        rootException: error,
        stack: stack,
      );
    }
    final effective = codec ?? TomBusCodec<T>.reflected();
    final consumer = _ServiceBusConsumer(
      this,
      topic,
      group,
      '${topicNameOf(namePrefix, topic)}/Subscriptions/$subscription',
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
      final key = _key(topic, group);
      _ephemeralUsers[key] = (_ephemeralUsers[key] ?? 0) + 1;
      consumer.onCancel = () => _releaseEphemeral(topic, group);
    }
    _consumers.add(consumer);
    try {
      await consumer.start();
    } on Object catch (error, stack) {
      _consumers.remove(consumer);
      throw TomBusException(
        'message_bus.azure.consumer_failed',
        "A consumer of group '$group' on '$topic' could not attach: $error",
        parameters: {'topic': topic, 'group': group},
        rootException: error,
        stack: stack,
      );
    }
    return consumer;
  }

  @override
  Future<void> close() => _closing ??= _shutDown();

  Future<void> _shutDown() async {
    _closed = true;
    await Future.wait([for (final c in List.of(_consumers)) c.cancel()]);
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await (await connection).close();
      } on Object {
        // Never opened, or failed already.
      }
    }
    if (_ownsClient) _http.close();
  }
}

/// One consumer of a group: a receiver link on the group's subscription,
/// granted one message at a time.
class _ServiceBusConsumer implements TomBusSubscription {
  _ServiceBusConsumer(
    this._bus,
    this.topic,
    this.group,
    this._address,
    this._maxDeliveries,
    this._handle,
  );

  final TomServiceBusMessageBus _bus;
  final String _address;
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
  AmqpReceiver? _receiver;
  Future<void>? _loop;

  /// Runs once this consumer has stopped — an ephemeral group's release.
  Future<void> Function()? onCancel;

  /// Attaches the first receiver and starts receiving.
  Future<void> start() async {
    final receiver = await _attach();
    _loop = _run(receiver);
  }

  Future<AmqpReceiver> _attach() async {
    final connection = await _bus._amqp();
    final receiver = await connection.attachReceiver(_address);
    _receiver = receiver;
    return receiver;
  }

  Future<void> _run(AmqpReceiver first) async {
    var receiver = first;
    while (_active) {
      try {
        receiver.grant(1);
        await for (final delivery in receiver.deliveries) {
          if (!_active) {
            delivery.settle(const AmqpReleased());
            break;
          }
          await _process(delivery);
          if (!_active) break;
          receiver.grant(1);
        }
      } on Object catch (error) {
        if (!_active) return;
        tomLog.warn('Receiving from $topic for $group failed: $error');
      }
      if (!_active) return;
      await Future<void>.delayed(_bus.retryDelay);
      try {
        receiver = await _attach();
      } on Object catch (error) {
        if (!_active) return;
        tomLog.warn('Attaching to $topic for $group failed: $error');
      }
    }
  }

  Future<void> _process(AmqpDelivery delivery) async {
    final body = delivery.message.data;
    final message = body == null
        ? null
        : TomServiceBusMessageBus.messageOf(topic, body);
    if (message == null) {
      // Not a message of this bus: nothing could ever handle it.
      delivery.settle(const AmqpAccepted());
      return;
    }
    final attempt = delivery.message.deliveryCount + 1;
    final (outcome, reason) = await _handle(message, attempt);
    switch (outcome) {
      case TomBusOutcome.acknowledged:
        delivery.settle(const AmqpAccepted());
      case TomBusOutcome.deadLettered:
        await _deadLetter(delivery, message, reason ?? 'rejected', attempt);
      case TomBusOutcome.requeued:
        if (attempt >= _maxDeliveries) {
          await _deadLetter(delivery, message, 'max-deliveries', attempt);
        } else {
          delivery.settle(const AmqpModified());
        }
    }
  }

  Future<void> _deadLetter(
    AmqpDelivery delivery,
    TomBusMessage message,
    String reason,
    int attempts,
  ) async {
    try {
      await _bus._send(
        tomDeadLetter(
          message,
          group: group,
          reason: reason,
          attempts: attempts,
        ),
      );
    } on Object catch (error) {
      // Abandoned: delivered again, and dead-lettered then.
      tomLog.warn('Dead-lettering ${message.id} of $topic failed: $error');
      delivery.settle(const AmqpModified(deliveryFailed: false));
      return;
    }
    delivery.settle(const AmqpAccepted());
  }

  @override
  Future<void> cancel() async {
    if (!_active) return;
    _active = false;
    _bus._consumers.remove(this);
    final receiver = _receiver;
    if (receiver != null) {
      try {
        await receiver.close();
      } on Object {
        // The connection is gone already.
      }
    }
    await _loop;
    await onCancel?.call();
  }
}

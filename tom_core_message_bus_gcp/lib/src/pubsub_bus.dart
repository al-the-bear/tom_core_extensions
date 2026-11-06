/// The Google Cloud adapter of the Tom message bus, over Pub/Sub.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:tom_core_kernel/tom_core_kernel.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_server/tom_core_server.dart'
    show TomFcmServiceAccountCredential;

/// Supplies the OAuth access token a Pub/Sub request carries — called for
/// every request; a source caches its token and mints a fresh one before it
/// expires.
typedef TomGcpTokenSource = Future<String> Function();

/// A [TomMessageBus] over Google Cloud Pub/Sub, through its REST API — no
/// Google SDK.
///
/// ## How the contract maps onto Pub/Sub
///
/// | Contract | Pub/Sub |
/// | -------- | ------- |
/// | A topic | A topic, `<namePrefix>-<topic>-<hash>` |
/// | A consumer group | A subscription to it, `<namePrefix>-<topic>-<group>-<hash>`, with message ordering enabled |
/// | An ephemeral group | A subscription of this bus's own, deleted when its last consumer cancels |
/// | Consumers of a group | Polling loops on the subscription, each pulling one message at a time |
/// | Acknowledge | `acknowledge` |
/// | Reject, redelivered | Handled again in place, the ack deadline extended, before the consumer pulls the next message |
/// | Dead letter | Published to `<topic>.dlq`'s topic, then acknowledged |
/// | The attempt | Counted by the consumer, in place |
/// | Ordering key | The message's `orderingKey` |
///
/// Pub/Sub counts deliveries only on a subscription with a dead-letter
/// policy, and that policy's least maximum is five attempts; the contract's
/// `maxDeliveries` is any number from one. So a redelivery is made in place,
/// as the Kafka adapter does: the delivery is handled again until it is
/// acknowledged, dead-lettered, or has had `maxDeliveries` attempts. A
/// consumer that stops before acknowledging leaves the message to the
/// subscription, which delivers it again after the ack deadline — the count
/// then starts over, which at least once allows.
///
/// A subscription receives the messages published after it was created and
/// keeps them for seven days while none of its consumers pulls. A message
/// published to a topic with no subscription reaches no one. With message
/// ordering enabled, Pub/Sub delivers a key's messages in publish order, the
/// next only once the one before was acknowledged: ordering per key is
/// declared.
///
/// The message travels as one JSON envelope in the message data: `{"id",
/// "key", "publishedAt", "headers", "payload"}`.
class TomPubSubMessageBus implements TomMessageBus {
  /// A bus in the Google Cloud project [projectId].
  ///
  /// [token] supplies the access token every request carries; `null` sends
  /// none, which only an emulator accepts. [endpoint] defaults to the global
  /// Pub/Sub endpoint; ordered publishing wants a regional one
  /// (`https://europe-west1-pubsub.googleapis.com/`). [namePrefix] begins
  /// every topic and subscription name; [ackDeadline] is how long a pulled
  /// message stays with its consumer; [fetchWait] is the pause before an empty
  /// pull is repeated — and so the longest a [TomBusSubscription.cancel]
  /// waits. [httpClient] sends the requests; a [TomResilientClient] by
  /// default, closed by [close].
  TomPubSubMessageBus({
    required this.projectId,
    this.token,
    Uri? endpoint,
    this.namePrefix = 'tombus',
    this.ackDeadline = const Duration(seconds: 60),
    this.fetchWait = const Duration(milliseconds: 500),
    this.redeliveryDelay = const Duration(milliseconds: 100),
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : endpoint = endpoint ?? Uri.parse('https://pubsub.googleapis.com/'),
       _http = httpClient ?? TomResilientClient(),
       _ownsClient = httpClient == null,
       _clock = clock ?? DateTime.now;

  /// A bus authenticated with the service-account key file [keyJson] (the
  /// JSON Google issues); the project is the key's own unless [projectId]
  /// names another.
  factory TomPubSubMessageBus.serviceAccount(
    String keyJson, {
    String? projectId,
    Uri? endpoint,
    String namePrefix = 'tombus',
  }) {
    final credential = serviceAccountCredential(keyJson);
    final project = projectId ?? credential.projectId;
    if (project == null) {
      throw TomBusException(
        'message_bus.pubsub.no_project',
        'The service-account key names no project, and none was given.',
      );
    }
    return TomPubSubMessageBus(
      projectId: project,
      token: credential.token,
      endpoint: endpoint,
      namePrefix: namePrefix,
    );
  }

  /// The scope Pub/Sub's REST API requires.
  static const String pubsubScope = 'https://www.googleapis.com/auth/pubsub';

  /// A Google service-account credential for the key file [keyJson], asking
  /// for [pubsubScope]: the OAuth JWT-bearer grant, its token cached until
  /// five minutes before it expires.
  static TomFcmServiceAccountCredential serviceAccountCredential(
    String keyJson,
  ) {
    final parsed = TomFcmServiceAccountCredential.fromJson(keyJson);
    return TomFcmServiceAccountCredential(
      clientEmail: parsed.clientEmail,
      privateKeyPem: (jsonDecode(keyJson) as Map)['private_key']! as String,
      tokenUri: parsed.tokenUri,
      scope: pubsubScope,
      projectId: parsed.projectId,
    );
  }

  /// A token source asking the metadata server of the Compute Engine, GKE or
  /// Cloud Run host for the default service account's token, cached until a
  /// minute before it expires.
  static TomGcpTokenSource metadataServer({
    http.Client? httpClient,
    DateTime Function()? clock,
  }) {
    final client = httpClient ?? http.Client();
    final now = clock ?? DateTime.now;
    String? token;
    DateTime? expires;
    return () async {
      final until = expires;
      if (token != null && until != null && now().isBefore(until)) {
        return token!;
      }
      final response = await client.get(
        Uri.parse(
          'http://metadata.google.internal/computeMetadata/v1/instance/'
          'service-accounts/default/token',
        ),
        headers: const {'Metadata-Flavor': 'Google'},
      );
      if (response.statusCode != 200) {
        throw TomBusException(
          'message_bus.pubsub.no_token',
          'The metadata server answered ${response.statusCode} for a token.',
          parameters: {'status': response.statusCode},
        );
      }
      final json = jsonDecode(response.body) as Map;
      token = json['access_token']! as String;
      final seconds = (json['expires_in'] as num?)?.toInt() ?? 300;
      expires = now().add(Duration(seconds: max(0, seconds - 60)));
      return token!;
    };
  }

  /// The project the topics and subscriptions live in.
  final String projectId;

  /// Where the access token comes from; `null` for an emulator.
  final TomGcpTokenSource? token;

  /// The Pub/Sub endpoint.
  final Uri endpoint;

  /// The first part of every topic and subscription name.
  final String namePrefix;

  /// How long a pulled message stays with its consumer.
  final Duration ackDeadline;

  /// The pause before an empty pull is repeated.
  final Duration fetchWait;

  /// The pause between two attempts of a delivery.
  final Duration redeliveryDelay;

  final http.Client _http;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final Map<String, Future<String>> _topics = {};
  final Map<String, Future<String>> _durable = {};
  final Map<String, Future<String>> _ephemeral = {};
  final Map<String, int> _ephemeralUsers = {};
  final Set<_PubSubConsumer> _consumers = {};
  final Random _random = Random.secure();
  late final String _busId = _hex(4);
  bool _closed = false;
  Future<void>? _closing;

  @override
  TomBusCapabilities get capabilities =>
      const TomBusCapabilities(orderedPerKey: true);

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

  /// The topic id of [topic] under [prefix]: it starts with a letter, as
  /// Pub/Sub requires.
  static String topicIdOf(String prefix, String topic) =>
      '$prefix-${_safe(topic, 160)}-${_hash(topic)}';

  /// The subscription id of [group] on [topic] under [prefix], with [suffix]
  /// for an ephemeral group's own subscription.
  static String subscriptionIdOf(
    String prefix,
    String topic,
    String group, {
    String? suffix,
  }) =>
      '$prefix-${_safe(topic, 100)}-${_safe(group, 100)}-'
      '${_hash('$topic\u0000$group')}${suffix == null ? '' : '-$suffix'}';

  static String _safe(String name, int max) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_\-.~]'), '_');
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

  /// The resource name of the topic [topic].
  String topicName(String topic) =>
      'projects/$projectId/topics/${topicIdOf(namePrefix, topic)}';

  String _subscriptionName(String id) =>
      'projects/$projectId/subscriptions/$id';

  // ---------------------------------------------------------------------------
  // The REST API
  // ---------------------------------------------------------------------------

  /// Calls Pub/Sub: [method] on `v1/<resource>` with [body], answering the
  /// decoded result. Throws a [PubSubError] for an error answer.
  Future<Map<String, Object?>> call(
    String method,
    String resource, [
    Map<String, Object?>? body,
  ]) async {
    final request = http.Request(method, endpoint.resolve('v1/$resource'));
    final source = token;
    if (source != null) {
      request.headers['Authorization'] = 'Bearer ${await source()}';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(await _http.send(request));
    final decoded = response.body.trim().isEmpty
        ? const <String, Object?>{}
        : (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode >= 300) {
      final error = decoded['error'];
      throw PubSubError(
        response.statusCode,
        error is Map ? '${error['status'] ?? ''}' : '',
        error is Map ? '${error['message'] ?? ''}' : response.body,
      );
    }
    return decoded;
  }

  /// `PUT` of [resource], taking an `ALREADY_EXISTS` answer as success: a
  /// topic or subscription another node created first is the same one.
  Future<void> _create(String resource, Map<String, Object?> body) async {
    try {
      await call('PUT', resource, body);
    } on PubSubError catch (error) {
      if (error.status != 409) rethrow;
    }
  }

  /// [topic]'s topic name, the topic created once.
  Future<String> _topic(String topic) => _topics[topic] ??= () async {
    final name = topicName(topic);
    try {
      await _create(name, const {});
    } on Object catch (error, stack) {
      _topics.remove(topic);
      throw TomBusException(
        'message_bus.pubsub.topic_failed',
        "The Pub/Sub topic of '$topic' could not be created: $error",
        parameters: {'topic': topic},
        rootException: error,
        stack: stack,
      );
    }
    return name;
  }();

  /// Creates the subscription [id] to [topicName]; answers its name.
  Future<String> _subscription(String id, String topicName) async {
    final name = _subscriptionName(id);
    await _create(name, {
      'topic': topicName,
      'ackDeadlineSeconds': ackDeadline.inSeconds,
      'enableMessageOrdering': true,
    });
    return name;
  }

  static String _key(String topic, String group) => '$topic\u0000$group';

  Future<String> _durableSubscription(String topic, String group) {
    final key = _key(topic, group);
    return _durable[key] ??= () async {
      try {
        return await _subscription(
          subscriptionIdOf(namePrefix, topic, group),
          await _topic(topic),
        );
      } on Object {
        _durable.remove(key);
        rethrow;
      }
    }();
  }

  Future<String> _ephemeralSubscription(String topic, String group) {
    final key = _key(topic, group);
    return _ephemeral[key] ??= () async {
      try {
        return await _subscription(
          subscriptionIdOf(
            namePrefix,
            topic,
            group,
            suffix: '$_busId${_hex(2)}',
          ),
          await _topic(topic),
        );
      } on Object {
        _ephemeral.remove(key);
        rethrow;
      }
    }();
  }

  /// The last subscriber of an ephemeral group in this bus cancelled: its
  /// subscription is deleted, and with it what waited in it.
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
      await call('DELETE', name);
    } on Object catch (error) {
      tomLog.warn(
        'The subscription of ephemeral group $group on $topic was not '
        'deleted: $error',
      );
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

  /// [message] as the envelope a message's data carries.
  static Map<String, Object?> envelopeOf(TomBusMessage message) => {
    'id': message.id,
    'key': ?message.key,
    'publishedAt': message.publishedAt.toUtc().toIso8601String(),
    'headers': message.headers,
    'payload': message.payload,
  };

  /// The message the base64 [data] of a message on [topic] carries; `null`
  /// when it is no envelope of this bus.
  static TomBusMessage? messageOf(String topic, String? data) {
    Object? value;
    try {
      value = jsonDecode(utf8.decode(base64.decode(data ?? '')));
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
    final topicName = await _topic(message.topic);
    try {
      await call('POST', '$topicName:publish', {
        'messages': [
          {
            'data': base64.encode(utf8.encode(jsonEncode(envelopeOf(message)))),
            if (message.key != null) 'orderingKey': message.key,
          },
        ],
      });
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.pubsub.publish_failed',
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
    } on TomBusException {
      rethrow;
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.pubsub.consumer_failed',
        "The subscription of group '$group' on '$topic' could not be "
            'created: $error',
        parameters: {'topic': topic, 'group': group},
        rootException: error,
        stack: stack,
      );
    }
    final effective = codec ?? TomBusCodec<T>.reflected();
    final consumer = _PubSubConsumer(
      this,
      topic,
      group,
      subscription,
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
    consumer.start();
    return consumer;
  }

  @override
  Future<void> close() => _closing ??= _shutDown();

  Future<void> _shutDown() async {
    _closed = true;
    await Future.wait([for (final c in List.of(_consumers)) c.cancel()]);
    if (_ownsClient) _http.close();
  }
}

/// An error answer of Pub/Sub.
class PubSubError implements Exception {
  /// An answer with HTTP [status], the gRPC status name [code] and [message].
  PubSubError(this.status, this.code, this.message);

  /// The HTTP status.
  final int status;

  /// The gRPC status name, e.g. `NOT_FOUND`.
  final String code;

  /// Pub/Sub's explanation.
  final String message;

  @override
  String toString() => 'Pub/Sub: HTTP $status $code $message'.trim();
}

/// One consumer of a group: a loop pulling one message at a time from the
/// group's subscription.
class _PubSubConsumer implements TomBusSubscription {
  _PubSubConsumer(
    this._bus,
    this.topic,
    this.group,
    this._subscription,
    this._maxDeliveries,
    this._handle,
  );

  final TomPubSubMessageBus _bus;
  final String _subscription;
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
  Future<void> Function()? onCancel;

  void start() => _loop = _run();

  Future<void> _run() async {
    while (_active) {
      final List<Object?> received;
      try {
        final answer = await _bus.call('POST', '$_subscription:pull', {
          'maxMessages': 1,
          // A bounded wait, so a cancel is answered within fetchWait.
          'returnImmediately': true,
        });
        received = (answer['receivedMessages'] as List?) ?? const [];
      } on Object catch (error) {
        if (!_active) return;
        tomLog.warn('Pulling from $topic for $group failed: $error');
        await Future<void>.delayed(_bus.fetchWait);
        continue;
      }
      if (received.isEmpty) {
        await Future<void>.delayed(_bus.fetchWait);
        continue;
      }
      for (final raw in received.cast<Map<Object?, Object?>>()) {
        final ackId = raw['ackId']! as String;
        if (!_active) {
          // Taken after the consumer was cancelled: back to the group.
          await _modify(ackId, Duration.zero);
          continue;
        }
        await _process(raw, ackId);
      }
    }
  }

  Future<void> _process(Map<Object?, Object?> raw, String ackId) async {
    final data = (raw['message'] as Map?)?['data'] as String?;
    final message = TomPubSubMessageBus.messageOf(topic, data);
    if (message == null) {
      // Not a message of this bus: nothing could ever handle it.
      await _acknowledge(ackId);
      return;
    }
    var attempt = 1;
    while (true) {
      final (outcome, reason) = await _handle(message, attempt);
      if (outcome == TomBusOutcome.acknowledged) break;
      if (outcome == TomBusOutcome.deadLettered || attempt >= _maxDeliveries) {
        final why = outcome == TomBusOutcome.deadLettered
            ? reason ?? 'rejected'
            : 'max-deliveries';
        if (!await _deadLetter(message, why, attempt)) return;
        break;
      }
      attempt++;
      await Future<void>.delayed(_bus.redeliveryDelay);
      if (!_active) {
        await _modify(ackId, Duration.zero);
        return;
      }
      // A fresh deadline for the next attempt.
      await _modify(ackId, _bus.ackDeadline);
    }
    await _acknowledge(ackId);
  }

  /// Publishes the dead letter; `false` when it could not be, the message then
  /// left to come back after its deadline.
  Future<bool> _deadLetter(
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
      return true;
    } on Object catch (error) {
      tomLog.warn('Dead-lettering ${message.id} of $topic failed: $error');
      return false;
    }
  }

  Future<void> _acknowledge(String ackId) async {
    try {
      await _bus.call('POST', '$_subscription:acknowledge', {
        'ackIds': [ackId],
      });
    } on Object catch (error) {
      // Delivered again after the deadline: at least once.
      tomLog.warn('Acknowledging on $topic for $group failed: $error');
    }
  }

  Future<void> _modify(String ackId, Duration deadline) async {
    try {
      await _bus.call('POST', '$_subscription:modifyAckDeadline', {
        'ackIds': [ackId],
        'ackDeadlineSeconds': deadline.inSeconds,
      });
    } on Object catch (error) {
      tomLog.warn('Extending a deadline on $topic for $group failed: $error');
    }
  }

  @override
  Future<void> cancel() async {
    if (!_active) return;
    _active = false;
    _bus._consumers.remove(this);
    await _loop;
    await onCancel?.call();
  }
}

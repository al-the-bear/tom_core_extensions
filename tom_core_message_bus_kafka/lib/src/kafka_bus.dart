/// The Kafka adapter of the Tom message bus, over the Kafka REST Proxy API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:tom_core_kernel/tom_core_kernel.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';

/// A [TomMessageBus] over a Kafka cluster, reached through a Kafka REST Proxy
/// (Confluent REST Proxy, API v2 for records and consumers, v3 for creating
/// topics).
///
/// ## How the contract maps onto Kafka
///
/// | Contract | Kafka |
/// | -------- | ----- |
/// | A topic | A Kafka topic of the same name, created with [partitions] partitions on first use |
/// | A consumer group | A Kafka consumer group of the same name |
/// | An ephemeral group | A consumer group of this bus's own, `<group>.<bus id>`, that commits no offset |
/// | Consumers of a group | Consumer instances of the group in the proxy; Kafka assigns each the partitions it reads |
/// | Publish | A record keyed by the message's key, its value the message envelope |
/// | Acknowledge | The record's offset committed |
/// | Reject, redelivered | Handled again in place, attempt by attempt, before the records behind it |
/// | Dead letter | Published to `<topic>.dlq`, then the offset committed |
/// | The attempt | Counted by the consumer, in place |
///
/// Kafka has no acknowledgement per message: a consumer's position in a
/// partition is the offset it committed. A redelivery is therefore made in
/// place — the delivery is handled again until it is acknowledged, dead-
/// lettered, or has had `maxDeliveries` attempts — and a consumer that stops
/// before committing leaves the record to the group. That keeps a key's
/// records in order, a redelivery before the ones behind it, so ordering per
/// key is declared: the records of one key go to one partition, and one
/// partition is read by one consumer of the group at a time.
///
/// A group created by its first subscription starts at the end of the topic
/// (`auto.offset.reset` `latest`), and [subscribe] answers only once the group
/// has joined and its position is committed, so every message published after
/// it is the group's. The group keeps its position while none of its consumers
/// is subscribed. A record outlives no consumer: it stays for the topic's
/// retention, which the cluster sets.
///
/// The REST Proxy API v2 carries no record headers, so the record's value is
/// an envelope: `{"id", "publishedAt", "headers", "payload"}`, the key the
/// record key. A consumer instance lives in the proxy that created it: a
/// deployment with several proxies routes one bus to one of them.
class TomKafkaMessageBus implements TomMessageBus {
  /// A bus over the REST proxy at [proxy] (e.g. `http://localhost:8082`).
  ///
  /// [partitions] is the partition count of a topic the bus creates — the
  /// most consumers of a group that read at once; [replicationFactor], when
  /// set, its replication factor (the cluster's default otherwise).
  /// [fetchWait] is how long one fetch waits for records — and so the longest
  /// a [TomBusSubscription.cancel] waits. [redeliveryDelay] spaces the
  /// attempts of a delivery. [client] sends the requests; a
  /// [TomResilientClient] by default, closed by [close].
  TomKafkaMessageBus(
    this.proxy, {
    this.partitions = 3,
    this.replicationFactor,
    this.fetchWait = const Duration(milliseconds: 500),
    this.redeliveryDelay = const Duration(milliseconds: 100),
    this.joinTimeout = const Duration(seconds: 20),
    http.Client? client,
    DateTime Function()? clock,
  }) : _http = client ?? TomResilientClient(),
       _ownsClient = client == null,
       _clock = clock ?? DateTime.now;

  /// Answers a bus over the proxy at [proxy] once the proxy answered for its
  /// cluster. Throws `message_bus.kafka.unreachable` when it does not.
  static Future<TomKafkaMessageBus> connect(
    Uri proxy, {
    int partitions = 3,
    int? replicationFactor,
    Duration fetchWait = const Duration(milliseconds: 500),
  }) async {
    final bus = TomKafkaMessageBus(
      proxy,
      partitions: partitions,
      replicationFactor: replicationFactor,
      fetchWait: fetchWait,
    );
    try {
      await bus._cluster();
    } on Object {
      await bus.close();
      rethrow;
    }
    return bus;
  }

  /// The REST proxy.
  final Uri proxy;

  /// The partition count of a topic the bus creates.
  final int partitions;

  /// The replication factor of a topic the bus creates; the cluster's default
  /// when `null`.
  final int? replicationFactor;

  /// How long one fetch waits for records.
  final Duration fetchWait;

  /// The pause between two attempts of a delivery.
  final Duration redeliveryDelay;

  /// How long [subscribe] waits for the group to give the new consumer its
  /// partitions. A group with more consumers than partitions leaves some with
  /// none; such a consumer is subscribed after this long and reads once a
  /// partition is free.
  final Duration joinTimeout;

  final http.Client _http;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final Map<String, Future<void>> _topics = {};
  final Set<_KafkaConsumer> _consumers = {};
  final Random _random = Random.secure();
  late final String _busId = _hex(4);
  Future<String>? _clusterId;
  var _instances = 0;
  bool _closed = false;
  Future<void>? _closing;

  /// The content type of the records of a JSON produce.
  static const String jsonRecords = 'application/vnd.kafka.json.v2+json';

  /// The content type of the v2 consumer requests.
  static const String v2 = 'application/vnd.kafka.v2+json';

  static final RegExp _topicPattern = RegExp(r'^[A-Za-z0-9._\-]{1,249}$');

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

  /// Refuses (`message_bus.kafka.invalid_topic`) a topic that is no Kafka
  /// topic name: letters, digits, `.`, `_` and `-`, at most 249 of them, and
  /// neither `.` nor `..`.
  static String validTopic(String topic) {
    if (!_topicPattern.hasMatch(topic) || topic == '.' || topic == '..') {
      throw TomBusException(
        'message_bus.kafka.invalid_topic',
        "The topic '$topic' is not a Kafka topic name: letters, digits, '.', "
            "'_' and '-', at most 249.",
        parameters: {'topic': topic},
      );
    }
    return topic;
  }

  String _hex(int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return '$buffer';
  }

  Uri _url(List<String> segments, [Map<String, String>? query]) =>
      proxy.replace(
        pathSegments: [
          ...proxy.pathSegments.where((s) => s.isNotEmpty),
          ...segments,
        ],
        queryParameters: query,
      );

  /// Sends a request and answers the decoded JSON of a 2xx answer, or throws a
  /// [_ProxyError] with the proxy's error code.
  Future<Object?> _call(
    String method,
    List<String> path, {
    Object? body,
    String contentType = v2,
    String accept = v2,
    Map<String, String>? query,
  }) async {
    final request = http.Request(method, _url(path, query))
      ..headers['Accept'] = accept;
    if (body != null) {
      request
        ..headers['Content-Type'] = contentType
        ..body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(await _http.send(request));
    final text = response.body;
    Object? json;
    if (text.isNotEmpty) {
      try {
        json = jsonDecode(text);
      } on FormatException {
        json = text;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return json;
    final code = json is Map ? json['error_code'] : null;
    throw _ProxyError(
      response.statusCode,
      code is int ? code : response.statusCode,
      json is Map ? '${json['message']}' : text,
    );
  }

  /// The cluster the proxy serves, asked once.
  Future<String> _cluster() => _clusterId ??= () async {
    try {
      final answer = await _call('GET', [
        'v3',
        'clusters',
      ], accept: 'application/json');
      final data = (answer! as Map)['data']! as List;
      return (data.first as Map)['cluster_id']! as String;
    } on Object catch (error, stack) {
      _clusterId = null;
      throw TomBusException(
        'message_bus.kafka.unreachable',
        'The Kafka REST proxy at $proxy did not name its cluster: $error',
        parameters: {'proxy': '$proxy'},
        rootException: error,
        stack: stack,
      );
    }
  }();

  /// Creates [topic] once; a topic that exists is taken as it is.
  Future<void> _topic(String topic) {
    validTopic(topic);
    return _topics[topic] ??= () async {
      final cluster = await _cluster();
      try {
        await _call(
          'POST',
          ['v3', 'clusters', cluster, 'topics'],
          body: {
            'topic_name': topic,
            'partitions_count': partitions,
            'replication_factor': ?replicationFactor,
          },
          contentType: 'application/json',
          accept: 'application/json',
        );
      } on _ProxyError catch (error, stack) {
        // The proxy answers a topic that exists with the same code as a
        // request it refuses (40002): only asking for the topic tells them
        // apart.
        if (await _topicExists(cluster, topic)) return;
        _topics.remove(topic);
        throw TomBusException(
          'message_bus.kafka.topic_failed',
          "The topic '$topic' could not be created: $error",
          parameters: {'topic': topic},
          rootException: error,
          stack: stack,
        );
      } on Object catch (error, stack) {
        _topics.remove(topic);
        if (error is TomBusException) rethrow;
        throw TomBusException(
          'message_bus.kafka.topic_failed',
          "The topic '$topic' could not be created: $error",
          parameters: {'topic': topic},
          rootException: error,
          stack: stack,
        );
      }
    }();
  }

  Future<bool> _topicExists(String cluster, String topic) async {
    try {
      await _call('GET', [
        'v3',
        'clusters',
        cluster,
        'topics',
        topic,
      ], accept: 'application/json');
      return true;
    } on _ProxyError {
      return false;
    }
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
    validTopic(topic);
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

  /// [message] as the envelope a record's value carries.
  static Map<String, Object?> envelopeOf(TomBusMessage message) => {
    'id': message.id,
    'publishedAt': message.publishedAt.toUtc().toIso8601String(),
    'headers': message.headers,
    'payload': message.payload,
  };

  /// The message a record of [topic] with [key] and the envelope [value]
  /// carries; `null` when [value] is no envelope of this bus.
  static TomBusMessage? messageOf(String topic, Object? key, Object? value) {
    if (value is! Map || value['id'] is! String) return null;
    final headers = value['headers'];
    final publishedAt = value['publishedAt'];
    return TomBusMessage(
      id: value['id']! as String,
      topic: topic,
      key: key?.toString(),
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

  /// Publishes [message] as it is, to its topic.
  Future<void> _send(TomBusMessage message) async {
    try {
      await _topic(message.topic);
      final answer = await _call(
        'POST',
        ['topics', message.topic],
        body: {
          'records': [
            {'key': ?message.key, 'value': envelopeOf(message)},
          ],
        },
        contentType: jsonRecords,
      );
      final offsets = (answer! as Map)['offsets']! as List;
      for (final offset in offsets.cast<Map>()) {
        if (offset['error_code'] != null) {
          throw StateError('${offset['error_code']}: ${offset['error']}');
        }
      }
    } on Object catch (error, stack) {
      if (error is TomBusException) rethrow;
      throw TomBusException(
        'message_bus.kafka.publish_failed',
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
    await _topic(topic);
    final kafkaGroup = ephemeral ? '$group.$_busId' : group;
    final instance = 'tom-$_busId-${++_instances}';
    final effective = codec ?? TomBusCodec<T>.reflected();
    final consumer = _KafkaConsumer(
      this,
      topic,
      group,
      kafkaGroup,
      instance,
      commits: !ephemeral,
      maxDeliveries: maxDeliveries,
      handle: (message, attempt) => tomDispatch(
        message,
        attempt: attempt,
        group: group,
        codec: effective,
        handler: handler,
      ),
    );
    try {
      await consumer.open();
    } on Object catch (error, stack) {
      await consumer.cancel();
      throw TomBusException(
        'message_bus.kafka.consumer_failed',
        "The consumer of group '$group' on '$topic' could not be created: "
            '$error',
        parameters: {'topic': topic, 'group': group},
        rootException: error,
        stack: stack,
      );
    }
    _consumers.add(consumer);
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

/// An error answer of the REST proxy.
class _ProxyError implements Exception {
  _ProxyError(this.status, this.code, this.message);

  final int status;
  final int code;
  final String message;

  @override
  String toString() => 'HTTP $status, error $code: $message';
}

/// One consumer of a group: a consumer instance in the proxy and the loop
/// fetching its records and handling them one at a time.
class _KafkaConsumer implements TomBusSubscription {
  _KafkaConsumer(
    this._bus,
    this.topic,
    this.group,
    this._kafkaGroup,
    this._instance, {
    required bool commits,
    required int maxDeliveries,
    required Future<(TomBusOutcome, String?)> Function(
      TomBusMessage message,
      int attempt,
    )
    handle,
  }) : _commits = commits,
       _maxDeliveries = maxDeliveries,
       _handle = handle;

  final TomKafkaMessageBus _bus;
  final String _kafkaGroup;
  final String _instance;
  final bool _commits;
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
  bool _created = false;
  Future<void>? _loop;
  final Completer<void> _joined = Completer<void>();

  List<String> get _path => ['consumers', _kafkaGroup, 'instances', _instance];

  /// Creates the consumer instance, subscribes it to [topic], and completes
  /// once the group has given it its partitions and its position is
  /// committed.
  Future<void> open() async {
    await _bus._call(
      'POST',
      ['consumers', _kafkaGroup],
      body: {
        'name': _instance,
        'format': 'json',
        'auto.offset.reset': 'latest',
        'auto.commit.enable': 'false',
      },
    );
    _created = true;
    await _bus._call(
      'POST',
      [..._path, 'subscription'],
      body: {
        'topics': [topic],
      },
    );
    _loop = _run();
    await _joined.future;
  }

  Future<void> _run() async {
    final joinBy = DateTime.now().add(_bus.joinTimeout);
    while (_active) {
      final List<Object?> records;
      try {
        records =
            await _bus._call(
                  'GET',
                  [..._path, 'records'],
                  accept: TomKafkaMessageBus.jsonRecords,
                  query: {'timeout': '${_bus.fetchWait.inMilliseconds}'},
                )
                as List<Object?>;
        if (!_joined.isCompleted) await _checkJoined(joinBy);
      } on Object catch (error, stack) {
        if (!_active) return;
        if (!_joined.isCompleted) {
          _joined.completeError(error, stack);
          return;
        }
        tomLog.warn('Fetching from $topic for $group failed: $error');
        await Future<void>.delayed(_bus.fetchWait);
        continue;
      }
      for (final record in records.cast<Map<Object?, Object?>>()) {
        if (!_active) return; // Uncommitted: the group hands it on.
        await _process(record);
      }
    }
  }

  /// Completes [_joined] once the instance holds partitions — or, past
  /// [joinBy], without them — committing the position first, so a later
  /// consumer of the group starts where this one did.
  Future<void> _checkJoined(DateTime joinBy) async {
    final answer =
        await _bus._call('GET', [..._path, 'assignments'])
            as Map<Object?, Object?>;
    final assigned = (answer['partitions'] as List?)?.isNotEmpty ?? false;
    if (!assigned && DateTime.now().isBefore(joinBy)) return;
    // An empty body commits the positions the last fetch reached.
    if (_commits && assigned) await _bus._call('POST', [..._path, 'offsets']);
    _joined.complete();
  }

  Future<void> _process(Map<Object?, Object?> record) async {
    final message = TomKafkaMessageBus.messageOf(
      topic,
      record['key'],
      record['value'],
    );
    if (message != null) {
      var attempt = 1;
      while (true) {
        final (outcome, reason) = await _handle(message, attempt);
        if (outcome == TomBusOutcome.acknowledged) break;
        if (outcome == TomBusOutcome.deadLettered ||
            attempt >= _maxDeliveries) {
          final why = outcome == TomBusOutcome.deadLettered
              ? reason ?? 'rejected'
              : 'max-deliveries';
          if (!await _deadLetter(message, why, attempt)) return;
          break;
        }
        attempt++;
        await Future<void>.delayed(_bus.redeliveryDelay);
        if (!_active) return; // Uncommitted: the group hands it on.
      }
    }
    // A record that is no message of this bus could never be handled: it is
    // passed over like a settled one.
    await _commit(record);
  }

  /// Publishes the dead letter, repeating until the broker took it; `false`
  /// when the consumer was cancelled first (the record stays uncommitted).
  Future<bool> _deadLetter(
    TomBusMessage message,
    String reason,
    int attempts,
  ) async {
    while (true) {
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
        if (!_active) return false;
        await Future<void>.delayed(_bus.fetchWait);
      }
    }
  }

  Future<void> _commit(Map<Object?, Object?> record) async {
    if (!_commits) return;
    try {
      // The proxy commits the offset after the one named.
      await _bus._call(
        'POST',
        [..._path, 'offsets'],
        body: {
          'offsets': [
            {
              'topic': record['topic'],
              'partition': record['partition'],
              'offset': record['offset'],
            },
          ],
        },
      );
    } on Object catch (error) {
      // The group delivers the record again: at least once.
      tomLog.warn('Committing a record of $topic for $group failed: $error');
    }
  }

  @override
  Future<void> cancel() async {
    if (!_active) return;
    _active = false;
    _bus._consumers.remove(this);
    await _loop;
    if (!_created) return;
    try {
      await _bus._call('DELETE', _path);
    } on Object catch (error) {
      // The proxy drops an idle instance after its own timeout.
      tomLog.warn('Removing the consumer of $group on $topic: $error');
    }
  }
}

/// The AWS adapter of the Tom message bus, over Amazon SNS and SQS.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:tom_core_kernel/tom_core_kernel.dart';
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_server/tom_core_server.dart'
    show TomAwsCredentials, TomAwsCredentialsSource, TomAwsV4Signer;

/// A [TomMessageBus] over Amazon SNS and SQS, through their HTTP APIs (the SQS
/// JSON protocol, the SNS query protocol) signed with Signature Version 4 — no
/// AWS SDK.
///
/// ## How the contract maps onto SNS and SQS
///
/// | Contract | AWS |
/// | -------- | --- |
/// | A topic | A standard SNS topic, `<namePrefix>-<topic>-<hash>` |
/// | A consumer group | A standard SQS queue, `<namePrefix>-<topic>-<group>-<hash>`, subscribed to the topic with raw message delivery |
/// | An ephemeral group | A queue of this bus's own, created on subscription and unsubscribed and deleted when its last consumer cancels |
/// | Consumers of a group | Long-polling loops on the group's queue, each receiving one message at a time |
/// | Acknowledge | `DeleteMessage` |
/// | Reject, redelivered | `ChangeMessageVisibility` to 0: the queue delivers it again at once |
/// | Dead letter | Published to `<topic>.dlq`'s SNS topic, then deleted from the queue |
/// | The attempt | The message's `ApproximateReceiveCount` |
/// | Message id | Carried in the message envelope |
///
/// A group's queue is subscribed to its topic when the group first subscribes,
/// and keeps what is published while none of its consumers is polling. A
/// message published to a topic no queue is subscribed to reaches no one. An
/// unacknowledged message comes back after [visibilityTimeout], so a handler
/// that runs longer than that sees its message delivered again — at least
/// once. Standard queues neither order nor deduplicate: ordering per key is
/// not declared, and a message can, rarely, be delivered twice.
///
/// SNS carries ten message attributes at most, so the message travels as one
/// JSON envelope in the body: `{"id", "key", "publishedAt", "headers",
/// "payload"}`.
class TomAwsMessageBus implements TomMessageBus {
  /// A bus in [region], signing with [credentials].
  ///
  /// [sqsEndpoint] and [snsEndpoint] default to the region's public endpoints;
  /// set them for a VPC endpoint or an emulator. [namePrefix] begins every
  /// topic and queue name; [visibilityTimeout] is how long a received message
  /// stays hidden from the group's other consumers; [fetchWait] is how long
  /// one receive waits for a message (whole seconds, from 1 to 20) — and so the
  /// longest a [TomBusSubscription.cancel] waits. [httpClient] sends the
  /// requests; a [TomResilientClient] by default, closed by [close].
  TomAwsMessageBus({
    required this.region,
    required this.credentials,
    Uri? sqsEndpoint,
    Uri? snsEndpoint,
    this.namePrefix = 'tombus',
    this.visibilityTimeout = const Duration(seconds: 30),
    this.fetchWait = const Duration(seconds: 1),
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : sqsEndpoint =
           sqsEndpoint ?? Uri.parse('https://sqs.$region.amazonaws.com/'),
       snsEndpoint =
           snsEndpoint ?? Uri.parse('https://sns.$region.amazonaws.com/'),
       _http = httpClient ?? TomResilientClient(),
       _ownsClient = httpClient == null,
       _clock = clock ?? DateTime.now;

  /// A bus with static [accessKeyId] and [secretAccessKey] (and, for temporary
  /// credentials, [sessionToken]); [endpoint], when set, serves both SNS and
  /// SQS — LocalStack's `http://localhost:4566`, say.
  factory TomAwsMessageBus.withKeys({
    required String region,
    required String accessKeyId,
    required String secretAccessKey,
    String? sessionToken,
    Uri? endpoint,
    String namePrefix = 'tombus',
  }) {
    final keys = TomAwsCredentials(
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      sessionToken: sessionToken,
    );
    return TomAwsMessageBus(
      region: region,
      credentials: () async => keys,
      sqsEndpoint: endpoint,
      snsEndpoint: endpoint,
      namePrefix: namePrefix,
    );
  }

  /// The region the topics and queues live in.
  final String region;

  /// Where the credentials come from, asked for every request.
  final TomAwsCredentialsSource credentials;

  /// The SQS endpoint.
  final Uri sqsEndpoint;

  /// The SNS endpoint.
  final Uri snsEndpoint;

  /// The first part of every topic and queue name.
  final String namePrefix;

  /// How long a received message stays hidden from the group's other
  /// consumers.
  final Duration visibilityTimeout;

  /// How long one receive waits for a message.
  final Duration fetchWait;

  final http.Client _http;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final Map<String, Future<String>> _topicArns = {};
  final Map<String, Future<String>> _durableQueues = {};
  final Map<String, Future<_EphemeralQueue>> _ephemeral = {};
  final Map<String, int> _ephemeralUsers = {};
  final Set<_AwsConsumer> _consumers = {};
  final Random _random = Random.secure();
  late final String _busId = _hex(4);
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

  /// The SNS topic name of [topic] under [prefix].
  static String topicNameOf(String prefix, String topic) =>
      '$prefix-${_safe(topic, 160)}-${_hash(topic)}';

  /// The SQS queue name of [group] on [topic] under [prefix], with [suffix]
  /// for an ephemeral group's own queue: at most 80 characters, as SQS
  /// requires, whatever the parts' lengths — the prefix is cut to 30, and the
  /// topic and group share what is left; the hash keeps cut names apart.
  static String queueNameOf(
    String prefix,
    String topic,
    String group, {
    String? suffix,
  }) {
    final head = _safe(prefix, 30);
    final tail =
        '-${_hash('$topic\u0000$group')}${suffix == null ? '' : '-$suffix'}';
    final room = 80 - head.length - tail.length - 2;
    final share = room ~/ 2;
    return '$head-${_safe(topic, share)}-${_safe(group, room - share)}$tail';
  }

  static String _safe(String name, int max) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
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
  // The two APIs
  // ---------------------------------------------------------------------------

  Future<http.Response> _signedPost(
    Uri endpoint,
    String service,
    Map<String, String> headers,
    String body,
  ) async {
    final signed =
        TomAwsV4Signer(
          credentials: await credentials(),
          region: region,
          service: service,
        ).signedHeaders(
          method: 'POST',
          uri: endpoint,
          headers: headers,
          payloadHash: sha256.convert(utf8.encode(body)).toString(),
          now: _clock().toUtc(),
        );
    // `host` was signed but is not sent: the client sets it from the URL.
    return _http.post(
      endpoint,
      headers: {
        for (final entry in signed.entries)
          if (entry.key != 'host') entry.key: entry.value,
      },
      body: body,
    );
  }

  /// Calls the SQS action [action] (JSON protocol) and answers its result.
  Future<Map<String, Object?>> sqs(
    String action,
    Map<String, Object?> request,
  ) async {
    final response = await _signedPost(sqsEndpoint, 'sqs', {
      'content-type': 'application/x-amz-json-1.0',
      'x-amz-target': 'AmazonSQS.$action',
    }, jsonEncode(request));
    final decoded = response.body.isEmpty
        ? const <String, Object?>{}
        : (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode >= 300) {
      throw _AwsError(
        'SQS',
        action,
        response.statusCode,
        '${decoded['__type'] ?? ''}'.split('#').last,
        '${decoded['message'] ?? decoded['Message'] ?? ''}',
      );
    }
    return decoded;
  }

  /// Calls the SNS action [action] (query protocol) and answers the XML of its
  /// result.
  Future<String> sns(String action, Map<String, String> parameters) async {
    final body = Uri(
      queryParameters: {
        'Action': action,
        'Version': '2010-03-31',
        ...parameters,
      },
    ).query;
    final response = await _signedPost(snsEndpoint, 'sns', {
      'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
    }, body);
    if (response.statusCode >= 300) {
      throw _AwsError(
        'SNS',
        action,
        response.statusCode,
        xmlValue(response.body, 'Code') ?? '',
        xmlValue(response.body, 'Message') ?? '',
      );
    }
    return response.body;
  }

  /// The text of the first `<element>` in [xml], or `null`.
  static String? xmlValue(String xml, String element) {
    final match = RegExp('<$element>([^<]*)</$element>').firstMatch(xml);
    if (match == null) return null;
    return match
        .group(1)!
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  // ---------------------------------------------------------------------------
  // Topics and queues
  // ---------------------------------------------------------------------------

  /// The ARN of [topic]'s SNS topic, created once. `CreateTopic` answers an
  /// existing topic's ARN, so every node may call it.
  Future<String> _topicArn(String topic) => _topicArns[topic] ??= () async {
    try {
      final xml = await sns('CreateTopic', {
        'Name': topicNameOf(namePrefix, topic),
      });
      final arn = xmlValue(xml, 'TopicArn');
      if (arn == null) throw StateError('CreateTopic answered no TopicArn');
      return arn;
    } on Object catch (error, stack) {
      _topicArns.remove(topic);
      throw TomBusException(
        'message_bus.aws.topic_failed',
        "The SNS topic of '$topic' could not be created: $error",
        parameters: {'topic': topic},
        rootException: error,
        stack: stack,
      );
    }
  }();

  /// Creates the queue [name], lets [topicArn] send to it, and subscribes it
  /// to that topic with raw message delivery. Answers the queue URL and the
  /// subscription ARN.
  Future<(String, String)> _queueOn(String name, String topicArn) async {
    final created = await sqs('CreateQueue', {
      'QueueName': name,
      'Attributes': {
        'VisibilityTimeout': '${visibilityTimeout.inSeconds}',
        // The longest SQS keeps a message: a group away for a fortnight still
        // finds what was published meanwhile.
        'MessageRetentionPeriod': '1209600',
      },
    });
    final url = created['QueueUrl']! as String;
    final attributes = await sqs('GetQueueAttributes', {
      'QueueUrl': url,
      'AttributeNames': ['QueueArn'],
    });
    final queueArn = (attributes['Attributes']! as Map)['QueueArn']! as String;
    await sqs('SetQueueAttributes', {
      'QueueUrl': url,
      'Attributes': {'Policy': jsonEncode(queuePolicy(queueArn, topicArn))},
    });
    final xml = await sns('Subscribe', {
      'TopicArn': topicArn,
      'Protocol': 'sqs',
      'Endpoint': queueArn,
      'ReturnSubscriptionArn': 'true',
      'Attributes.entry.1.key': 'RawMessageDelivery',
      'Attributes.entry.1.value': 'true',
    });
    final subscription = xmlValue(xml, 'SubscriptionArn');
    if (subscription == null) {
      throw StateError('Subscribe answered no SubscriptionArn');
    }
    return (url, subscription);
  }

  /// The queue policy that lets the SNS topic [topicArn], and nothing else,
  /// send to the queue [queueArn].
  static Map<String, Object?> queuePolicy(String queueArn, String topicArn) => {
    'Version': '2012-10-17',
    'Statement': [
      {
        'Effect': 'Allow',
        'Principal': {'Service': 'sns.amazonaws.com'},
        'Action': 'sqs:SendMessage',
        'Resource': queueArn,
        'Condition': {
          'ArnEquals': {'aws:SourceArn': topicArn},
        },
      },
    ],
  };

  static String _key(String topic, String group) => '$topic\u0000$group';

  /// The durable group's queue URL, its queue created and subscribed once.
  Future<String> _durableQueue(String topic, String group) {
    final key = _key(topic, group);
    return _durableQueues[key] ??= () async {
      try {
        final topicArn = await _topicArn(topic);
        final (url, _) = await _queueOn(
          queueNameOf(namePrefix, topic, group),
          topicArn,
        );
        return url;
      } on Object {
        _durableQueues.remove(key);
        rethrow;
      }
    }();
  }

  /// The ephemeral group's queue in this bus, created and subscribed for its
  /// first subscriber.
  Future<_EphemeralQueue> _ephemeralQueue(String topic, String group) {
    final key = _key(topic, group);
    return _ephemeral[key] ??= () async {
      try {
        final topicArn = await _topicArn(topic);
        // A name of its own each time: SQS refuses for a minute to create a
        // queue under the name of one just deleted.
        final (url, subscription) = await _queueOn(
          queueNameOf(namePrefix, topic, group, suffix: '$_busId${_hex(2)}'),
          topicArn,
        );
        return _EphemeralQueue(url, subscription);
      } on Object {
        _ephemeral.remove(key);
        rethrow;
      }
    }();
  }

  /// The last subscriber of an ephemeral group in this bus cancelled: its
  /// queue is unsubscribed and deleted, and with it what waited in it.
  Future<void> _releaseEphemeral(String topic, String group) async {
    final key = _key(topic, group);
    final users = (_ephemeralUsers[key] ?? 1) - 1;
    if (users > 0) {
      _ephemeralUsers[key] = users;
      return;
    }
    _ephemeralUsers.remove(key);
    final queue = await _ephemeral.remove(key);
    if (queue == null) return;
    try {
      await sns('Unsubscribe', {'SubscriptionArn': queue.subscriptionArn});
      await sqs('DeleteQueue', {'QueueUrl': queue.url});
    } on Object catch (error) {
      tomLog.warn(
        'The queue of ephemeral group $group on $topic was not removed: '
        '$error',
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
  static TomBusMessage? messageOf(String topic, String body) {
    Object? value;
    try {
      value = jsonDecode(body);
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
    final topicArn = await _topicArn(message.topic);
    try {
      await sns('Publish', {
        'TopicArn': topicArn,
        'Message': jsonEncode(envelopeOf(message)),
      });
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.aws.publish_failed',
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
    final String url;
    try {
      url = ephemeral
          ? (await _ephemeralQueue(topic, group)).url
          : await _durableQueue(topic, group);
    } on TomBusException {
      rethrow;
    } on Object catch (error, stack) {
      throw TomBusException(
        'message_bus.aws.consumer_failed',
        "The queue of group '$group' on '$topic' could not be created: "
            '$error',
        parameters: {'topic': topic, 'group': group},
        rootException: error,
        stack: stack,
      );
    }
    final effective = codec ?? TomBusCodec<T>.reflected();
    final consumer = _AwsConsumer(
      this,
      topic,
      group,
      url,
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

/// An error answer of SNS or SQS.
class _AwsError implements Exception {
  _AwsError(this.service, this.action, this.status, this.code, this.message);

  final String service;
  final String action;
  final int status;
  final String code;
  final String message;

  @override
  String toString() => '$service $action: HTTP $status $code $message'.trim();
}

class _EphemeralQueue {
  _EphemeralQueue(this.url, this.subscriptionArn);

  final String url;
  final String subscriptionArn;
}

/// One consumer of a group: a loop receiving one message at a time from the
/// group's queue.
class _AwsConsumer implements TomBusSubscription {
  _AwsConsumer(
    this._bus,
    this.topic,
    this.group,
    this._queueUrl,
    this._maxDeliveries,
    this._handle,
  );

  final TomAwsMessageBus _bus;
  final String _queueUrl;
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
    // Whole seconds, at least one: a zero wait is a short poll, repeated as
    // fast as SQS answers.
    final wait = _bus.fetchWait.inSeconds.clamp(1, 20);
    while (_active) {
      final List<Object?> messages;
      try {
        final received = await _bus.sqs('ReceiveMessage', {
          'QueueUrl': _queueUrl,
          'MaxNumberOfMessages': 1,
          'WaitTimeSeconds': wait,
          'AttributeNames': ['ApproximateReceiveCount'],
          'MessageSystemAttributeNames': ['ApproximateReceiveCount'],
        });
        messages = (received['Messages'] as List?) ?? const [];
      } on Object catch (error) {
        if (!_active) return;
        tomLog.warn('Receiving from $topic for $group failed: $error');
        await Future<void>.delayed(_bus.fetchWait);
        continue;
      }
      for (final raw in messages.cast<Map<Object?, Object?>>()) {
        final receipt = raw['ReceiptHandle']! as String;
        if (!_active) {
          // Taken after the consumer was cancelled: back to the group.
          await _settle('ChangeMessageVisibility', receipt);
          continue;
        }
        await _process(raw, receipt);
      }
    }
  }

  Future<void> _process(Map<Object?, Object?> raw, String receipt) async {
    final message = TomAwsMessageBus.messageOf(topic, '${raw['Body']}');
    if (message == null) {
      // Not a message of this bus: nothing could ever handle it.
      await _settle('DeleteMessage', receipt);
      return;
    }
    final attributes = raw['Attributes'];
    final attempt = attributes is Map
        ? int.tryParse('${attributes['ApproximateReceiveCount']}') ?? 1
        : 1;
    final (outcome, reason) = await _handle(message, attempt);
    switch (outcome) {
      case TomBusOutcome.acknowledged:
        await _settle('DeleteMessage', receipt);
      case TomBusOutcome.deadLettered:
        await _deadLetter(message, reason ?? 'rejected', attempt, receipt);
      case TomBusOutcome.requeued:
        if (attempt >= _maxDeliveries) {
          await _deadLetter(message, 'max-deliveries', attempt, receipt);
        } else {
          await _settle('ChangeMessageVisibility', receipt);
        }
    }
  }

  Future<void> _deadLetter(
    TomBusMessage message,
    String reason,
    int attempts,
    String receipt,
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
      // Left to come back after the visibility timeout and be tried again.
      tomLog.warn('Dead-lettering ${message.id} of $topic failed: $error');
      return;
    }
    await _settle('DeleteMessage', receipt);
  }

  /// Deletes the message, or (`ChangeMessageVisibility`) makes it visible to
  /// the group again at once. One that fails comes back after the visibility
  /// timeout, which is what at least once allows.
  Future<void> _settle(String action, String receipt) async {
    try {
      await _bus.sqs(action, {
        'QueueUrl': _queueUrl,
        'ReceiptHandle': receipt,
        if (action == 'ChangeMessageVisibility') 'VisibilityTimeout': 0,
      });
    } on Object catch (error) {
      tomLog.warn('$action on $topic for $group failed: $error');
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

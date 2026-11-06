# Tom Core Message Bus AWS API Reference: tom_core_message_bus_aws

The AWS adapter of the Tom message bus: `TomAwsMessageBus`. One library,
`package:tom_core_message_bus_aws/tom_core_message_bus_aws.dart`.

For credentials and signing, the mapping onto SNS and SQS, settling and the
error keys, see [aws_message_bus.md](../aws_message_bus.md); for the contract's
types (`TomMessageBus`, `TomBusSubscription`, `TomBusCodec`,
`TomBusException`), `tom_core_message_bus`'s
[API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md);
for `TomAwsCredentials` and `TomAwsCredentialsSource`, `tom_core_server`'s
[file storage API summary](../../../../core/tom_core_server/doc/api/api_summary_file_storage.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomAwsMessageBus](#tomawsmessagebus)

## Overview

Source: `lib/src/aws_bus.dart`.

| File | Declares |
| ---- | -------- |
| `aws_bus.dart` | `TomAwsMessageBus` |

The bus is constructed over a region and a credentials source, or with static
keys through `withKeys`, and is used through the `TomMessageBus` contract.

## Class Hierarchy

```text
TomMessageBus  (tom_core_message_bus)
    └── TomAwsMessageBus  (implements)
```

## Classes

### TomAwsMessageBus

A `TomMessageBus` over Amazon SNS and SQS, through their HTTP APIs (the SQS
JSON protocol, the SNS query protocol) signed with Signature Version 4 — no AWS
SDK: a standard SNS topic per topic, a standard SQS queue per group, no
ordering per key.

- **Implements:** `TomMessageBus` (from `tom_core_message_bus`)

#### Constructors

```dart
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
})
```

A bus in `region`, signing with `credentials`. `sqsEndpoint` and `snsEndpoint`
default to `https://sqs.<region>.amazonaws.com/` and
`https://sns.<region>.amazonaws.com/`. `httpClient` sends the requests; a
`TomResilientClient` by default, which `close` closes. `clock` gives a
message's publication time and the signing time; `DateTime.now` by default.

#### Factory Constructors

```dart
factory TomAwsMessageBus.withKeys({
  required String region,
  required String accessKeyId,
  required String secretAccessKey,
  String? sessionToken,
  Uri? endpoint,
  String namePrefix = 'tombus',
})
```

| Factory | Description |
| ------- | ----------- |
| `withKeys` | A bus whose credentials source answers one fixed `TomAwsCredentials` of `accessKeyId`, `secretAccessKey` and, for temporary credentials, `sessionToken`. `endpoint`, when set, serves both SNS and SQS — LocalStack's `http://localhost:4566`, say. The other settings take their defaults. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `topicNameOf` | `static String topicNameOf(String prefix, String topic)` | The SNS topic name of `topic` under `prefix`: `<prefix>-<topic>-<hash>`, the topic's characters other than letters, digits, `_` and `-` replaced by `_` and cut to 160, the hash an eight-digit FNV-1a of the topic as given. |
| `queueNameOf` | `static String queueNameOf(String prefix, String topic, String group, {String? suffix})` | The SQS queue name of `group` on `topic` under `prefix`: `<prefix>-<topic>-<group>-<hash>[-<suffix>]`, the prefix cut to 30, topic and group replaced the same way and sharing the rest of SQS's 80 characters, the hash over the pair. `suffix` names an ephemeral group's own queue. At most 80 characters. |
| `queuePolicy` | `static Map<String, Object?> queuePolicy(String queueArn, String topicArn)` | The queue policy that lets the SNS topic `topicArn`, and nothing else, send to the queue `queueArn`: the service `sns.amazonaws.com` allowed `sqs:SendMessage` on the queue under the condition `ArnEquals` `aws:SourceArn`. |
| `xmlValue` | `static String? xmlValue(String xml, String element)` | The text of the first `<element>` in `xml`, its five XML entities unescaped; `null` when there is none. |
| `envelopeOf` | `static Map<String, Object?> envelopeOf(TomBusMessage message)` | The envelope a message body carries: `{id, key (left out when null), publishedAt (ISO 8601 in UTC), headers, payload}`. |
| `messageOf` | `static TomBusMessage? messageOf(String topic, String body)` | The message the body `body` of a message on `topic` carries; `null` when it is not JSON or no envelope of this bus (not a map with a string `id`). |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `region` | `String` | The region the topics and queues live in. |
| `credentials` | `TomAwsCredentialsSource` | Where the credentials come from, asked for every request. |
| `sqsEndpoint` | `Uri` | The SQS endpoint. |
| `snsEndpoint` | `Uri` | The SNS endpoint. |
| `namePrefix` | `String` | The first part of every topic and queue name. |
| `visibilityTimeout` | `Duration` | How long a received message stays hidden from the group's other consumers. |
| `fetchWait` | `Duration` | How long one receive waits for a message (whole seconds, from 1 to 20); the longest a `cancel` waits. |
| `capabilities` | `TomBusCapabilities` | `const TomBusCapabilities()`: no ordering per key. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `publish` | `Future<String> publish<T>(String topic, T payload, {String? key, Map<String, String> headers = const {}, String? id, TomBusCodec<T>? codec})` | Encodes `payload`, creates the topic if needed and publishes the envelope inside `TomBusTrace.publishing`. Answers the message id (`id`, or a new one). Throws `message_bus.closed`, `message_bus.aws.topic_failed`, `message_bus.aws.publish_failed`, `message_bus.payload.not_json`. |
| `subscribe` | `Future<TomBusSubscription> subscribe<T>(String topic, {required String group, required TomBusHandler<T> handler, TomBusCodec<T>? codec, int maxDeliveries = 5, bool ephemeral = false})` | Checks the arguments, creates the topic if needed, creates the group's queue (once per bus for a durable group, a queue of its own for an ephemeral one), sets its policy, subscribes it to the topic with raw message delivery and starts a receiving loop. Throws `message_bus.closed`, `message_bus.subscribe.invalid`, `message_bus.aws.topic_failed`, `message_bus.aws.consumer_failed`. |
| `sqs` | `Future<Map<String, Object?>> sqs(String action, Map<String, Object?> request)` | Calls the SQS action `action` (JSON protocol), signed, and answers its decoded result. Throws for an answer with a status of 300 or more, naming the action, the status and SQS's error type and message. |
| `sns` | `Future<String> sns(String action, Map<String, String> parameters)` | Calls the SNS action `action` (query protocol, `Version` `2010-03-31`), signed, and answers the XML of its result. Throws for an answer with a status of 300 or more, naming the action, the status and SNS's error code and message. |
| `close` | `Future<void> close()` | Refuses further calls, cancels every consumer (an ephemeral group's last one removing its queue) and closes the HTTP client when the bus made it. A second call answers the same future. |

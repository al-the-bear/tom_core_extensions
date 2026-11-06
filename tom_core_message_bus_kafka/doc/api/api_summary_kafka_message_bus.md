# Tom Core Message Bus Kafka API Reference: tom_core_message_bus_kafka

The Kafka adapter of the Tom message bus: `TomKafkaMessageBus`. One library,
`package:tom_core_message_bus_kafka/tom_core_message_bus_kafka.dart`.

For the REST proxy, the mapping onto Kafka, settling, ordering per key and the
error keys, see [kafka_message_bus.md](../kafka_message_bus.md); for the
contract's types (`TomMessageBus`, `TomBusSubscription`, `TomBusCodec`,
`TomBusException`), `tom_core_message_bus`'s
[API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomKafkaMessageBus](#tomkafkamessagebus)

## Overview

Source: `lib/src/kafka_bus.dart`.

| File | Declares |
| ---- | -------- |
| `kafka_bus.dart` | `TomKafkaMessageBus` |

The bus is constructed over the URI of a Kafka REST proxy or opened with
`connect`, and is used through the `TomMessageBus` contract.

## Class Hierarchy

```text
TomMessageBus  (tom_core_message_bus)
    └── TomKafkaMessageBus  (implements)
```

## Classes

### TomKafkaMessageBus

A `TomMessageBus` over a Kafka cluster, reached through a Kafka REST Proxy
(Confluent REST Proxy; API v2 for records and consumers, v3 for the cluster and
for creating topics): a Kafka topic per topic, a Kafka consumer group per
group, ordering per key.

- **Implements:** `TomMessageBus` (from `tom_core_message_bus`)

#### Constructors

```dart
TomKafkaMessageBus(
  this.proxy, {
  this.partitions = 3,
  this.replicationFactor,
  this.fetchWait = const Duration(milliseconds: 500),
  this.redeliveryDelay = const Duration(milliseconds: 100),
  this.joinTimeout = const Duration(seconds: 20),
  http.Client? client,
  DateTime Function()? clock,
})
```

A bus over the REST proxy at `proxy` (e.g. `http://localhost:8082`). `client`
sends the requests; a `TomResilientClient` by default, which `close` closes.
`clock` gives a message's publication time; `DateTime.now` by default.

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `connect` | `static Future<TomKafkaMessageBus> connect(Uri proxy, {int partitions = 3, int? replicationFactor, Duration fetchWait = const Duration(milliseconds: 500)})` | Answers a bus over the proxy at `proxy` once the proxy named its cluster (`GET /v3/clusters`). Throws `message_bus.kafka.unreachable` when it does not, and closes the bus it made. |
| `validTopic` | `static String validTopic(String topic)` | Answers `topic`. Throws `message_bus.kafka.invalid_topic` for a topic that is not letters, digits, `.`, `_` and `-`, 1 to 249 of them, or is `.` or `..`. |
| `envelopeOf` | `static Map<String, Object?> envelopeOf(TomBusMessage message)` | The envelope a record's value carries: `{id, publishedAt (ISO 8601 in UTC), headers, payload}`. |
| `messageOf` | `static TomBusMessage? messageOf(String topic, Object? key, Object? value)` | The message a record of `topic` with `key` and the envelope `value` carries; `null` when `value` is no envelope of this bus (not a map with a string `id`). |

#### Static Constants

| Constant | Type | Value | Description |
| -------- | ---- | ----- | ----------- |
| `jsonRecords` | `String` | `application/vnd.kafka.json.v2+json` | The content type of the records of a JSON produce, and the accept type of a fetch. |
| `v2` | `String` | `application/vnd.kafka.v2+json` | The content type of the v2 consumer requests. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `proxy` | `Uri` | The REST proxy. |
| `partitions` | `int` | The partition count of a topic the bus creates — the most consumers of a group that read at once. |
| `replicationFactor` | `int?` | The replication factor of a topic the bus creates; the cluster's default when `null`. |
| `fetchWait` | `Duration` | How long one fetch waits for records; the longest a `cancel` waits. |
| `redeliveryDelay` | `Duration` | The pause between two attempts of a delivery. |
| `joinTimeout` | `Duration` | How long `subscribe` waits for the group to give the new consumer its partitions. |
| `capabilities` | `TomBusCapabilities` | `const TomBusCapabilities(orderedPerKey: true)`. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `publish` | `Future<String> publish<T>(String topic, T payload, {String? key, Map<String, String> headers = const {}, String? id, TomBusCodec<T>? codec})` | Checks the topic, encodes `payload`, creates the topic if needed and produces one record inside `TomBusTrace.publishing`, keyed by `key`, its value the envelope. Answers the message id (`id`, or a new one). Throws `message_bus.closed`, `message_bus.kafka.invalid_topic`, `message_bus.kafka.unreachable`, `message_bus.kafka.topic_failed`, `message_bus.kafka.publish_failed`, `message_bus.payload.not_json`. |
| `subscribe` | `Future<TomBusSubscription> subscribe<T>(String topic, {required String group, required TomBusHandler<T> handler, TomBusCodec<T>? codec, int maxDeliveries = 5, bool ephemeral = false})` | Checks the arguments, creates the topic if needed, creates a consumer instance of the group in the proxy (`auto.offset.reset` `latest`, auto commit off), subscribes it and answers once it holds partitions and its position is committed — or after `joinTimeout` without partitions. With `ephemeral` the group is `<group>.<bus id>` and commits no offset. Throws `message_bus.closed`, `message_bus.subscribe.invalid`, `message_bus.kafka.invalid_topic`, `message_bus.kafka.unreachable`, `message_bus.kafka.topic_failed`, `message_bus.kafka.consumer_failed`. |
| `close` | `Future<void> close()` | Refuses further calls, cancels every consumer (deleting its instance in the proxy) and closes the HTTP client when the bus made it. A second call answers the same future. |

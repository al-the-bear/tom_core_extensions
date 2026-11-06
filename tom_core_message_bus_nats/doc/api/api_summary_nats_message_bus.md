# Tom Core Message Bus NATS API Reference: tom_core_message_bus_nats

The NATS JetStream adapter of the Tom message bus: `TomNatsMessageBus`. One
library, `package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart`.

For the mapping onto JetStream, settling, retention and the error keys, see
[nats_message_bus.md](../nats_message_bus.md); for the contract's types
(`TomMessageBus`, `TomBusSubscription`, `TomBusCodec`, `TomBusException`),
`tom_core_message_bus`'s
[API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomNatsMessageBus](#tomnatsmessagebus)

## Overview

Source: `lib/src/nats_bus.dart`.

| File | Declares |
| ---- | -------- |
| `nats_bus.dart` | `TomNatsMessageBus` |

The bus is constructed over a `dart_nats` `Client` or opened with `connect`,
and is used through the `TomMessageBus` contract.

## Class Hierarchy

```text
TomMessageBus  (tom_core_message_bus)
    └── TomNatsMessageBus  (implements)
```

## Classes

### TomNatsMessageBus

A `TomMessageBus` over a NATS server with JetStream: a stream per topic, a
durable pull consumer per consumer group, an unnamed pull consumer per
ephemeral group.

- **Implements:** `TomMessageBus` (from `tom_core_message_bus`)

#### Constructors

```dart
TomNatsMessageBus(
  this.client, {
  this.subjectPrefix = 'tombus',
  this.retention = const Duration(days: 7),
  this.fetchWait = const Duration(milliseconds: 500),
  this.ownsClient = false,
  DateTime Function()? clock,
})
```

A bus over `client`, already connected to a NATS server with JetStream.
`clock` gives a message's publication time; `DateTime.now` by default.

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `connect` | `static Future<TomNatsMessageBus> connect(Uri uri, {String subjectPrefix = 'tombus', Duration retention = const Duration(days: 7), Duration fetchWait = const Duration(milliseconds: 500)})` | Connects to the server at `uri` (one attempt, five-second timeout) and answers a bus owning the connection. Throws `message_bus.nats.unreachable`. |
| `validSubject` | `static String validSubject(String prefix, String topic)` | `<prefix>.<topic>`. Throws `message_bus.nats.invalid_topic` for a topic that is not tokens of letters, digits, `_` and `-` separated by `.`. |
| `streamOf` | `static String streamOf(String topic)` | The stream holding `topic`: `TOMBUS_<sanitised topic, at most 40 characters>_<FNV-1a hash>`. |
| `consumerOf` | `static String consumerOf(String group)` | The durable consumer of `group`: `<sanitised group, at most 40 characters>_<FNV-1a hash>`. |
| `deliveredCount` | `static int deliveredCount(String? replyTo)` | The delivered count in a JetStream reply subject (`$JS.ACK.<stream>.<consumer>.<delivered>...`, also with a domain and account hash); `1` for anything else. |

#### Static Constants

| Constant | Type | Value | Description |
| -------- | ---- | ----- | ----------- |
| `idHeader` | `String` | `Tom-Bus-Id` | The header carrying the message id. |
| `keyHeader` | `String` | `Tom-Bus-Key` | The header carrying the ordering key, when the message has one. |
| `publishedAtHeader` | `String` | `Tom-Bus-Published-At` | The header carrying the publication time, ISO 8601 in UTC. |
| `ephemeralInactivity` | `Duration` | 30 seconds | The `inactive_threshold` of an ephemeral group's consumer: how long the server keeps it without a pull, so a process that stopped without cancelling leaves it this long. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `client` | `Client` | The NATS connection (`dart_nats`). |
| `subjectPrefix` | `String` | The first token of every subject the bus uses. |
| `retention` | `Duration` | How long a stream keeps a message. |
| `fetchWait` | `Duration` | How long one pull waits for a message; the longest a `cancel` waits. |
| `ownsClient` | `bool` | Whether `close` closes `client`. |
| `capabilities` | `TomBusCapabilities` | `const TomBusCapabilities()`: no ordering per key. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `subjectOf` | `String subjectOf(String topic)` | The subject of `topic`: `validSubject(subjectPrefix, topic)`. |
| `publish` | `Future<String> publish<T>(String topic, T payload, {String? key, Map<String, String> headers = const {}, String? id, TomBusCodec<T>? codec})` | Encodes `payload`, creates the topic's stream if needed and publishes inside `TomBusTrace.publishing`, with the id as `Nats-Msg-Id`. Answers the message id (`id`, or a new one). Throws `message_bus.closed`, `message_bus.nats.invalid_topic`, `message_bus.nats.stream_failed`, `message_bus.nats.publish_failed`, `message_bus.payload.not_json`. |
| `subscribe` | `Future<TomBusSubscription> subscribe<T>(String topic, {required String group, required TomBusHandler<T> handler, TomBusCodec<T>? codec, int maxDeliveries = 5, bool ephemeral = false})` | Checks the arguments, creates the topic's stream and the group's durable consumer (deliver policy `new`, explicit acknowledgement) and starts one consumer loop. With `ephemeral` the group's consumer is unnamed, with `inactive_threshold` `ephemeralInactivity`, shared by the group's subscribers in this bus and deleted when the last of them cancels. Throws `message_bus.closed`, `message_bus.subscribe.invalid`, `message_bus.nats.invalid_topic`, `message_bus.nats.stream_failed`, `message_bus.nats.consumer_failed`. |
| `close` | `Future<void> close()` | Refuses further calls, cancels every consumer and closes `client` when `ownsClient`. A second call answers the same future. |

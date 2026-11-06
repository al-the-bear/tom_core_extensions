# Tom Core Message Bus RabbitMQ API Reference: tom_core_message_bus_rabbitmq

The RabbitMQ adapter of the Tom message bus: `TomRabbitMqMessageBus`. One
library, `package:tom_core_message_bus_rabbitmq/tom_core_message_bus_rabbitmq.dart`.

For the mapping onto RabbitMQ, publisher confirms, settling and the error keys,
see [rabbitmq_message_bus.md](../rabbitmq_message_bus.md); for the contract's
types (`TomMessageBus`, `TomBusSubscription`, `TomBusCodec`,
`TomBusException`), `tom_core_message_bus`'s
[API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomRabbitMqMessageBus](#tomrabbitmqmessagebus)

## Overview

Source: `lib/src/rabbitmq_bus.dart`.

| File | Declares |
| ---- | -------- |
| `rabbitmq_bus.dart` | `TomRabbitMqMessageBus` |

The bus is constructed over a `dart_amqp` `Client` or opened with `connect`,
and is used through the `TomMessageBus` contract.

## Class Hierarchy

```text
TomMessageBus  (tom_core_message_bus)
    └── TomRabbitMqMessageBus  (implements)
```

## Classes

### TomRabbitMqMessageBus

A `TomMessageBus` over a RabbitMQ broker (AMQP 0-9-1): a durable fanout
exchange per topic, a durable queue per consumer group, an exclusive
auto-deleted queue per ephemeral group, every publish confirmed by the broker.

- **Implements:** `TomMessageBus` (from `tom_core_message_bus`)

#### Constructors

```dart
factory TomRabbitMqMessageBus(
  Client client, {
  String namePrefix = 'tombus',
  Duration confirmTimeout = const Duration(seconds: 10),
  bool ownsClient = false,
  DateTime Function()? clock,
})
```

A bus over `client`, connected or not. `namePrefix` prefixes every exchange
and queue the bus declares; `confirmTimeout` is how long a publish waits for
the broker's confirmation; with `ownsClient` the bus closes `client` on
`close`. `clock` gives a message's publication time; `DateTime.now` by
default.

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `connect` | `static Future<TomRabbitMqMessageBus> connect(Uri uri, {String namePrefix = 'tombus', Duration confirmTimeout = const Duration(seconds: 10)})` | Connects to the broker at `uri` (`amqp://user:password@host:port/vhost`; one attempt, five-second connect timeout) and answers a bus owning the connection. Throws `message_bus.rabbitmq.unreachable` when the broker cannot be reached or refuses the login. |
| `settingsOf` | `static ConnectionSettings settingsOf(Uri uri)` | The connection settings `uri` names: host (`127.0.0.1` when empty), port (5672 by default), the user and password of its user info, percent-decoded (`guest` / `guest` by default), and the virtual host of its path (`/` by default; `/%2F` is `/` as well). |
| `exchangeOf` | `static String exchangeOf(String prefix, String topic)` | The exchange of `topic`: `<prefix>.<sanitised topic, at most 80 characters>_<FNV-1a hash of the topic>`. |
| `queueOf` | `static String queueOf(String prefix, String topic, String group)` | The durable queue of `group` on `topic`: `<prefix>.<sanitised topic>.<sanitised group>_<FNV-1a hash of topic and group>`. |

#### Static Constants

| Constant | Type | Value | Description |
| -------- | ---- | ----- | ----------- |
| `keyHeader` | `String` | `Tom-Bus-Key` | The header carrying the ordering key, when the message has one. |
| `publishedAtHeader` | `String` | `Tom-Bus-Published-At` | The header carrying the publication time, ISO 8601 in UTC. |
| `attemptHeader` | `String` | `Tom-Bus-Attempt` | The header carrying the attempt a delivery of this copy is, from 1. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `client` | `Client` | The AMQP connection (`dart_amqp`). |
| `namePrefix` | `String` | The first part of every exchange and queue name the bus declares. |
| `confirmTimeout` | `Duration` | How long a publish waits for the broker's confirmation. |
| `ownsClient` | `bool` | Whether `close` closes `client`. |
| `capabilities` | `TomBusCapabilities` | `const TomBusCapabilities()`: no ordering per key. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `publish` | `Future<String> publish<T>(String topic, T payload, {String? key, Map<String, String> headers = const {}, String? id, TomBusCodec<T>? codec})` | Encodes `payload`, declares the topic's exchange if needed and publishes a persistent message inside `TomBusTrace.publishing`, waiting for the broker's confirmation. Answers the message id (`id`, or a new one). Throws `message_bus.closed`, `message_bus.rabbitmq.publish_failed`, `message_bus.payload.not_json`. |
| `subscribe` | `Future<TomBusSubscription> subscribe<T>(String topic, {required String group, required TomBusHandler<T> handler, TomBusCodec<T>? codec, int maxDeliveries = 5, bool ephemeral = false})` | Checks the arguments, declares the topic's exchange and the group's durable queue, binds it, and starts one consumer on a channel of its own with a prefetch of one. With `ephemeral` the queue is exclusive and auto-deleted, named after the group and the bus id. Throws `message_bus.closed`, `message_bus.subscribe.invalid`, `message_bus.rabbitmq.consumer_failed`. |
| `close` | `Future<void> close()` | Refuses further calls, cancels every consumer, closes the publish channel and closes `client` when `ownsClient`. A second call answers the same future. |

# tom_core_message_bus_rabbitmq

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed.

The RabbitMQ adapter of the Tom message bus: `TomRabbitMqMessageBus`, the
`TomMessageBus` contract of [`tom_core_message_bus`](../../core/tom_core_message_bus/README.md)
over a RabbitMQ broker (AMQP 0-9-1) — a durable fanout exchange per topic, a
durable queue per consumer group, publishes confirmed by the broker,
redelivery and dead letters as confirmed publishes followed by the ack of the
delivery. It passes the bus's conformance suite against a real broker.

| Library | Holds |
| ------- | ----- |
| `package:tom_core_message_bus_rabbitmq/tom_core_message_bus_rabbitmq.dart` | `TomRabbitMqMessageBus` |

## Overview

A service that publishes and consumes through `TomMessageBus` runs on RabbitMQ
by constructing this bus instead of the in-memory one; nothing above the
contract changes. The other adapters are
[`tom_core_message_bus_nats`](../tom_core_message_bus_nats/README.md) (NATS
JetStream), [`tom_core_message_bus_kafka`](../tom_core_message_bus_kafka/README.md)
(Kafka through a REST proxy), [`tom_core_message_bus_aws`](../tom_core_message_bus_aws/README.md)
(Amazon SNS and SQS), [`tom_core_message_bus_gcp`](../tom_core_message_bus_gcp/README.md)
(Google Cloud Pub/Sub) and
[`tom_core_message_bus_azure`](../tom_core_message_bus_azure/README.md) (Azure
Service Bus).

The contract is **at least once**, as for every bus: a message is delivered
until a consumer of its group acknowledges it or it is dead-lettered, under the
same id on every delivery. On RabbitMQ that rests on **publisher confirms**:
`publish` answers only once the broker has confirmed that it took the
persistent message, and a redelivery or a dead letter acknowledges the
original delivery only once its copy is confirmed. A failure between the two
repeats the message rather than losing it.

The AMQP client is [`tom_dart_amqp`](https://pub.dev/packages/tom_dart_amqp),
the fork of `dart_amqp`
[al-the-bear/tom_dart_amqp](https://github.com/al-the-bear/tom_dart_amqp)
(branch `tom/0.3.1-fixes`, version `0.3.1+tom.1`) published under its own
name, with upstream's API. The upstream `dart_amqp`
0.3.1 has had no commit since 2024-05-31, and its publisher confirms break
under load: a confirmation with `multiple = true` removed the wrong sequence
number while the handler walked the live key view (upstream issue #132), so a
burst of publishes left some of them unconfirmed and their `publish` calls
waiting until they timed out. Because publisher confirms are what make a
publish at least once here, the adapter takes the fork, which carries that fix
and the error-stream fix of upstream PR #134 (the client's error stream
carries only `Exception`s).

## Installation

```yaml
dependencies:
  tom_core_message_bus: ^0.1.0
  tom_core_message_bus_rabbitmq: ^0.1.0
```

Dart SDK `^3.10.0`. The AMQP client comes with it, as
`tom_dart_amqp: ^0.3.1+tom.1`; code building a `Client` itself imports
`package:tom_dart_amqp/tom_dart_amqp.dart`.

## Features

| Feature | What it does |
| ------- | ------------ |
| `TomRabbitMqMessageBus.connect` | Connects to the broker an `amqp://user:password@host:port/vhost` URI names and answers a bus that owns the connection; an unreachable broker or a refused login is `message_bus.rabbitmq.unreachable`. |
| `TomRabbitMqMessageBus(client, ...)` | A bus over a `dart_amqp` `Client` made by the caller — with whatever settings that client carries. |
| An exchange per topic | A durable fanout exchange, `<namePrefix>.<topic>_<hash>`, declared on first use. |
| A queue per group | A durable queue, `<namePrefix>.<topic>.<group>_<hash>`, bound to the topic's exchange and shared by every consumer of the group. |
| An exclusive queue per ephemeral group | An exclusive, auto-deleted queue of the bus's connection, its name suffixed with the bus id; the broker deletes it when its last consumer cancels. |
| Publisher confirms | Every publish is persistent and answers once the broker confirmed it, within `confirmTimeout` (10 s). |
| Settling | Acknowledge is `basic.ack`; a redelivery is a confirmed copy on the group's queue with the next attempt, then the ack; a dead letter a confirmed publish to `<topic>.dlq`, then the ack. |
| The attempt | Carried in the header `Tom-Bus-Attempt`, written by each copy. |
| Message fields | The id is the AMQP `message-id`; key and publication time travel in the headers `Tom-Bus-Key` and `Tom-Bus-Published-At`; the body is the payload's JSON. |

## Quick start

```dart
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_rabbitmq/tom_core_message_bus_rabbitmq.dart';

Future<void> main() async {
  final bus = await TomRabbitMqMessageBus.connect(
    Uri.parse('amqp://guest:guest@127.0.0.1:5672/'),
  );

  await bus.subscribe<Map<String, Object?>>(
    'orders',
    group: 'billing',
    handler: (delivery) => print('billing ${delivery.payload['order']}'),
  );

  await bus.publish('orders', {'order': 'o-1'});
  // ... the consumer runs until the bus is closed.
  await bus.close();
}
```

A handler that returns acknowledges its delivery; one that throws has it
delivered again, and after `maxDeliveries` attempts (5 unless the subscription
says otherwise) the message is dead-lettered to `orders.dlq`.

## Example

[`example/rabbitmq_message_bus_example.dart`](example/rabbitmq_message_bus_example.dart)
runs two checked steps against a RabbitMQ broker: two consumer groups each
receiving an order, and a message rejected without requeue arriving on the
dead-letter topic with its reason. It reads the broker address from
`TOM_RABBITMQ_TEST_URL` (`amqp://guest:guest@127.0.0.1:5672/` by default).

```bash
docker run -d -p 5672:5672 rabbitmq:3.13-alpine
dart run example/rabbitmq_message_bus_example.dart
```

## Limits

- **No ordering per key.** The bus declares `TomBusCapabilities()`: a
  redelivery is a copy at the back of the group's queue, behind the messages
  published after it.
- **One delivery at a time per consumer.** Each consumer has a channel of its
  own with a prefetch of one, so the broker hands it the next message only once
  the current one is settled.
- **A copy the broker does not confirm is retried.** When the copy of a
  redelivery or a dead letter is not confirmed, the delivery is rejected back
  to the queue after 200 ms, and the broker delivers it again.

## Documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/rabbitmq_message_bus.md](doc/rabbitmq_message_bus.md) | Connecting, the mapping onto RabbitMQ, groups, publisher confirms, settling and dead letters, the client fork, the error keys and running the suite |
| [doc/api/api_summary_rabbitmq_message_bus.md](doc/api/api_summary_rabbitmq_message_bus.md) | Every public member, with signatures |
| [`tom_core_message_bus/doc/message_bus.md`](../../core/tom_core_message_bus/doc/message_bus.md) | The contract this bus keeps, and the conformance suite |

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `tom_dart_amqp` | runtime | The AMQP 0-9-1 client, the fork of `dart_amqp` published as `tom_dart_amqp`: the connection, channels, exchanges, queues, consumers, publisher confirms |
| `tom_core_message_bus` | runtime | `TomMessageBus`, `TomBusMessage`, `TomBusCodec`, `TomBusTrace`, `tomDispatch`, `tomDeadLetter`, `tomCheckSubscription`, `TomBusException` |
| `tom_core_kernel` | runtime | The exception base and `tomLog` |
| `tom_core_server` | dev | `TomBusRelay`, for the relay-through-RabbitMQ test |
| `test`, `lints` | dev | The suites and analysis |

## Status

Version **0.1.0**. `dart test` runs the offline unit suite
(`test/rabbitmq_bus_test.dart`); the tests tagged `rabbitmq` — the bus's
conformance suite, the relay and burst tests, the refusals and the example —
skip themselves without a broker. `tool/run_rabbitmq_tests.sh` starts
`rabbitmq:3.13-management-alpine` in Docker, runs them and fails when every one
of them skipped: 26 pass and MB-C18, the ordering test, is skipped because the
bus declares no ordering per key.

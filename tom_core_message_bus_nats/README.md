# tom_core_message_bus_nats

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed.

The NATS JetStream adapter of the Tom message bus: `TomNatsMessageBus`, the
`TomMessageBus` contract of [`tom_core_message_bus`](../../core/tom_core_message_bus/README.md)
over a NATS server with JetStream — a stream per topic, a durable pull consumer
per consumer group, acknowledgement, redelivery and dead letters mapped onto
JetStream's `+ACK`, `-NAK` and `+TERM`. It passes the bus's conformance suite
against a real server.

| Library | Holds |
| ------- | ----- |
| `package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart` | `TomNatsMessageBus` |

## Overview

A service that publishes and consumes through `TomMessageBus` runs on NATS by
constructing this bus instead of the in-memory one; nothing above the contract
changes. The adapter is built on [`dart_nats`](https://pub.dev/packages/dart_nats),
the maintained pure-Dart NATS client with JetStream support.

The bus has four further adapters in `tom_core_extensions`:
[`tom_core_message_bus_rabbitmq`](../tom_core_message_bus_rabbitmq/README.md)
over RabbitMQ, built on a fork of `dart_amqp` that carries the
publisher-confirm fix the unmaintained upstream lacks,
[`tom_core_message_bus_kafka`](../tom_core_message_bus_kafka/README.md) over
Kafka through a REST proxy,
[`tom_core_message_bus_aws`](../tom_core_message_bus_aws/README.md) over Amazon
SNS and SQS, and [`tom_core_message_bus_gcp`](../tom_core_message_bus_gcp/README.md)
over Google Cloud Pub/Sub.

The contract is **at least once**, as for every bus: a message is delivered
until a consumer of its group acknowledges it or it is dead-lettered, under the
same id on every delivery. The message id is also JetStream's `Nats-Msg-Id`,
so the server drops a publish it has already stored within its duplicate
window — which is what makes the server's `TomBusRelay` safe to repeat a
publish after a crash.

## Installation

```yaml
dependencies:
  tom_core_message_bus: ^0.1.0
  tom_core_message_bus_nats: ^0.1.0
```

Dart SDK `^3.10.0`. The server must run with JetStream enabled
(`nats-server -js`).

## Features

| Feature | What it does |
| ------- | ------------ |
| `TomNatsMessageBus.connect` | Connects to a NATS server and answers a bus that owns the connection; an unreachable server is refused with `message_bus.nats.unreachable`. |
| `TomNatsMessageBus(client, ...)` | A bus over a `dart_nats` `Client` connected by the caller — with whatever TLS and credentials that connection carries. |
| A stream per topic | `TOMBUS_<topic>_<hash>`, holding the subject `<subjectPrefix>.<topic>`, created on first use with the bus's `retention` as its maximum age. |
| A durable consumer per group | A pull consumer with the deliver policy `new` and explicit acknowledgement, shared by every consumer of the group. |
| An unnamed consumer per ephemeral group | A pull consumer without a durable name and with `inactive_threshold` `ephemeralInactivity` (30 s), shared by the group's consumers in one bus and deleted when the last of them cancels; the server removes it after the threshold when a process stops without cancelling. |
| Settling | Each delivery goes through `tomDispatch`; acknowledge is `+ACK`, redelivery `-NAK`, a dead letter a publish to `<topic>.dlq` followed by `+TERM`. |
| The attempt | Read from the delivered count in JetStream's reply subject. |
| Duplicate detection | The message id travels as `Nats-Msg-Id`. |
| Message fields | Id, key and publication time travel in the headers `Tom-Bus-Id`, `Tom-Bus-Key` and `Tom-Bus-Published-At`; the payload is the message's JSON. |

## Quick start

```dart
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart';

Future<void> main() async {
  final bus = await TomNatsMessageBus.connect(
    Uri.parse('nats://127.0.0.1:4222'),
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

[`example/nats_message_bus_example.dart`](example/nats_message_bus_example.dart)
runs two checked steps against a NATS server: two consumer groups each
receiving an order, and a message rejected without requeue arriving on the
dead-letter topic with its reason. It reads the server address from
`TOM_NATS_TEST_URL` (`nats://127.0.0.1:4222` by default).

```bash
docker run -d -p 4222:4222 nats:2.10-alpine -js
dart run example/nats_message_bus_example.dart
```

## Limits

- **No ordering per key.** The bus declares `TomBusCapabilities()`: a NAK
  redelivers one message while the next is already with another consumer of
  the group, so a consumer that needs ordering cannot rely on it here.
- **One message per fetch.** Each consumer pulls one message at a time and
  waits at most `fetchWait` (500 ms) for it; `cancel` therefore waits at most
  that long, and a message fetched after `cancel` is NAKed back to the group.
- **An unconfirmed settlement is redelivered.** An ack, NAK or TERM the server
  does not confirm is logged; the message is then delivered again after the
  consumer's acknowledgement wait, which at least once allows.

## Documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/nats_message_bus.md](doc/nats_message_bus.md) | Connecting, the mapping onto JetStream, groups, settling and dead letters, retention and the duplicate window, the error keys and running the suite |
| [doc/api/api_summary_nats_message_bus.md](doc/api/api_summary_nats_message_bus.md) | Every public member, with signatures |
| [`tom_core_message_bus/doc/message_bus.md`](../../core/tom_core_message_bus/doc/message_bus.md) | The contract this bus keeps, and the conformance suite |

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `dart_nats` | runtime | The NATS client: the connection, JetStream streams, durable pull consumers, ack / nak / term |
| `tom_core_message_bus` | runtime | `TomMessageBus`, `TomBusMessage`, `TomBusCodec`, `TomBusTrace`, `tomDispatch`, `tomDeadLetter`, `tomCheckSubscription`, `TomBusException` |
| `tom_core_kernel` | runtime | The exception base and `tomLog` |
| `tom_core_server` | dev | `TomBusRelay` and `TomBusInvalidationChannel`, for the relay-through-NATS and invalidation tests |
| `test`, `lints` | dev | The suites and analysis |

## Status

Version **0.1.0**. `dart test` runs the offline unit suite
(`test/nats_bus_test.dart`); the tests tagged `nats` — the bus's conformance
suite, the relay tests, the refusals and the example — skip themselves without
a server. `tool/run_nats_tests.sh` starts `nats:2.10-alpine` with JetStream in
Docker, runs them and fails when every one of them skipped: 27 pass and MB-C18,
the ordering test, is skipped because the bus declares no ordering per key.
Among them is NB-V1 (`test/nats_invalidation_test.dart`): the server's
`TomBusInvalidationChannel` between two isolates over NATS, a grant revoked on
one node refused on the other within the channel's bound.

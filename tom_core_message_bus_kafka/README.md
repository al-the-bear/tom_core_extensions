# tom_core_message_bus_kafka

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed.

The Kafka adapter of the Tom message bus: `TomKafkaMessageBus`, the
`TomMessageBus` contract of [`tom_core_message_bus`](../../core/tom_core_message_bus/README.md)
over a Kafka cluster, reached through the Kafka REST Proxy API — a Kafka topic
per topic, a Kafka consumer group per consumer group, acknowledgement as an
offset commit, redelivery in place, and ordering per key. It passes the bus's
conformance suite, the ordering test included, against a real cluster.

| Library | Holds |
| ------- | ----- |
| `package:tom_core_message_bus_kafka/tom_core_message_bus_kafka.dart` | `TomKafkaMessageBus` |

## Overview

A service that publishes and consumes through `TomMessageBus` runs on Kafka by
constructing this bus instead of the in-memory one; nothing above the contract
changes. The other adapters are
[`tom_core_message_bus_nats`](../tom_core_message_bus_nats/README.md) (NATS
JetStream), [`tom_core_message_bus_rabbitmq`](../tom_core_message_bus_rabbitmq/README.md)
(RabbitMQ), [`tom_core_message_bus_aws`](../tom_core_message_bus_aws/README.md)
(Amazon SNS and SQS), [`tom_core_message_bus_gcp`](../tom_core_message_bus_gcp/README.md)
(Google Cloud Pub/Sub) and
[`tom_core_message_bus_azure`](../tom_core_message_bus_azure/README.md) (Azure
Service Bus).

The bus speaks HTTP to a **Confluent REST Proxy** in front of the cluster:
API v2 for records and consumer instances, v3 for naming the cluster and
creating topics, which v2 cannot. The requests go through `tom_core_kernel`'s
`TomResilientClient` — a timeout per attempt, retries of idempotent calls, a
circuit breaker and a bulkhead per destination — unless a client is passed.
The cluster behind the proxy may be Kafka or Redpanda; Redpanda's own HTTP
proxy is not enough (see [Limits](#limits)).

The contract is **at least once**, as for every bus: a message is delivered
until a consumer of its group acknowledges it or it is dead-lettered, under the
same id on every delivery. Kafka has no acknowledgement per message, so
acknowledging commits the record's offset, and a redelivery is made in place,
before the records behind it. That keeps a key's records in order, and the bus
declares **ordering per key**.

## Installation

```yaml
dependencies:
  tom_core_message_bus: ^0.1.0
  tom_core_message_bus_kafka: ^0.1.0
```

Dart SDK `^3.10.0`. The bus needs a Confluent REST Proxy (`cp-kafka-rest`) in
front of the cluster.

## Features

| Feature | What it does |
| ------- | ------------ |
| `TomKafkaMessageBus.connect` | Answers a bus over the REST proxy at a URI once the proxy named its cluster; a proxy that does not is refused with `message_bus.kafka.unreachable`. |
| `TomKafkaMessageBus(proxy, ...)` | A bus over the proxy at `proxy`, with the HTTP client given or a `TomResilientClient`. |
| A topic per topic | A Kafka topic of the same name, created on first use with `partitions` partitions (3) and the optional `replicationFactor`; a topic that exists is taken as it is. |
| A consumer group per group | A Kafka consumer group of the same name, starting at the end of the topic, with auto commit off. |
| A consumer group per ephemeral group | `<group>.<bus id>`, a group of the bus's own that commits no offset. |
| A consumer instance per subscription | Created in the proxy; `subscribe` answers once the instance holds partitions and its position is committed. |
| Settling | Acknowledge commits the record's offset; a redelivery handles the record again in place; a dead letter publishes to `<topic>.dlq`, then commits. |
| The record | Keyed by the message's key, its value an envelope `{id, publishedAt, headers, payload}`. |

## Quick start

```dart
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_kafka/tom_core_message_bus_kafka.dart';

Future<void> main() async {
  final bus = await TomKafkaMessageBus.connect(
    Uri.parse('http://127.0.0.1:8082'),
  );

  await bus.subscribe<Map<String, Object?>>(
    'orders',
    group: 'billing',
    handler: (delivery) => print('billing ${delivery.payload['order']}'),
  );

  await bus.publish('orders', {'order': 'o-1'}, key: 'customer-7');
  // ... the consumer runs until the bus is closed.
  await bus.close();
}
```

A handler that returns acknowledges its delivery; one that throws has it
handled again, and after `maxDeliveries` attempts (5 unless the subscription
says otherwise) the message is dead-lettered to `orders.dlq`. The messages of
one key reach the group in the order they were published.

## Example

[`example/kafka_message_bus_example.dart`](example/kafka_message_bus_example.dart)
runs two checked steps against a REST proxy: two consumer groups each receiving
an order, and a message rejected without requeue arriving on the dead-letter
topic with its reason. It reads the proxy address from
`TOM_KAFKA_REST_TEST_URL` (`http://127.0.0.1:8082` by default);
`tool/run_kafka_tests.sh` shows the two containers it needs.

```bash
dart run example/kafka_message_bus_example.dart
```

## Limits

- **Confluent REST Proxy, not Redpanda's HTTP proxy.** Redpanda's own proxy
  serves no consumer assignments, refuses `auto.offset.reset` `latest` and
  creates no topics; a deployment runs Confluent REST Proxy in front of its
  cluster, Kafka or Redpanda.
- **One bus, one proxy.** A consumer instance lives in the proxy that created
  it, so a deployment with several proxies routes each bus to one of them.
- **A burst of concurrent publishes meets the bulkhead.** The default
  `TomResilientClient` limits the concurrent calls to one destination; hundreds
  of publishes at once are refused with `http.client.bulkhead_full`, wrapped in
  `message_bus.kafka.publish_failed`. Publish in sequence, or pass a client
  with another policy.
- **A redelivery holds its partition.** The attempts of a delivery are made in
  place, `redeliveryDelay` (100 ms) apart, and the records behind it in the
  partition wait until it is acknowledged or dead-lettered.

## Documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/kafka_message_bus.md](doc/kafka_message_bus.md) | Connecting, the REST proxy, the mapping onto Kafka, groups, settling and dead letters, ordering per key, the error keys and running the suite |
| [doc/api/api_summary_kafka_message_bus.md](doc/api/api_summary_kafka_message_bus.md) | Every public member, with signatures |
| [`tom_core_message_bus/doc/message_bus.md`](../../core/tom_core_message_bus/doc/message_bus.md) | The contract this bus keeps, and the conformance suite |

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `http` | runtime | The requests to the REST proxy |
| `tom_core_message_bus` | runtime | `TomMessageBus`, `TomBusMessage`, `TomBusCodec`, `TomBusTrace`, `tomDispatch`, `tomDeadLetter`, `tomCheckSubscription`, `TomBusException` |
| `tom_core_kernel` | runtime | `TomResilientClient`, the exception base and `tomLog` |
| `tom_core_server` | dev | `TomBusRelay`, for the relay-through-Kafka test |
| `test`, `lints` | dev | The suites and analysis |

## Status

Version **0.1.0**. `dart test` runs the offline unit suite
(`test/kafka_bus_test.dart`, against a mock proxy); the tests tagged `kafka` —
the bus's conformance suite, the relay and shared-group tests and the example —
skip themselves without a proxy. `tool/run_kafka_tests.sh` starts Redpanda and
Confluent REST Proxy in Docker, runs them and fails when every one of them
skipped: all 23 pass, MB-C18, the ordering test, among them.

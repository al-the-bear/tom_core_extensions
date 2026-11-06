# tom_core_message_bus_aws

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed.

The AWS adapter of the Tom message bus: `TomAwsMessageBus`, the
`TomMessageBus` contract of [`tom_core_message_bus`](../../core/tom_core_message_bus/README.md)
over Amazon SNS and SQS, reached through their HTTP APIs — an SNS topic per
topic, a standard SQS queue per consumer group, acknowledgement as a
`DeleteMessage`, redelivery through the queue's visibility. It passes the bus's
conformance suite against LocalStack; the ordering test is skipped, because
standard queues do not order.

| Library | Holds |
| ------- | ----- |
| `package:tom_core_message_bus_aws/tom_core_message_bus_aws.dart` | `TomAwsMessageBus` |

## Overview

A service that publishes and consumes through `TomMessageBus` runs on SNS and
SQS by constructing this bus instead of the in-memory one; nothing above the
contract changes. The other adapters are
[`tom_core_message_bus_nats`](../tom_core_message_bus_nats/README.md) (NATS
JetStream), [`tom_core_message_bus_rabbitmq`](../tom_core_message_bus_rabbitmq/README.md)
(RabbitMQ), [`tom_core_message_bus_kafka`](../tom_core_message_bus_kafka/README.md)
(Kafka through a REST proxy) and
[`tom_core_message_bus_gcp`](../tom_core_message_bus_gcp/README.md) (Google
Cloud Pub/Sub).

The bus speaks HTTP to both services, with no AWS SDK: the **SQS JSON
protocol** (`application/x-amz-json-1.0`) and the **SNS query protocol**, every
request signed with Signature Version 4 by `tom_core_server`'s
`TomAwsV4Signer`. The credentials come from a `TomAwsCredentialsSource`, asked
for every request — static keys, or a role's temporary credentials. The
requests go through `tom_core_kernel`'s `TomResilientClient` unless a client is
passed.

The contract is **at least once**, as for every bus: a message is delivered
until a consumer of its group acknowledges it or it is dead-lettered, under the
same id on every delivery. Standard SQS queues neither order nor deduplicate:
the bus does not declare ordering per key, and a message can, rarely, be
delivered twice.

## Installation

```yaml
dependencies:
  tom_core_message_bus: ^0.1.0
  tom_core_message_bus_aws: ^0.1.0
```

Dart SDK `^3.10.0`. The bus needs SNS and SQS in one region — AWS, a VPC
endpoint, or an emulator such as LocalStack.

## Features

| Feature | What it does |
| ------- | ------------ |
| `TomAwsMessageBus(region:, credentials:, ...)` | A bus in a region, signing with a credentials source; the endpoints default to the region's public ones. |
| `TomAwsMessageBus.withKeys` | A bus with static keys (and an optional session token); one `endpoint` serves both SNS and SQS. |
| An SNS topic per topic | A standard topic, `<namePrefix>-<topic>-<hash>`, created on first use; `CreateTopic` answers an existing topic's ARN. |
| An SQS queue per group | A standard queue, `<namePrefix>-<topic>-<group>-<hash>`, subscribed to the topic with raw message delivery, its policy letting only that topic send. |
| A queue per ephemeral group | A queue of the bus's own, under a fresh name each time, unsubscribed and deleted when its last consumer cancels. |
| A polling loop per subscription | Long-polls the group's queue, one message at a time, waiting at most `fetchWait` (whole seconds, from 1 to 20). |
| Settling | Acknowledge is `DeleteMessage`; a redelivery is `ChangeMessageVisibility` to 0; a dead letter publishes to `<topic>.dlq`'s SNS topic, then deletes. |
| The message | One JSON envelope in the body, `{id, key, publishedAt, headers, payload}`. |

## Quick start

```dart
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_aws/tom_core_message_bus_aws.dart';

Future<void> main() async {
  final bus = TomAwsMessageBus.withKeys(
    region: 'eu-central-1',
    accessKeyId: 'AKIA...',
    secretAccessKey: '...',
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
says otherwise) the message is dead-lettered to `orders.dlq`. On an instance or
task role, pass the role's credentials source instead of keys:

```dart
final bus = TomAwsMessageBus(
  region: 'eu-central-1',
  credentials: roleCredentials, // a TomAwsCredentialsSource
);
```

## Example

[`example/aws_message_bus_example.dart`](example/aws_message_bus_example.dart)
runs two checked steps against SNS and SQS: two consumer groups each receiving
an order, and a message rejected without requeue arriving on the dead-letter
topic with its reason. It reads the endpoint from `TOM_AWS_TEST_ENDPOINT`
(`http://127.0.0.1:4566` by default) and signs with the keys `test`/`test`,
which LocalStack accepts; `tool/run_aws_tests.sh` shows the container it needs.

```bash
dart run example/aws_message_bus_example.dart
```

## Limits

- **No ordering per key.** Standard queues hand messages to the group's
  consumers in no fixed order; `capabilities.orderedPerKey` is `false` and the
  ordering test, MB-C18, is skipped.
- **A rare duplicate.** A standard queue can deliver a message twice; a
  consumer that must not act twice keeps the ids it handled.
- **A handler longer than the visibility timeout sees its message again.** A
  received message stays hidden from the group's other consumers for
  `visibilityTimeout` (30 seconds); a handler that runs longer has it delivered
  a second time.
- **A burst of concurrent publishes meets the bulkhead.** The default
  `TomResilientClient` limits the concurrent calls to one destination; publish
  in sequence, or pass a client with another policy.

## Documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/aws_message_bus.md](doc/aws_message_bus.md) | Constructing the bus, the two HTTP APIs and signing, the mapping onto SNS and SQS, groups, settling and dead letters, why there is no ordering per key, the error keys and running the suite |
| [doc/api/api_summary_aws_message_bus.md](doc/api/api_summary_aws_message_bus.md) | Every public member, with signatures |
| [`tom_core_message_bus/doc/message_bus.md`](../../core/tom_core_message_bus/doc/message_bus.md) | The contract this bus keeps, and the conformance suite |

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `http` | runtime | The requests to SNS and SQS |
| `crypto` | runtime | The SHA-256 of a request body, for its signature |
| `tom_core_message_bus` | runtime | `TomMessageBus`, `TomBusMessage`, `TomBusCodec`, `TomBusTrace`, `tomDispatch`, `tomDeadLetter`, `tomCheckSubscription`, `TomBusException` |
| `tom_core_kernel` | runtime | `TomResilientClient` and `tomLog` |
| `tom_core_server` | runtime | `TomAwsV4Signer`, `TomAwsCredentials` and `TomAwsCredentialsSource`; `TomBusRelay` for the relay test |
| `test`, `lints` | dev | The suites and analysis |

## Status

Version **0.1.0**. `dart test` runs the offline unit suite
(`test/aws_bus_test.dart`, against a mock client); the tests tagged `aws` — the
bus's conformance suite, the relay test and the example — skip themselves
without an endpoint. `tool/run_aws_tests.sh` starts LocalStack in Docker, runs
them and fails when every one of them skipped: 21 pass and 1 is skipped,
MB-C18, the ordering test.

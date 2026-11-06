# tom_core_message_bus_gcp

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed.

The Google Cloud adapter of the Tom message bus: `TomPubSubMessageBus`, the
`TomMessageBus` contract of [`tom_core_message_bus`](../../core/tom_core_message_bus/README.md)
over Google Cloud Pub/Sub, reached through its REST API — a Pub/Sub topic per
topic, a subscription per consumer group with message ordering enabled,
redelivery in place, and ordering per key. It passes the bus's conformance
suite, the ordering test included, against the Pub/Sub emulator.

| Library | Holds |
| ------- | ----- |
| `package:tom_core_message_bus_gcp/tom_core_message_bus_gcp.dart` | `TomPubSubMessageBus`, `TomGcpTokenSource`, `PubSubError` |

## Overview

A service that publishes and consumes through `TomMessageBus` runs on Pub/Sub
by constructing this bus instead of the in-memory one; nothing above the
contract changes. The other adapters are
[`tom_core_message_bus_nats`](../tom_core_message_bus_nats/README.md) (NATS
JetStream), [`tom_core_message_bus_rabbitmq`](../tom_core_message_bus_rabbitmq/README.md)
(RabbitMQ), [`tom_core_message_bus_kafka`](../tom_core_message_bus_kafka/README.md)
(Kafka through a REST proxy) and
[`tom_core_message_bus_aws`](../tom_core_message_bus_aws/README.md) (Amazon SNS
and SQS).

The bus speaks Pub/Sub's REST API (`v1`) over HTTP, with no Google SDK. Every
request carries the access token of a `TomGcpTokenSource`: a service account's,
minted with the OAuth JWT-bearer grant (`TomPubSubMessageBus.serviceAccount`),
or the metadata server's on Compute Engine, GKE or Cloud Run
(`TomPubSubMessageBus.metadataServer`). The emulator takes none. The requests
go through `tom_core_kernel`'s `TomResilientClient` unless a client is passed.

The contract is **at least once**, as for every bus: a message is delivered
until a consumer of its group acknowledges it or it is dead-lettered, under the
same id on every delivery. A redelivery is made in place, before the consumer
pulls the next message, and Pub/Sub's message ordering hands a key's messages
over one at a time, so the bus declares **ordering per key**.

## Installation

```yaml
dependencies:
  tom_core_message_bus: ^0.1.0
  tom_core_message_bus_gcp: ^0.1.0
```

Dart SDK `^3.10.0`. The bus needs a Google Cloud project with the Pub/Sub API,
or the Pub/Sub emulator.

## Features

| Feature | What it does |
| ------- | ------------ |
| `TomPubSubMessageBus(projectId:, token:, ...)` | A bus in a project, with a token source (none for the emulator) and the global endpoint unless another is given. |
| `TomPubSubMessageBus.serviceAccount` | A bus authenticated with a service-account key file, in the key's project unless another is named. |
| `TomPubSubMessageBus.metadataServer` | A token source asking the host's metadata server, its token cached until a minute before it expires. |
| A topic per topic | A Pub/Sub topic, `<namePrefix>-<topic>-<hash>`, created on first use; one that exists is taken. |
| A subscription per group | `<namePrefix>-<topic>-<group>-<hash>`, with message ordering enabled and an ack deadline of `ackDeadline` (60 s). |
| A subscription per ephemeral group | A subscription of the bus's own, deleted when its last consumer cancels. |
| A polling loop per subscription | Pulls one message at a time with `returnImmediately`, pausing `fetchWait` (500 ms) when the pull is empty. |
| Settling | Acknowledge is `acknowledge`; a redelivery handles the message again in place, its ack deadline extended; a dead letter publishes to `<topic>.dlq`, then acknowledges. |
| The message | One JSON envelope in the message data, base64, `{id, key, publishedAt, headers, payload}`; the message's key as its `orderingKey`. |

## Quick start

```dart
import 'dart:io';

import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_gcp/tom_core_message_bus_gcp.dart';

Future<void> main() async {
  final bus = TomPubSubMessageBus.serviceAccount(
    File('service-account.json').readAsStringSync(),
    endpoint: Uri.parse('https://europe-west1-pubsub.googleapis.com/'),
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
one key reach the group in the order they were published. On Google Cloud's
own hosts, the metadata server supplies the token instead:

```dart
final bus = TomPubSubMessageBus(
  projectId: 'my-project',
  token: TomPubSubMessageBus.metadataServer(),
);
```

## Example

[`example/gcp_message_bus_example.dart`](example/gcp_message_bus_example.dart)
runs two checked steps against Pub/Sub: two consumer groups each receiving an
order, and a message rejected without requeue arriving on the dead-letter topic
with its reason. It reads the endpoint from `TOM_PUBSUB_TEST_ENDPOINT`
(`http://127.0.0.1:8085` by default) and sends no token, which only the
emulator accepts; `tool/run_gcp_tests.sh` shows the container it needs.

```bash
dart run example/gcp_message_bus_example.dart
```

## Limits

- **Polling, not streaming.** A consumer pulls with `returnImmediately` and
  pauses `fetchWait` when nothing is there, so a message waits up to
  `fetchWait` on an idle consumer, and a `cancel` answers within it.
- **Ordered publishing wants a regional endpoint.** The default endpoint is the
  global `https://pubsub.googleapis.com/`; a deployment that relies on ordering
  per key passes a regional one.
- **A redelivery holds its key.** The attempts of a delivery are made in place,
  `redeliveryDelay` (100 ms) apart, and the key's next message waits until it
  is acknowledged or dead-lettered.
- **A burst of concurrent publishes meets the bulkhead.** The default
  `TomResilientClient` limits the concurrent calls to one destination; publish
  in sequence, or pass a client with another policy.

## Documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/gcp_message_bus.md](doc/gcp_message_bus.md) | Constructing the bus, authentication, the REST API, the mapping onto Pub/Sub, groups, settling and dead letters, ordering per key, the error keys and running the suite |
| [doc/api/api_summary_gcp_message_bus.md](doc/api/api_summary_gcp_message_bus.md) | Every public member, with signatures |
| [`tom_core_message_bus/doc/message_bus.md`](../../core/tom_core_message_bus/doc/message_bus.md) | The contract this bus keeps, and the conformance suite |

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `http` | runtime | The requests to Pub/Sub and the metadata server |
| `tom_core_message_bus` | runtime | `TomMessageBus`, `TomBusMessage`, `TomBusCodec`, `TomBusTrace`, `tomDispatch`, `tomDeadLetter`, `tomCheckSubscription`, `TomBusException` |
| `tom_core_kernel` | runtime | `TomResilientClient` and `tomLog` |
| `tom_core_server` | runtime | `TomFcmServiceAccountCredential`, the Google service-account token flow; `TomBusRelay` for the relay test |
| `test`, `lints` | dev | The suites and analysis |

## Status

Version **0.1.0**. `dart test` runs the offline unit suite
(`test/gcp_bus_test.dart`, against a mock client); the tests tagged `gcp` — the
bus's conformance suite, the relay test and the example — skip themselves
without an endpoint. `tool/run_gcp_tests.sh` starts the Pub/Sub emulator in
Docker, runs them and fails when every one of them skipped: all 22 pass, MB-C18,
the ordering test, among them.

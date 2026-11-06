# tom_core_message_bus_azure

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed.

The Azure adapter of the Tom message bus: `TomServiceBusMessageBus`, the
`TomMessageBus` contract of [`tom_core_message_bus`](../../core/tom_core_message_bus/README.md)
over Azure Service Bus — a topic per topic, a subscription per consumer group,
acknowledgement as a complete, redelivery as an abandon. Messages travel over
AMQP 1.0, through a minimal AMQP 1.0 client of the package's own
(`AmqpConnection`), since Dart has no maintained one; topics and subscriptions
are created through the management API. It passes the bus's conformance suite
against the Service Bus emulator; the ordering test is skipped.

| Library | Holds |
| ------- | ----- |
| `package:tom_core_message_bus_azure/tom_core_message_bus_azure.dart` | `TomServiceBusMessageBus`, `TomServiceBusSasKey`, and the AMQP client: `AmqpConnection`, `AmqpSender`, `AmqpReceiver`, `AmqpDelivery`, `AmqpMessage`, the outcomes and the type codec |

## Overview

A service that publishes and consumes through `TomMessageBus` runs on Service
Bus by constructing this bus instead of the in-memory one; nothing above the
contract changes. The other adapters are
[`tom_core_message_bus_nats`](../tom_core_message_bus_nats/README.md) (NATS
JetStream), [`tom_core_message_bus_rabbitmq`](../tom_core_message_bus_rabbitmq/README.md)
(RabbitMQ), [`tom_core_message_bus_kafka`](../tom_core_message_bus_kafka/README.md)
(Kafka through a REST proxy), [`tom_core_message_bus_aws`](../tom_core_message_bus_aws/README.md)
(Amazon SNS and SQS) and [`tom_core_message_bus_gcp`](../tom_core_message_bus_gcp/README.md)
(Google Cloud Pub/Sub).

Service Bus serves messaging over AMQP 1.0, and its emulator over AMQP alone.
The package's `AmqpConnection` is the part of AMQP 1.0 a message bus needs:
the type system, framing, SASL `PLAIN` and `ANONYMOUS`, one session per
connection, sending links that send unsettled and complete on the peer's
outcome, receiving links granted credit one message at a time and settled with
an outcome, the claims-based security exchange (`putToken` on `$cbs`), and
heartbeats against the peer's idle timeout. The bus authenticates with a shared
access key — SASL `PLAIN`, or a shared access signature per entity through
claims-based security — or with a Microsoft Entra ID token put through
claims-based security; the management API takes the matching signature or
bearer token.

The contract is **at least once**, as for every bus: a message is delivered
until a consumer of its group acknowledges it or it is dead-lettered, under the
same id on every delivery.

## Installation

```yaml
dependencies:
  tom_core_message_bus: ^0.1.0
  tom_core_message_bus_azure: ^0.1.0
```

Dart SDK `^3.10.0`. The bus needs a Service Bus namespace of the Standard tier
or above (Basic has no topics), or the Service Bus emulator.

## Features

| Feature | What it does |
| ------- | ------------ |
| `TomServiceBusMessageBus(host:, credential:, ...)` | A bus on a namespace; AMQP over TLS on 5671 and the management API at `https://<host>/` by default. |
| `TomServiceBusSasKey` | A shared access key: SASL `PLAIN`, or with `claimsBased` a signature put per entity on `$cbs`; shared access signatures on the management API. |
| `TomServiceBusTokenCredential` | A Microsoft Entra ID credential: the application's function answering an access token, put per entity on `$cbs` and renewed before it expires; a bearer token on the management API. |
| `TomServiceBusMessageBus.fromConnectionString` | A bus from a Service Bus connection string; one with `UseDevelopmentEmulator=true` addresses the emulator (AMQP on 5672 without TLS, the management API over HTTP on 5300). |
| A topic per topic | `<namePrefix>-<topic>-<hash>`, created through the management API on first use; one that exists already is taken as it is. |
| A subscription per group | `<group>-<hash>`, at most 50 characters, with the bus's `lockDuration` and `maxDeliveryCount`. |
| A subscription per ephemeral group | A subscription of the bus's own, under a fresh name, deleted when its last consumer cancels — and by Service Bus after `ephemeralIdle` without a consumer. |
| A receiver link per consumer | Granted one message at a time; competing consumers of a group are links on the same subscription. |
| Settling | Acknowledge is `accepted` (complete); a redelivery is `modified` with `delivery-failed` (abandon), which raises the message's delivery count; a dead letter publishes to `<topic>.dlq`'s topic, then completes. |
| The message | One JSON envelope in a `data` section, `{id, key, publishedAt, headers, payload}`; `message-id` and `creation-time` set from it. |

## Quick start

```dart
import 'package:tom_core_message_bus/tom_core_message_bus.dart';
import 'package:tom_core_message_bus_azure/tom_core_message_bus_azure.dart';

Future<void> main() async {
  final bus = TomServiceBusMessageBus.fromConnectionString(
    'Endpoint=sb://my-namespace.servicebus.windows.net/;'
    'SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=...',
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

[`example/azure_message_bus_example.dart`](example/azure_message_bus_example.dart)
runs two checked steps against Service Bus: two consumer groups each receiving
an order, and a message rejected without requeue arriving on the dead-letter
topic with its reason. It reads the connection string from
`TOM_AZURE_SB_CONNECTION` (the emulator's by default) and the ports from
`TOM_AZURE_SB_AMQP_PORT` and `TOM_AZURE_SB_HTTP_PORT`;
`tool/run_azure_tests.sh` starts the emulator it needs.

```bash
dart run example/azure_message_bus_example.dart
```

## Limits

- **No ordering per key.** Ordering on Service Bus needs sessions, which the
  bus does not use; `capabilities.orderedPerKey` is `false` and the ordering
  test, MB-C18, is skipped.
- **At most `maxDeliveryCount` deliveries.** Service Bus moves a message to the
  subscription's own dead-letter queue after `maxDeliveryCount` deliveries (10
  by default; at most 10 on the emulator, 2000 on Service Bus). A consumer
  passing a larger `maxDeliveries` gets at most `maxDeliveryCount` deliveries,
  and the message then sits in the subscription's dead-letter queue rather than
  on `<topic>.dlq`; raise `maxDeliveryCount` with it.
- **A handler longer than the lock sees its message again.** A received
  message is locked to its consumer for `lockDuration` (30 seconds); a handler
  that runs longer has it delivered again.
- **Entra ID tokens are the application's to obtain.** The bus asks a
  `TomServiceBusTokenCredential` for a token and puts it; acquiring it — a
  service principal, a managed identity — is outside the package. The emulator
  checks no token, so the Entra ID path is measured with a scripted peer and the
  claims-based path with shared access signatures.
- **One connection, one session.** All senders and receivers of a bus share
  one AMQP connection; a connection that fails is opened again for the next
  send, and each consumer attaches again after `retryDelay`.

## Documentation

| Document | Covers |
| -------- | ------ |
| [doc/index.md](doc/index.md) | The catalogue of this package's documentation |
| [doc/azure_message_bus.md](doc/azure_message_bus.md) | Constructing the bus, the AMQP client, the management API, the mapping onto Service Bus, groups, settling and dead letters, the limits, the error keys and running the suite |
| [doc/api/api_summary_azure_message_bus.md](doc/api/api_summary_azure_message_bus.md) | Every public member, with signatures |
| [`tom_core_message_bus/doc/message_bus.md`](../../core/tom_core_message_bus/doc/message_bus.md) | The contract this bus keeps, and the conformance suite |

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `http` | runtime | The management API's requests |
| `crypto` | runtime | The HMAC-SHA256 of a shared access signature |
| `tom_core_message_bus` | runtime | `TomMessageBus`, `TomBusMessage`, `TomBusCodec`, `TomBusTrace`, `tomDispatch`, `tomDeadLetter`, `tomCheckSubscription`, `TomBusException` |
| `tom_core_kernel` | runtime | `TomResilientClient` and `tomLog` |
| `tom_core_server` | dev | `TomBusRelay`, for the relay test |
| `test`, `lints` | dev | The suites and analysis |

## Status

Version **0.1.0**. `dart test` runs the offline suites — the codec, the message
format, the shared access signature, the names and the management API
(`test/amqp_codec_test.dart`, ZB-U1 to ZB-U10, ZB-U14, ZB-U15), and the
connection and the claims-based exchange against a scripted AMQP peer in the
same process (`test/amqp_connection_test.dart`, ZB-U11 to ZB-U13); the tests
tagged `azure` — the bus's conformance suite, authenticated with SASL `PLAIN`
and authorized through claims-based security, the relay test and the example —
skip themselves without a connection string. `tool/run_azure_tests.sh` starts
the emulator in Docker, runs them and fails when every one of them skipped: 40
pass and 2 are skipped, MB-C18, the ordering test, in each mode.

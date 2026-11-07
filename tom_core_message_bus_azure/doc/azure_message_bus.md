# Azure Message Bus

`TomServiceBusMessageBus` keeps the `TomMessageBus` contract of
`tom_core_message_bus` on Azure Service Bus. Messages travel over AMQP 1.0
through the package's own minimal AMQP 1.0 client; topics and subscriptions
are created through Service Bus's management API. This page covers how the bus
is constructed, the AMQP client, how the contract maps onto Service Bus, the
limits, the error keys and running the suite.

## Table of Contents

- [Constructing the Bus](#constructing-the-bus)
  - [From a connection string](#from-a-connection-string)
  - [The emulator](#the-emulator)
- [Authentication](#authentication)
  - [Claims-based security](#claims-based-security)
- [The AMQP Client](#the-amqp-client)
  - [What it implements](#what-it-implements)
  - [Handles are each side's own](#handles-are-each-sides-own)
- [The Management API](#the-management-api)
- [The Mapping onto Service Bus](#the-mapping-onto-service-bus)
  - [Names](#names)
  - [The message on the wire](#the-message-on-the-wire)
- [Consumer Groups](#consumer-groups)
  - [Ephemeral groups](#ephemeral-groups)
- [Settling and Dead Letters](#settling-and-dead-letters)
  - [The delivery limit](#the-delivery-limit)
  - [The lock](#the-lock)
- [No Ordering per Key](#no-ordering-per-key)
- [Publishing from the Bus Relay](#publishing-from-the-bus-relay)
- [Connections and Closing](#connections-and-closing)
- [Error Keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## Constructing the Bus

```dart
final bus = TomServiceBusMessageBus(
  host: 'my-namespace.servicebus.windows.net',
  credential: const TomServiceBusSasKey('RootManageSharedAccessKey', '...'),
);
```

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `host` | — | The namespace's host name |
| `credential` | — | A `TomServiceBusSasKey` or a `TomServiceBusTokenCredential` — see [Authentication](#authentication) |
| `amqpPort` | `5671` | The AMQP port |
| `secure` | `true` | AMQP over TLS |
| `managementEndpoint` | `https://<host>/` | The management API's base address |
| `namePrefix` | `tombus` | The first part of every topic name |
| `lockDuration` | 30 seconds | How long a received message is locked to its consumer |
| `maxDeliveryCount` | `10` | The subscriptions' own delivery limit — see [The delivery limit](#the-delivery-limit) |
| `ephemeralIdle` | 5 minutes | How long Service Bus keeps an ephemeral group's subscription after its consumers went away without cancelling |
| `retryDelay` | 1 second | How long a consumer waits before attaching again after its link or connection failed |
| `httpClient` | a `TomResilientClient` | The client of the management API, closed by `close` when the bus made it |
| `clock` | `DateTime.now` | The time messages are stamped with and signatures expire from |

### From a connection string

`TomServiceBusMessageBus.fromConnectionString` reads the connection string the
Azure portal shows —
`Endpoint=sb://<host>/;SharedAccessKeyName=<name>;SharedAccessKey=<key>` —
and refuses one without the three
(`message_bus.azure.connection_string_invalid`).

### The emulator

A connection string with `UseDevelopmentEmulator=true` addresses the Service
Bus emulator: AMQP without TLS on `amqpPort` (5672 by default) and the
management API over HTTP on `managementPort` (5300 by default). The emulator
serves messaging over AMQP only — its HTTP port answers the management API and
refuses message operations — which is why the bus speaks AMQP rather than
Service Bus's REST API. `tool/emulator/docker-compose.yaml` runs it with the
SQL Edge database it keeps its state in.

## Authentication

| Credential | The AMQP connection | The management API |
| ---------- | ------------------- | ------------------ |
| `TomServiceBusSasKey(keyName, key)` | SASL `PLAIN` with the key name and the key | A shared access signature for the request's resource |
| `TomServiceBusSasKey(keyName, key, claimsBased: true)` | SASL `ANONYMOUS`, then a shared access signature per entity on `$cbs` (`servicebus.windows.net:sastoken`) | A shared access signature |
| `TomServiceBusTokenCredential(token, lifetime:)` | SASL `ANONYMOUS`, then the Microsoft Entra ID token per entity on `$cbs` (`jwt`) | `Authorization: Bearer <token>` |

A shared access signature (`TomServiceBusSasKey.signature`) is an HMAC-SHA256
over the URL-encoded resource and the expiry, valid for an hour. A
`TomServiceBusTokenCredential` takes the application's function answering an
access token for Service Bus (scope `https://servicebus.azure.net/.default`);
how the token is obtained — a service principal, a managed identity — is the
application's.

### Claims-based security

With a claims-based credential the connection authenticates anonymously and is
then authorized entity by entity: before a sender or receiver attaches, the bus
puts a token for `sb://<host>/<entity>` on the connection's `$cbs` node
(`AmqpConnection.putToken`: a request message with `operation` `put-token`, the
token's `type` and `name` and its `expiration`, answered on a reply link with a
`status-code`, 200 or 202 when accepted). Service Bus stops a link whose token
expired, so the bus puts a fresh token when three quarters of its lifetime
have passed, for as long as the connection is open. A refused token fails the
attach as `message_bus.azure.consumer_failed` or the send as
`message_bus.azure.publish_failed`.

## The AMQP Client

### What it implements

`AmqpConnection` is the part of AMQP 1.0 (OASIS) a message bus needs:

| Part | What there is |
| ---- | ------------- |
| Types | Every primitive type, lists, maps, arrays and described types (`AmqpWriter`, `AmqpReader`, `amqpEncode`, `amqpDecode`); unsigned integers and symbols as `AmqpUbyte`, `AmqpUshort`, `AmqpUint`, `AmqpUlong`, `AmqpSymbol` |
| Security | SASL `PLAIN` and `ANONYMOUS` (`AmqpSasl`), over TLS when `secure`; the claims-based security exchange (`putToken`) |
| Connection | `open` and `close`, frames split to the peer's maximum frame size, an empty frame every half of the peer's idle timeout |
| Session | One session per connection, `begin` and `end` |
| Sending | `attachSender`: messages sent unsettled; `AmqpSender.send` completes with the peer's outcome and fails with an `AmqpException` on `rejected` or a detach |
| Receiving | `attachReceiver`: `grant` gives credit, `deliveries` streams `AmqpDelivery`s, each settled once with `AmqpAccepted`, `AmqpReleased`, `AmqpModified` or `AmqpRejected` |
| Messages | `AmqpMessage`: the `header`, `message-annotations`, `properties` and `application-properties` sections, and a `data` or `amqp-value` body |

A connection the peer closes, or whose socket fails, fails every pending send
and every link with the cause, and `done` completes with it.
`AmqpConnection.frameLog`, when set, is told of every frame sent and received.

### Handles are each side's own

A link has a handle on each side, and the two need not agree: the peer answers
an attach under a handle of its own and names that handle in every `flow`,
`transfer` and `detach` it sends. The connection keeps the links by the peer's
handle for what arrives and sends under its own. The emulator reuses a handle
as soon as a link is detached, so a client that took the peer's handle for its
own would give a new link's credit to a detached one.

## The Management API

Topics and subscriptions are created with `PUT` on the management API
(`api-version=2021-05`), with an Atom entry carrying a `TopicDescription` or
`SubscriptionDescription`; an entity that exists already (`409`) is taken as
it is. An ephemeral group's subscription is removed with `DELETE`. Every request
carries a shared access signature for its resource, or the bearer token of an
Entra ID credential (see [Authentication](#authentication)).

## The Mapping onto Service Bus

| Contract | Service Bus |
| -------- | ----------- |
| A topic | A topic, `<namePrefix>-<topic>-<hash>` |
| A consumer group | A subscription of the topic, `<group>-<hash>` |
| An ephemeral group | A subscription of the bus's own, under a fresh name, deleted when its last consumer cancels |
| Consumers of a group | Receiver links on the subscription, each granted one message at a time |
| Acknowledge | `accepted` (complete) |
| Reject, redelivered | `modified` with `delivery-failed` (abandon) |
| Dead letter | Published to `<topic>.dlq`'s topic, then completed |
| The attempt | The header's `delivery-count`, plus one |
| Message id | `message-id`, and in the envelope |

### Names

`topicNameOf(prefix, topic)` is the prefix, the topic with every character
other than letters, digits, `_`, `-` and `.` replaced by `_`, and an FNV-1a hash
of the topic, which keeps topics the replacing maps alike apart.
`subscriptionNameOf(group, suffix:)` keeps within the 50 characters Service
Bus allows a subscription name, cutting the group and adding the hash (and an
ephemeral group's suffix).

### The message on the wire

Each message is one JSON envelope in a `data` section —
`{"id", "key", "publishedAt", "headers", "payload"}` (`envelopeOf`,
`messageOf`), as the other adapters' messages are — with `message-id`,
`content-type` (`application/json`) and `creation-time` set. A message in the
subscription that is no envelope of the bus is completed and dropped: nothing
could handle it.

## Consumer Groups

A group's subscription is created when the group first subscribes, and keeps
what is published while none of its consumers is attached. A message published
to a topic without subscriptions reaches no one. The consumers of a group are
receiver links on the same subscription, which Service Bus hands each message
to one of.

### Ephemeral groups

An ephemeral group is a subscription of this bus's own, created for its first
consumer under a fresh name and deleted when its last consumer cancels, so it
keeps nothing for a later subscriber. It is created with `AutoDeleteOnIdle`
set to `ephemeralIdle`, so Service Bus removes a subscription whose process
went away without cancelling.

## Settling and Dead Letters

Every delivery goes through the bus's shared `tomDispatch`. A handler that
returns acknowledges the delivery (`accepted`). A handler that throws, or
rejects with requeue, has the message abandoned (`modified` with
`delivery-failed`): Service Bus delivers it again and raises its delivery
count. After `maxDeliveries` attempts, or on a rejection without requeue, or a
payload that does not decode, the message is published to `<topic>.dlq`
(`tomDeadLetter`, with the reason, the group and the attempts in its headers)
and the original completed. A dead letter that cannot be published leaves the
original abandoned without counting the delivery, to be dead-lettered on its
next delivery.

### The delivery limit

Service Bus moves a message to the subscription's own dead-letter queue after
the subscription's `MaxDeliveryCount` deliveries. The bus creates its
subscriptions with `maxDeliveryCount` (10 by default); the emulator allows at
most 10, Service Bus up to 2000. A consumer passing a `maxDeliveries` above
`maxDeliveryCount` gets at most `maxDeliveryCount` deliveries, and the message
then lies in the subscription's dead-letter queue, not on `<topic>.dlq`.

### The lock

A received message is locked to its consumer for `lockDuration` (30 seconds).
A handler that runs longer loses the lock, and the message is delivered again —
at least once.

## No Ordering per Key

Service Bus orders messages within a session, and the bus does not use
sessions: `capabilities.orderedPerKey` is `false`, and the conformance suite's
ordering test, MB-C18, is skipped.

## Publishing from the Bus Relay

`tom_core_server`'s `TomBusRelay` publishes through any bus: a message queued
in a database transaction is published once the transaction committed, under
the id it was queued with. `test/azure_conformance_test.dart` (ZB-I1) has a
relay publish through Service Bus and a consumer receive it once.

## Connections and Closing

A bus opens one AMQP connection when it first sends or attaches, and shares it
between its senders (one per topic) and its consumers. A connection that fails
is opened again for the next send; a send whose link or connection failed under
it is tried once more on a fresh one. A consumer whose link or connection
failed attaches again after `retryDelay`. `close` cancels every consumer —
detaching its link, and deleting an ephemeral group's subscription — then
closes the connection and, when the bus made it, the management API's client.
A closed bus refuses to publish and to subscribe (`message_bus.closed`).

## Error Keys

| Key | Raised when |
| --- | ----------- |
| `message_bus.azure.connection_string_invalid` | A connection string lacks `Endpoint`, `SharedAccessKeyName` or `SharedAccessKey` |
| `message_bus.azure.management_failed` | The management API answered a status of 300 or above other than an accepted one |
| `message_bus.azure.publish_failed` | A message could not be sent to its topic |
| `message_bus.azure.consumer_failed` | A group's subscription could not be created, or a consumer could not attach |
| `message_bus.closed` | The bus was closed (the contract's key) |

The AMQP client fails with `AmqpException` (the peer's error condition and
description, or a local one) and `AmqpCodecException` (bytes that are no AMQP
encoding).

## Not Yet Implemented

- **Acquiring Entra ID tokens.** The bus puts the tokens a
  `TomServiceBusTokenCredential` answers; obtaining them is the application's.
- **Sessions.** Without them there is no ordering per key.
- **More than one session per connection, transactions, link recovery.** The
  client implements what the bus needs.

## Verification

| Suite | What it covers |
| ----- | -------------- |
| `test/amqp_codec_test.dart` | ZB-U1 to ZB-U10 and ZB-U14 to ZB-U18, offline: every primitive type, the compact encodings, nested and large lists and maps, arrays, malformed bytes; the message sections and the outcomes; the shared access signature; subscription and topic names; connection strings, and the one refused without a key; ZB-U14, ZB-U15: the management API's shared access signature and Entra ID bearer token, and its refusals; ZB-U16 to ZB-U18: a closed bus's publish, a send to a port nothing listens on and a management API that cannot be reached, each with its error key |
| `test/amqp_connection_test.dart` | ZB-U11 to ZB-U13, against a scripted AMQP peer in the same process: SASL `PLAIN`, `open` and `begin`, a send accepted by the peer; a link attached after another was detached, receiving its credit and its deliveries under the peer's handle; ZB-U13, a token put on `$cbs`, accepted and refused |
| `test/azure_conformance_test.dart` | Tagged `azure`: the bus's conformance suite MB-C1 to MB-C20 twice — authenticated with SASL `PLAIN`, and authorized through claims-based security — and ZB-I1, the bus relay publishing through Service Bus |
| `test/example_test.dart` | Tagged `azure`: the example runs green |

`tool/run_azure_tests.sh` starts the emulator and its database in Docker,
waits until the emulator reports itself up, runs the `azure` tests and fails
when every one of them skipped. 40 tests pass and 2 are skipped, MB-C18 in
each authentication mode.

```bash
tool/run_azure_tests.sh
```

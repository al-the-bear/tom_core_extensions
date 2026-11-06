# GCP Message Bus

`TomPubSubMessageBus` keeps the `TomMessageBus` contract of
[`tom_core_message_bus`](../../../core/tom_core_message_bus/doc/message_bus.md)
over Google Cloud Pub/Sub, reached through its REST API. This page covers the
Pub/Sub side: how the bus is constructed and authenticated, how each point of
the contract maps onto topics and subscriptions, how deliveries are settled and
dead-lettered, why the bus orders per key, the error keys, and how the suite
runs. The contract itself — consumer groups, at least once, codecs, headers and
trace — is in the message bus guide.

## Table of Contents

- [Constructing the Bus](#constructing-the-bus)
- [Authentication](#authentication)
  - [A service account](#a-service-account)
  - [The metadata server](#the-metadata-server)
  - [The emulator](#the-emulator)
- [The REST API](#the-rest-api)
  - [Requests and the resilient client](#requests-and-the-resilient-client)
- [The Mapping onto Pub/Sub](#the-mapping-onto-pubsub)
  - [Names](#names)
  - [The message on the wire](#the-message-on-the-wire)
- [Consumer Groups](#consumer-groups)
  - [The group's subscription](#the-groups-subscription)
  - [Ephemeral groups](#ephemeral-groups)
- [Settling and Dead Letters](#settling-and-dead-letters)
  - [Why redelivery is made in place](#why-redelivery-is-made-in-place)
- [Ordering per Key](#ordering-per-key)
- [Publishing from the Bus Relay](#publishing-from-the-bus-relay)
- [Closing](#closing)
- [Error Keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## Constructing the Bus

The constructor takes a project and a token source; nothing is asked of
Pub/Sub until the first publish or subscribe:

```dart
final bus = TomPubSubMessageBus(
  projectId: 'my-project',
  token: TomPubSubMessageBus.metadataServer(),
  endpoint: Uri.parse('https://europe-west1-pubsub.googleapis.com/'),
  ackDeadline: const Duration(seconds: 60),
  fetchWait: const Duration(milliseconds: 500),
);
```

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `projectId` | — | The project the topics and subscriptions live in. |
| `token` | none | The `TomGcpTokenSource` every request's access token comes from; without one no `Authorization` header is sent, which only the emulator accepts. |
| `endpoint` | `https://pubsub.googleapis.com/` | The Pub/Sub endpoint; a regional one (`https://europe-west1-pubsub.googleapis.com/`) for ordered publishing, or the emulator. |
| `namePrefix` | `tombus` | The first part of every topic and subscription id; it starts with a letter, as Pub/Sub requires of an id. |
| `ackDeadline` | 60 s | How long a pulled message stays with its consumer: the subscription's `ackDeadlineSeconds`, and the deadline set again between two attempts (constructor only). |
| `fetchWait` | 500 ms | The pause before an empty or failed pull is repeated; the longest a `cancel` waits (constructor only). |
| `redeliveryDelay` | 100 ms | The pause between two attempts of a delivery (constructor only). |
| `httpClient` | a `TomResilientClient` | The `package:http` client the requests go through; one the bus makes is closed by `close` (constructor only). |
| `clock` | `DateTime.now` | The publication time of a message (constructor only). |

## Authentication

A `TomGcpTokenSource` is a `Future<String> Function()` answering an OAuth access
token. The bus calls it for **every request** and sends the answer as
`Authorization: Bearer <token>`; the source caches its token and mints a fresh
one before it expires.

### A service account

`serviceAccount(keyJson)` builds a bus from the JSON key file Google issues for
a service account:

```dart
final bus = TomPubSubMessageBus.serviceAccount(
  File('service-account.json').readAsStringSync(),
  projectId: 'another-project', // the key's own project otherwise
);
```

The token comes from `serviceAccountCredential(keyJson)`: `tom_core_server`'s
`TomFcmServiceAccountCredential` built from the key's `client_email`,
`private_key`, `token_uri` and `project_id`, asking for `pubsubScope`
(`https://www.googleapis.com/auth/pubsub`). It makes the OAuth JWT-bearer
grant — an assertion signed with the account's RSA key, exchanged at the token
endpoint — and caches the token until five minutes before the expiry the
endpoint states. The project is `projectId` when given, else the key's
`project_id`; a key that names none, with no `projectId`, is refused with
`message_bus.pubsub.no_project`. A key file without `client_email` or
`private_key` is refused by the credential, with
`messaging.push.bad_service_account`. `serviceAccount` takes the default
`ackDeadline`, `fetchWait`, `redeliveryDelay` and client.

### The metadata server

`metadataServer()` is a token source for a bus on Compute Engine, GKE or Cloud
Run: it asks the host's metadata server
(`http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token`,
with `Metadata-Flavor: Google`) for the default service account's token, and
caches it until a minute before the `expires_in` the server states (300
seconds when it states none). An answer other than 200 is refused with
`message_bus.pubsub.no_token`. `httpClient` and `clock` may be passed; without a
client it makes a plain `http.Client` of its own.

### The emulator

The Pub/Sub emulator checks no token: a bus over it is constructed with its
`endpoint` and no `token`.

```dart
final bus = TomPubSubMessageBus(
  projectId: 'tom-test',
  endpoint: Uri.parse('http://127.0.0.1:8085'),
);
```

## The REST API

`call(method, resource, body)` sends `method` to `v1/<resource>` under the
endpoint, with the token and a JSON body, and answers the decoded result; an
answer with a status of 300 or more is a `PubSubError` carrying the HTTP status,
the gRPC status name and Pub/Sub's message. It is public so a test or a tool
administers the same resources through it.

| Call | For |
| ---- | --- |
| `PUT projects/<project>/topics/<id>` | Creating a topic; `ALREADY_EXISTS` (409) is taken as success |
| `POST .../topics/<id>:publish` | Publishing a message and a dead letter |
| `PUT projects/<project>/subscriptions/<id>` | Creating a subscription, with `topic`, `ackDeadlineSeconds` and `enableMessageOrdering`; 409 taken as success |
| `POST .../subscriptions/<id>:pull` | Pulling one message, `returnImmediately` |
| `POST .../subscriptions/<id>:acknowledge` | Acknowledging |
| `POST .../subscriptions/<id>:modifyAckDeadline` | Extending a deadline between attempts, or handing a message back (0 seconds) |
| `DELETE projects/<project>/subscriptions/<id>` | Removing an ephemeral group's subscription |

### Requests and the resilient client

Without an `httpClient`, the requests go through `tom_core_kernel`'s
`TomResilientClient` with the destination's policy: a timeout per attempt,
retries of idempotent calls, a circuit breaker and a bulkhead per destination.
The bulkhead limits the concurrent calls to one destination, so a burst of
hundreds of concurrent publishes is refused beyond that limit; a publisher that
sends many messages at once publishes them in sequence, or passes a client with
another policy.

## The Mapping onto Pub/Sub

| Contract | Pub/Sub |
| -------- | ------- |
| A topic | A topic, `<namePrefix>-<topic>-<hash>`, created on first use |
| A consumer group | A subscription to it, `<namePrefix>-<topic>-<group>-<hash>`, with message ordering enabled |
| An ephemeral group | A subscription of the bus's own, deleted when its last consumer cancels |
| Consumers of a group | Polling loops on the subscription, each pulling one message at a time |
| Publish | `publish` of the message envelope, the message's key as its `orderingKey` |
| Acknowledge | `acknowledge` |
| Reject, redelivered | Handled again in place, the ack deadline extended, before the consumer pulls the next message |
| Dead letter | Published to `<topic>.dlq`'s topic, then acknowledged |
| The attempt | Counted by the consumer, in place |
| Ordering per key | Declared |

### Names

A topic's id is `topicIdOf(namePrefix, topic)`: the prefix, the topic with
every character other than letters, digits, `_`, `-`, `.` and `~` replaced by
`_` and cut to 160 characters, and an eight-digit hexadecimal FNV-1a hash of the
topic as given. The hash keeps apart two topics the replacement maps alike:
`a b` and `a_b` are two Pub/Sub topics. `orders.dlq` is
`tombus-orders.dlq-<hash>`. `topicName(topic)` is the resource name,
`projects/<project>/topics/<id>`.

A group's subscription id is `subscriptionIdOf(namePrefix, topic, group)`: the
prefix, the topic and the group each replaced the same way and cut to 100
characters, and a hash of the pair; an ephemeral group's subscription adds a
suffix. Pub/Sub allows 255 characters; with the default prefix every id stays
within it.

### The message on the wire

The message travels as one JSON envelope in the message's `data`, base64
encoded:

```json
{
  "id": "msg-3f2a...",
  "key": "customer-7",
  "publishedAt": "2026-11-06T12:00:00.000Z",
  "headers": {"traceparent": "00-..."},
  "payload": {"order": "o-1"}
}
```

`envelopeOf(message)` builds it (`key` left out when the message has none),
`messageOf(topic, data)` reads it back from the base64 data — `null` for data
that is not base64 JSON or is no envelope of this bus. A message with a key is
published with that key as its `orderingKey`; one without has none. The payload
is encoded by the subscription's `TomBusCodec`.

## Consumer Groups

A group is a Pub/Sub subscription. Every `subscribe` is one consumer of it: a
loop that pulls one message with `returnImmediately`, handles it, and pulls the
next; an empty pull is repeated after `fetchWait`. Pub/Sub hands each message
to one consumer of the subscription at a time, so the consumers of a group
share its messages (MB-C3).

This is polling: a message published while a consumer pauses waits up to
`fetchWait`, and a `cancel` answers within `fetchWait` — after the pull, or the
message under way. A pull that fails is logged, and the loop tries again after
`fetchWait`. A message pulled after the cancel is handed back to the group with
`modifyAckDeadline` 0.

### The group's subscription

The first subscription of a durable group in a bus creates its Pub/Sub
subscription to the topic, with `ackDeadlineSeconds` from `ackDeadline` and
`enableMessageOrdering`; one that exists — another node created it first — is
taken. `subscribe` answers once it exists.

A subscription receives the messages published after it was created, and keeps
them while none of its consumers pulls (MB-C4) — for Pub/Sub's retention of
seven days. A message published to a topic with no subscription reaches no one
(MB-C5). The bus deletes neither durable subscriptions nor topics.

A subscription Pub/Sub does not create is refused with
`message_bus.pubsub.consumer_failed`; a topic it does not create with
`message_bus.pubsub.topic_failed`.

### Ephemeral groups

A group subscribed with `ephemeral: true` is a subscription of the bus's own,
named with a suffix of the bus id and a random part. The consumers of the group
in one bus share it. When the last of them cancels, the subscription is
deleted, and what waited in it is gone (MB-C19); a deletion that fails is
logged. Two buses with the same ephemeral group name have two subscriptions,
each receiving every message (MB-C20).

## Settling and Dead Letters

Each message goes through `tomDispatch` from `tom_core_message_bus`: the
payload is decoded, the handler runs inside `TomBusTrace.delivering`, and the
outcome is mapped onto Pub/Sub:

| Outcome | What the consumer does |
| ------- | ---------------------- |
| Acknowledged (the handler returned or called `ack`) | `acknowledge` |
| Requeued (the handler threw or called `reject()`) below `maxDeliveries` | Waits `redeliveryDelay`, sets the ack deadline to `ackDeadline` again, and handles the message again, as the next attempt |
| Requeued at attempt `maxDeliveries` | A dead letter with the reason `max-deliveries`, then `acknowledge` |
| Dead-lettered (`reject(requeue: false)`) | A dead letter with the delivery's reason, then `acknowledge` |
| The payload does not decode | A dead letter with the reason `undecodable`, then `acknowledge`; the handler is not called |

A message whose data is no envelope of this bus could never be handled; it is
acknowledged without a dead letter. An `acknowledge` or `modifyAckDeadline`
that fails is logged; Pub/Sub delivers the message again after its deadline,
which at least once allows.

A dead letter is `tomDeadLetter(message, ...)`: the original message — same
id, key, payload and headers — with the four dead-letter headers, published to
the topic of `tomDeadLetterTopic(topic)`, `<topic>.dlq`. That is a topic like
any other, created on first use; a group subscribed to it receives the dead
letters. A dead letter Pub/Sub does not take is logged and the message is not
acknowledged: Pub/Sub delivers it again after its deadline, and it is handled
from the first attempt.

### Why redelivery is made in place

Pub/Sub counts deliveries only on a subscription with a dead-letter policy,
and that policy's least maximum is five attempts; the contract's
`maxDeliveries` is any number from one. So the consumer counts the attempts
itself and makes the redelivery in place, as the Kafka adapter does: the
message is handled again until it is acknowledged, dead-lettered, or has had
`maxDeliveries` attempts, its ack deadline extended before each further
attempt. A consumer that stops before settling — cancelled between two
attempts, or a process that crashed — leaves the message to the subscription,
which delivers it again after the deadline; the count then starts over at 1.

## Ordering per Key

The bus declares `TomBusCapabilities(orderedPerKey: true)`, and the
conformance suite's ordering test, MB-C18, runs and passes. Three properties
make it hold:

- **A key is an ordering key.** A message is published with its key as the
  `orderingKey`, and every subscription the bus creates has message ordering
  enabled.
- **Pub/Sub hands a key's messages over one at a time.** With message ordering
  enabled, it delivers a key's messages in publish order, the next only once
  the one before was acknowledged.
- **A redelivery comes before the messages behind it.** The attempts of a
  delivery are made in place, so the key's next message is handled only once
  this one is acknowledged or dead-lettered.

The cost is the third point: a message that fails holds its key for up to
`maxDeliveries` attempts, `redeliveryDelay` apart. Pub/Sub orders the messages
a client publishes to one region; a deployment that relies on ordering per key
publishes through a regional endpoint rather than the global one.

## Publishing from the Bus Relay

`tom_core_server`'s `TomBusRelay` queues a message in the caller's database
transaction and publishes it to a bus after the commit. With this bus the
message reaches a Pub/Sub consumer once, under the id the relay chose and with
its key (GB-I1):

```dart
final relay = TomBusRelay(
  bus: TomPubSubMessageBus.serviceAccount(keyJson),
);
```

Pub/Sub has no duplicate detection by message id: a publish the relay repeats
after a crash is a second message, and a consumer that must not act twice keeps
the ids it handled, as the contract's at least once asks. See the server's
[messaging guide](../../../core/tom_core_server/doc/messaging.md#the-bus-relay).

## Closing

`close` refuses further `publish` and `subscribe` calls with
`message_bus.closed`, cancels every consumer — each finishing the message it is
handling, and an ephemeral group's last consumer deleting its subscription —
and closes the HTTP client when the bus made it. A second call is the same
close.

## Error Keys

Every refusal is a `TomBusException`, with its key and parameters.

| Key | Raised when | Parameters |
| --- | ----------- | ---------- |
| `message_bus.pubsub.topic_failed` | Pub/Sub did not create the topic and it does not exist, on `publish` or `subscribe` | `topic` |
| `message_bus.pubsub.publish_failed` | Pub/Sub did not take the `publish` — a refused request, a call the resilient client refused | `topic`, `message` |
| `message_bus.pubsub.consumer_failed` | The group's subscription could not be created | `topic`, `group` |
| `message_bus.pubsub.no_project` | `serviceAccount` with a key that names no project and no `projectId` | — |
| `message_bus.pubsub.no_token` | The metadata server answered a token request with a status other than 200 | `status` |

The bus's own keys — `message_bus.closed`, `message_bus.subscribe.invalid`,
`message_bus.delivery.already_settled`, `message_bus.payload.not_json`,
`message_bus.payload.undecodable` — are raised as for every bus; see the
[message bus guide](../../../core/tom_core_message_bus/doc/message_bus.md#error-keys).

## Not Yet Implemented

- **No streaming pull.** A consumer polls with `returnImmediately` and
  `fetchWait` between empty pulls; there is no gRPC streaming pull.
- **No Pub/Sub dead-letter policy.** Dead letters are published by the consumer
  to `<topic>.dlq`; the subscriptions carry no dead-letter policy, so Pub/Sub's
  delivery count is not used.
- **No subscription configuration beyond the ack deadline and ordering.** A
  subscription the bus creates takes Pub/Sub's retention, expiry and other
  defaults; one that exists is not changed.
- **No resource removal beyond ephemeral groups.** Topics and durable
  subscriptions stay after the bus is closed; removing them is the
  deployment's.
- **No batching.** One message per `publish` call, one per `pull`.

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/gcp_bus_test.dart` | Offline, against a mock client playing Pub/Sub. GB-U1 topics and subscriptions named after their topic and group, kept apart by a hash, starting with a letter, ids within 255 characters; GB-U2 a message surviving its envelope, foreign data none; GB-U3 every request carrying the token, a keyed message its ordering key; GB-U4 a topic Pub/Sub has already taken as it is; GB-U5 a topic Pub/Sub does not create (`message_bus.pubsub.topic_failed`); GB-U6 a publish Pub/Sub refuses (`message_bus.pubsub.publish_failed`); GB-U7 a subscription Pub/Sub does not create (`message_bus.pubsub.consumer_failed`); GB-U8 a closed bus refusing to publish (`message_bus.closed`); GB-U9 a key file without a project needing one (`message_bus.pubsub.no_project`), the credential asking for `pubsubScope`; GB-U10 the metadata server's token cached until a minute before it expires, a refusal keyed `message_bus.pubsub.no_token`. |
| `test/gcp_conformance_test.dart` | Tagged `gcp`. The bus's conformance suite, MB-C1 to MB-C20, against the Pub/Sub emulator, MB-C18 included; GB-I1 a message queued on `TomBusRelay` reaching a Pub/Sub consumer once, under its id and key. Skips itself unless `TOM_PUBSUB_TEST_ENDPOINT` names an endpoint. |
| `test/example_test.dart` | Tagged `gcp`. The example runs to the end against the endpoint. |

`test/fixtures/throwaway_rsa_private.pem` is an RSA key generated for GB-U9 and
used for nothing else: the test reads it to build a key file and never signs
with it.

```bash
dart test                   # the unit suite; the gcp tests skip
./tool/run_gcp_tests.sh     # the gcp suite against a Pub/Sub emulator container
```

`tool/run_gcp_tests.sh` starts the Pub/Sub emulator
(`gcr.io/google.com/cloudsdktool/google-cloud-cli:emulators`, running
`gcloud beta emulators pubsub start` for the project `tom-test`) on
`127.0.0.1:18086` (`PUBSUB_TEST_PORT` overrides the port,
`PUBSUB_EMULATOR_IMAGE` the image). It waits until the emulator answers, runs
`dart test --tags gcp` with `TOM_PUBSUB_TEST_ENDPOINT` pointing at it, and
removes the container. A run in which every test skipped is reported as a
failure, because it means the emulator never answered. It needs Docker. The
suite's result: 22 passed, none skipped; the ten untagged unit tests pass
without an endpoint.

The emulator checks no token, so authentication is checked offline: GB-U3 for
the header every request carries, GB-U9 and GB-U10 for the two token sources.

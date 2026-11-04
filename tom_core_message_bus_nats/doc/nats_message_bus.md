# NATS Message Bus

`TomNatsMessageBus` keeps the `TomMessageBus` contract of
[`tom_core_message_bus`](../../../core/tom_core_message_bus/doc/message_bus.md)
over a NATS server with JetStream. This page covers the NATS side: how the bus
connects, how each point of the contract maps onto JetStream, how deliveries
are settled and dead-lettered, what the server retains, the error keys, and
how the suite runs. The contract itself — consumer groups, at least once,
codecs, headers and trace — is in the message bus guide.

## Table of Contents

- [Connecting](#connecting)
- [The Mapping onto JetStream](#the-mapping-onto-jetstream)
  - [Topics and subjects](#topics-and-subjects)
  - [The message on the wire](#the-message-on-the-wire)
- [Consumer Groups](#consumer-groups)
- [Settling and Dead Letters](#settling-and-dead-letters)
- [Retention and the Duplicate Window](#retention-and-the-duplicate-window)
- [Publishing from the Bus Relay](#publishing-from-the-bus-relay)
- [Closing](#closing)
- [Error Keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## Connecting

`connect` opens the connection and answers a bus that owns it — `close` closes
the connection too:

```dart
final bus = await TomNatsMessageBus.connect(
  Uri.parse('nats://nats.internal:4222'),
  subjectPrefix: 'tombus',
  retention: const Duration(days: 7),
  fetchWait: const Duration(milliseconds: 500),
);
```

`connect` tries once, with a five-second timeout; a server that does not answer
is refused with `message_bus.nats.unreachable`.

A connection that needs more than an address — TLS, credentials, a reconnect
policy — is opened by the caller with `dart_nats`' `Client` and handed to the
constructor. The bus then leaves the connection to the caller unless
`ownsClient` is set:

```dart
final client = Client();
await client.connect(Uri.parse('nats://nats.internal:4222'));
final bus = TomNatsMessageBus(client, ownsClient: true);
```

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `subjectPrefix` | `tombus` | The first token of every subject the bus publishes to. |
| `retention` | 7 days | How long a stream keeps a message: the stream's maximum age. |
| `fetchWait` | 500 ms | How long one pull waits for a message before the consumer asks again; also the longest a `cancel` waits. |
| `ownsClient` | `false` | Whether `close` closes the client (constructor only; `connect` sets it). |
| `clock` | `DateTime.now` | The publication time of a message (constructor only). |

The server must run with JetStream enabled (`nats-server -js`).

## The Mapping onto JetStream

| Contract | JetStream |
| -------- | --------- |
| A topic | A stream of its own, `TOMBUS_<topic>_<hash>`, holding the subject `<subjectPrefix>.<topic>` |
| A consumer group | A durable pull consumer of that stream, deliver policy `new`, explicit acknowledgement |
| Consumers of a group | Pull loops on the same durable consumer, each fetching one message at a time |
| Acknowledge | `+ACK` |
| Reject, redelivered | `-NAK`: the server delivers it again at once |
| Dead letter | Published to `<topic>.dlq`, then `+TERM`ed on the topic |
| The attempt | The delivered count of the JetStream reply subject |
| Message id | `Nats-Msg-Id`, so the server drops a repeated publish within its duplicate window |
| Ordering per key | Not declared |

### Topics and subjects

A topic is a NATS subject below the prefix: tokens of letters, digits, `_` and
`-`, separated by `.`. `orders` and `orders.dlq` are topics; a space, an empty
token or a wildcard (`*`, `>`) is refused with
`message_bus.nats.invalid_topic` on `publish` and `subscribe`.
`subjectOf(topic)` answers the subject, `validSubject(prefix, topic)` is the
same check without a bus.

Each topic has its own stream, created (or updated) the first time the bus
publishes or subscribes to it and remembered for the bus's lifetime.
`streamOf(topic)` is its name: the topic with every character outside
`[A-Za-z0-9_-]` replaced by `_`, cut to 40 characters, followed by an FNV-1a
hash of the topic, so `a.b` and `a_b` get two streams. `consumerOf(group)`
names a group's durable consumer the same way. A stream that cannot be created
is refused with `message_bus.nats.stream_failed` and tried again on the next
call.

### The message on the wire

The payload is the message's JSON, encoded by the subscription's
`TomBusCodec`. The message's own fields travel in NATS headers beside the
headers it was published with:

| Header | Constant | Carries |
| ------ | -------- | ------- |
| `Tom-Bus-Id` | `idHeader` | The message id |
| `Tom-Bus-Key` | `keyHeader` | The ordering key, when the message has one |
| `Tom-Bus-Published-At` | `publishedAtHeader` | The publication time, ISO 8601 in UTC |

On delivery these three are taken out of the headers, and so is every header
whose name starts with `Nats-` — those are the transport's, not the message's.
A delivery whose body is not JSON was not published by this bus; nothing could
handle it, so it is `+TERM`ed without a dead letter.

## Consumer Groups

A group is a durable pull consumer of the topic's stream, created by `subscribe`
with the deliver policy `new`. It receives the messages published after it was
first created and keeps its position while none of its consumers is
subscribed, so a message published in that time waits for the next consumer
(MB-C4). A message published before any group existed reaches no group (MB-C5).

Every `subscribe` is one consumer of the group: a loop on the shared durable
consumer that fetches one message, handles it, settles it, and fetches the
next. The consumers of a group therefore compete for its messages (MB-C3). A
fetch that fails — the connection dropped, say — is logged, and the loop tries
again after `fetchWait`. A consumer that cannot be created is refused with
`message_bus.nats.consumer_failed`.

`cancel` stops the loop. It waits for the fetch under way, at most `fetchWait`;
a message that fetch brings back after the cancel is NAKed, so another consumer
of the group receives it.

## Settling and Dead Letters

The handler runs inside `TomBusTrace.delivering`, and its delivery is settled
by its outcome:

| Outcome | Sent to the server |
| ------- | ------------------ |
| Acknowledged (the handler returned or called `ack`) | `+ACK` |
| Requeued (the handler threw or called `reject()`) below `maxDeliveries` | `-NAK`: delivered again at once, with the next attempt |
| Requeued at attempt `maxDeliveries` | A dead letter with the reason `max-deliveries`, then `+TERM` |
| Dead-lettered (`reject(requeue: false)`) | A dead letter with the delivery's reason, then `+TERM` |
| The payload does not decode | A dead letter with the reason `undecodable`, then `+TERM`; the handler is not called |

The attempt is JetStream's delivered count, read from the reply subject
(`$JS.ACK.<stream>.<consumer>.<delivered>...`, or with a domain and an account
hash before the stream); `deliveredCount` reads it. `maxDeliveries` is counted
by the bus, not set on the consumer.

A dead letter is the original message — same id, payload and headers — with
the four dead-letter headers (`TomBusHeaders.deadLetterTopic`, `...Group`,
`...Reason`, `...Attempts`), published to `tomDeadLetterTopic(topic)`,
`<topic>.dlq`. That is a topic like any other, with its own stream; a group
subscribed to it receives the dead letters.

**A settlement the server did not confirm** — no reply within five seconds — is
logged. The message is then delivered again once the consumer's
acknowledgement wait has passed, which at least once allows.

## Retention and the Duplicate Window

A stream keeps a message for `retention`, a week by default, whether or not
every group has consumed it; a group that stays away longer loses what it did
not fetch. Nothing else limits a stream.

Every publish sends the message id as `Nats-Msg-Id`. The server stores a
message once per id within the stream's duplicate window — the server's
default, two minutes — and answers a repeated publish without storing it
again. A caller that may publish the same message twice gives the id itself
(`publish(..., id: ...)`), and the second publish never reaches a consumer
(NB-I2).

## Publishing from the Bus Relay

`tom_core_server`'s `TomBusRelay` queues a message in the caller's database
transaction and publishes it to a bus after the commit. With this bus it
publishes under the message id the relay chose (NB-I1), so a publish the relay
repeats is dropped by the server within its duplicate window (NB-I2):

```dart
final relay = TomBusRelay(bus: await TomNatsMessageBus.connect(uri));
```

See the server's
[messaging guide](../../../core/tom_core_server/doc/messaging.md#the-bus-relay).

## Closing

`close` refuses further `publish` and `subscribe` calls with
`message_bus.closed`, cancels every consumer — each finishing the delivery it
is handling — and closes the client when the bus owns it. A second call is the
same close.

## Error Keys

Every refusal is a `TomBusException`, with its key and parameters.

| Key | Raised when | Parameters |
| --- | ----------- | ---------- |
| `message_bus.nats.unreachable` | `connect` could not reach the server | `uri` |
| `message_bus.nats.invalid_topic` | A topic that is not a NATS subject, on `publish` or `subscribe` | `topic` |
| `message_bus.nats.stream_failed` | The topic's stream could not be created | `topic`, `stream` |
| `message_bus.nats.publish_failed` | The server did not store a publish | `topic`, `message` |
| `message_bus.nats.consumer_failed` | The group's durable consumer could not be created | `topic`, `group` |

The bus's own keys — `message_bus.closed`, `message_bus.subscribe.invalid`,
`message_bus.delivery.already_settled`, `message_bus.payload.not_json`,
`message_bus.payload.undecodable` — are raised as for every bus; see the
[message bus guide](../../../core/tom_core_message_bus/doc/message_bus.md#error-keys).

## Not Yet Implemented

- **No ordering per key.** The bus declares `TomBusCapabilities()`: a NAK
  redelivers one message while the next is already with another consumer.
- **No connection options of its own.** TLS, credentials and reconnecting are
  what the `Client` handed to the constructor carries; `connect` takes an
  address only.
- **No stream limits other than retention.** A stream has no limit on its
  messages, bytes or message size beyond the server's, and its duplicate
  window is the server's default.
- **The acknowledgement wait is the server's default.** A consumer is created
  without its own, so an unconfirmed settlement is redelivered after the
  server's default wait (30 seconds).

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/nats_bus_test.dart` | Offline. NB-U1 streams and consumers named after their topic and group, kept apart by the hash and cut when long; NB-U2 the attempt read from both reply-subject forms; NB-U3 a topic that is no NATS subject refused with `message_bus.nats.invalid_topic`; NB-U4 an unreachable server refused at `connect` with `message_bus.nats.unreachable`. |
| `test/nats_conformance_test.dart` | Tagged `nats`. The bus's conformance suite, MB-C1 to MB-C18, against a NATS server (MB-C18 skipped: no ordering per key is declared); NB-I1 a message queued on `TomBusRelay` reaching a NATS consumer once, under its id and key; NB-I2 a repeated publish of one id dropped by the server. Skips itself unless `TOM_NATS_TEST_URL` names a server. |
| `test/nats_refusals_test.dart` | Tagged `nats`. NB-E1 a closed bus refusing to publish (`message_bus.closed`); NB-E2 a topic whose subject another stream holds (`message_bus.nats.stream_failed`); NB-E3 a group whose durable consumer exists with another configuration (`message_bus.nats.consumer_failed`); NB-E4 a publish over a lost connection (`message_bus.nats.publish_failed`). |
| `test/example_test.dart` | Tagged `nats`. The example runs to the end against the server. |

```bash
dart test                    # the unit suite; the nats tests skip
./tool/run_nats_tests.sh     # the nats suite against a NATS container
```

`tool/run_nats_tests.sh` starts `nats:2.10-alpine` with JetStream on
`127.0.0.1:14222` (`NATS_TEST_PORT` overrides the port, `NATS_IMAGE` the
image), waits for its health endpoint, runs `dart test --tags nats` with
`TOM_NATS_TEST_URL` pointing at it, and removes the container. A run in which
every test skipped is reported as a failure, because it means the server never
answered. It needs Docker. The suite's result: 24 passed, 1 skipped.

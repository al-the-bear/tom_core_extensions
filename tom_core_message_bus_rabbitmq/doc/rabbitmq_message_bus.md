# RabbitMQ Message Bus

`TomRabbitMqMessageBus` keeps the `TomMessageBus` contract of
[`tom_core_message_bus`](../../../core/tom_core_message_bus/doc/message_bus.md)
over a RabbitMQ broker (AMQP 0-9-1). This page covers the RabbitMQ side: how
the bus connects, how each point of the contract maps onto exchanges and
queues, how publisher confirms make a publish at least once, how deliveries are
settled and dead-lettered, why the client is a fork, the error keys, and how
the suite runs. The contract itself — consumer groups, at least once, codecs,
headers and trace — is in the message bus guide.

## Table of Contents

- [Connecting](#connecting)
- [The Mapping onto RabbitMQ](#the-mapping-onto-rabbitmq)
  - [Exchanges and queues](#exchanges-and-queues)
  - [The message on the wire](#the-message-on-the-wire)
- [Consumer Groups](#consumer-groups)
  - [Ephemeral groups](#ephemeral-groups)
- [Publisher Confirms](#publisher-confirms)
- [Settling and Dead Letters](#settling-and-dead-letters)
- [The AMQP Client](#the-amqp-client)
- [Publishing from the Bus Relay](#publishing-from-the-bus-relay)
- [Closing](#closing)
- [Error Keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## Connecting

`connect` opens the connection and answers a bus that owns it — `close` closes
the connection too:

```dart
final bus = await TomRabbitMqMessageBus.connect(
  Uri.parse('amqp://app:secret@rabbitmq.internal:5672/orders'),
  namePrefix: 'tombus',
  confirmTimeout: const Duration(seconds: 10),
);
```

The URI is `amqp://user:password@host:port/vhost`; `settingsOf(uri)` turns it
into `tom_dart_amqp` `ConnectionSettings`:

| Part | Default | Meaning |
| ---- | ------- | ------- |
| user, password | `guest` / `guest` | The login, percent-decoded (`s%3Acret` is `s:cret`). |
| host | `127.0.0.1` | The broker's host. |
| port | `5672` | The broker's AMQP port. |
| path | `/` | The virtual host; `/%2F` names `/` as well. |

`connect` tries once, with a five-second connect timeout; a broker that does
not answer, or refuses the login, is refused with
`message_bus.rabbitmq.unreachable`. The URI in the error has its user info
replaced by `***`.

A connection that needs more than a URI — TLS, other tuning — is a `tom_dart_amqp`
`Client` made by the caller and handed to the constructor. The bus then leaves
the connection to the caller unless `ownsClient` is set:

```dart
final client = Client(settings: TomRabbitMqMessageBus.settingsOf(uri));
final bus = TomRabbitMqMessageBus(client, ownsClient: true);
```

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `namePrefix` | `tombus` | The first part of every exchange and queue name the bus declares. |
| `confirmTimeout` | 10 s | How long a publish waits for the broker's confirmation. |
| `ownsClient` | `false` | Whether `close` closes the client (constructor only; `connect` sets it). |
| `clock` | `DateTime.now` | The publication time of a message (constructor only). |

## The Mapping onto RabbitMQ

| Contract | RabbitMQ |
| -------- | -------- |
| A topic | A durable fanout exchange of its own, `<namePrefix>.<topic>_<hash>` |
| A consumer group | A durable queue bound to the topic's exchange, `<namePrefix>.<topic>.<group>_<hash>` |
| An ephemeral group | An exclusive, auto-deleted queue of the bus's connection, `<group queue>.<bus id>`, deleted by the broker when its last consumer cancels |
| Consumers of a group | Consumers of that queue, each on a channel of its own with a prefetch of one |
| Publish | A persistent message, confirmed by the broker before `publish` answers |
| Acknowledge | `basic.ack` |
| Reject, redelivered | A copy published to the group's queue with the next attempt, confirmed, then the delivery acknowledged |
| Dead letter | Published to `<topic>.dlq`, confirmed, then the delivery acknowledged |
| The attempt | The `Tom-Bus-Attempt` header the copy carries |
| Message id | The AMQP `message-id` property |
| Ordering per key | Not declared |

### Exchanges and queues

Any topic is accepted: the bus names its exchange after it. `exchangeOf(prefix,
topic)` is the topic with every character outside `[A-Za-z0-9_.-]` replaced by
`_`, cut to 80 characters, followed by an FNV-1a hash of the topic, so `a b`
and `a_b` get two exchanges. `queueOf(prefix, topic, group)` names a group's
queue the same way, hashing topic and group together, so `a.b` + `c` and `a` +
`b.c` get two queues; both names stay below AMQP's 255-byte limit.

A topic's exchange is declared the first time the bus publishes or subscribes
to it, and remembered for the bus's lifetime. A message published to an
exchange no queue is bound to is confirmed and dropped: it reaches no group
(MB-C5).

### The message on the wire

The body is the payload's JSON, encoded by the subscription's `TomBusCodec`,
with the content type `application/json`. The message's own fields travel as
AMQP properties and headers beside the headers it was published with:

| Where | Constant | Carries |
| ----- | -------- | ------- |
| `message-id` property | — | The message id |
| `Tom-Bus-Key` header | `keyHeader` | The ordering key, when the message has one |
| `Tom-Bus-Published-At` header | `publishedAtHeader` | The publication time, ISO 8601 in UTC |
| `Tom-Bus-Attempt` header | `attemptHeader` | The attempt a delivery of this copy is, from 1 |

On delivery these three headers are taken out of the message's headers. A
delivery whose body cannot be read as a message of this bus is rejected
without requeue and without a dead letter: nothing could ever handle it.

## Consumer Groups

A group is a durable queue, declared by `subscribe` and bound to the topic's
exchange. It receives the messages published after it was bound and keeps
them while none of its consumers is subscribed, so a message published in that
time waits for the next consumer (MB-C4). The queue has no expiry; the bus
never deletes it.

Every `subscribe` is one consumer of the group: an AMQP consumer on the
group's queue, on a channel of its own with a prefetch of one, handling one
delivery at a time. The consumers of a group therefore compete for its
messages (MB-C3). A queue that cannot be declared or bound — one that exists
with other properties, say — is refused with
`message_bus.rabbitmq.consumer_failed`.

`cancel` cancels the AMQP consumer, waits for the delivery under way and
closes the channel. A delivery the broker had already sent and that arrives
after the cancel is rejected back to the queue, so another consumer of the
group receives it.

### Ephemeral groups

A group subscribed with `ephemeral: true` is an exclusive, auto-deleted queue
of the bus's connection. Its name is the group's queue name followed by the bus
id, so two buses of one process have one queue each. Every subscription of the
group in that bus consumes the same queue; when the last of them cancels, the
broker deletes the queue, and what waited in it is gone with it (MB-C19). A
later subscription declares a new queue, which receives only what is published
after it. A process that stops without cancelling loses its connection, and the
broker deletes the exclusive queue with it.

Each bus instance has a queue of its own for an ephemeral group, so two
processes subscribing with the same ephemeral group name each receive every
message rather than sharing them (MB-C20).

## Publisher Confirms

The bus publishes on one channel in confirm mode. Every publish — a message, a
redelivery copy, a dead letter — is a persistent message whose correlation id
is a tag of the bus's own; the publish waits until the broker confirms that
tag, at most `confirmTimeout`. A message the broker refuses (a negative
confirmation), a confirmation that does not come in time, or a channel the
broker closed is a failure: `publish` throws
`message_bus.rabbitmq.publish_failed`. Unless the failure was the timeout, the
bus opens a new publish channel for the next call.

This is what makes a publish at least once on RabbitMQ: a `publish` that
answered was taken by the broker, and a message that may not have been taken
is reported to the caller, who can publish it again under the same id
(`publish(..., id: ...)`). It is also what keeps a redelivery or a dead letter
from losing a message: the original delivery is acknowledged only after the
copy is confirmed.

## Settling and Dead Letters

Each delivery goes through `tomDispatch` from `tom_core_message_bus`: the
payload is decoded, the handler runs inside `TomBusTrace.delivering`, and the
outcome is mapped onto RabbitMQ:

| Outcome | Sent to the broker |
| ------- | ------------------ |
| Acknowledged (the handler returned or called `ack`) | `basic.ack` |
| Requeued (the handler threw or called `reject()`) below `maxDeliveries` | A copy published to the group's queue through the default exchange with `Tom-Bus-Attempt` one higher, confirmed, then `basic.ack` |
| Requeued at attempt `maxDeliveries` | A dead letter with the reason `max-deliveries`, confirmed, then `basic.ack` |
| Dead-lettered (`reject(requeue: false)`) | A dead letter with the delivery's reason, confirmed, then `basic.ack` |
| The payload does not decode | A dead letter with the reason `undecodable`, confirmed, then `basic.ack`; the handler is not called |

A redelivery is a copy rather than `basic.reject` with requeue because
RabbitMQ's classic queues count no deliveries: the attempt has to travel with
the message. The copy goes to the back of the group's queue, behind the
messages published after the original.

A dead letter is `tomDeadLetter(message, ...)`: the original message — same
id, key, payload and headers — with the four dead-letter headers, published to
`tomDeadLetterTopic(topic)`, `<topic>.dlq`. That is a topic like any other,
with its own exchange; a group subscribed to it receives the dead letters.

**A copy the broker did not confirm** — a redelivery or a dead letter — is
logged; after 200 ms the delivery is rejected back to the queue, and the broker
delivers it again with the attempt it had. A settlement that cannot be sent at
all, because the channel is gone, is logged; the broker hands the unacknowledged
delivery to the group again.

## The AMQP Client

The bus uses [`tom_dart_amqp`](https://pub.dev/packages/tom_dart_amqp), the fork
[al-the-bear/tom_dart_amqp](https://github.com/al-the-bear/tom_dart_amqp) of
`dart_amqp` (branch `tom/0.3.1-fixes`, version `0.3.1+tom.1`) published under
its own name with upstream's API. The upstream package,
`dart_amqp` 0.3.1, is unmaintained: no commit since 2024-05-31, and submitted
fixes are unmerged. The fork carries two of them:

- **Publisher confirms with `multiple = true`** (upstream issue #132). A broker
  confirms several publishes at once by naming the highest sequence number with
  `multiple` set. The upstream handler walked the live key view of its pending
  publishes while removing from it, and removed the confirmed number instead of
  each pending one, so a burst left earlier publishes unconfirmed. Here that
  means `publish` calls waiting out `confirmTimeout` and failing for messages
  the broker had taken. The fork confirms every pending publish up to the
  sequence number; RB-I2 publishes 500 messages at once and requires every one
  confirmed and delivered.
- **The error stream carries only `Exception`s** (upstream PR #134, issue
  #133): a Dart `Error` raised while handling a frame is wrapped in a
  `FatalException` that keeps the source error and stack trace.

The dependency is `tom_dart_amqp: ^0.3.1+tom.1`, a version on pub.dev, so the
package itself can be published; its library is
`package:tom_dart_amqp/tom_dart_amqp.dart`. Both fixes are offered upstream; once
upstream releases them, the adapter can go back to `dart_amqp`.

## Publishing from the Bus Relay

`tom_core_server`'s `TomBusRelay` queues a message in the caller's database
transaction and publishes it to a bus after the commit. With this bus the
message reaches a RabbitMQ consumer once, under the id the relay chose and with
its key (RB-I1):

```dart
final relay = TomBusRelay(bus: await TomRabbitMqMessageBus.connect(uri));
```

RabbitMQ has no duplicate detection by message id: a publish the relay repeats
after a crash is delivered again, and a consumer that must not act twice keeps
the ids it handled, as the contract's at least once asks. See the server's
[messaging guide](../../../core/tom_core_server/doc/messaging.md#the-bus-relay).

## Closing

`close` refuses further `publish` and `subscribe` calls with
`message_bus.closed`, cancels every consumer — each finishing the delivery it
is handling — closes the publish channel, and closes the client when the bus
owns it. A second call is the same close.

## Error Keys

Every refusal is a `TomBusException`, with its key and parameters.

| Key | Raised when | Parameters |
| --- | ----------- | ---------- |
| `message_bus.rabbitmq.unreachable` | `connect` could not reach the broker, or the broker refused the login | `uri` (user info redacted) |
| `message_bus.rabbitmq.publish_failed` | The topic's exchange could not be declared, or the broker did not confirm a publish within `confirmTimeout` | `topic`, `message` |
| `message_bus.rabbitmq.consumer_failed` | The group's queue, its binding or its consumer could not be created | `topic`, `group` |

The bus's own keys — `message_bus.closed`, `message_bus.subscribe.invalid`,
`message_bus.delivery.already_settled`, `message_bus.payload.not_json`,
`message_bus.payload.undecodable` — are raised as for every bus; see the
[message bus guide](../../../core/tom_core_message_bus/doc/message_bus.md#error-keys).

## Not Yet Implemented

- **No ordering per key.** The bus declares `TomBusCapabilities()`: a
  redelivery is a copy behind the messages published after the original.
- **No duplicate detection.** The broker stores a message once per publish; a
  repeated publish of one id is delivered twice.
- **No queue limits.** A group's queue has no length limit, message TTL or
  expiry of its own; the broker's policies apply.
- **No connection options of its own.** `connect` takes a URI; TLS and other
  settings are what the `Client` handed to the constructor carries.

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/rabbitmq_bus_test.dart` | Offline. RB-U1 exchanges and queues named after their topic and group, kept apart by the hash and cut when long; RB-U2 the connection settings a URI names, with the defaults and `/%2F`; RB-U3 an unreachable broker refused at `connect` with `message_bus.rabbitmq.unreachable`. |
| `test/rabbitmq_conformance_test.dart` | Tagged `rabbitmq`. The bus's conformance suite, MB-C1 to MB-C20, against a RabbitMQ broker (MB-C18 skipped: no ordering per key is declared); RB-I1 a message queued on `TomBusRelay` reaching a RabbitMQ consumer once, under its id and key; RB-I2 a burst of 500 concurrent publishes confirmed in full and every message delivered. Skips itself unless `TOM_RABBITMQ_TEST_URL` names a broker. |
| `test/rabbitmq_refusals_test.dart` | Tagged `rabbitmq`. RB-E1 a closed bus refusing to publish (`message_bus.closed`); RB-E2 a topic whose exchange exists as another type (`message_bus.rabbitmq.publish_failed`); RB-E3 a group whose queue exists with other properties (`message_bus.rabbitmq.consumer_failed`); RB-E4 a broker refusing the login (`message_bus.rabbitmq.unreachable`). |
| `test/example_test.dart` | Tagged `rabbitmq`. The example runs to the end against the broker. |

```bash
dart test                        # the unit suite; the rabbitmq tests skip
./tool/run_rabbitmq_tests.sh     # the rabbitmq suite against a RabbitMQ container
```

`tool/run_rabbitmq_tests.sh` starts `rabbitmq:3.13-management-alpine` on
`127.0.0.1:15673` (`RABBITMQ_TEST_PORT` overrides the port, `RABBITMQ_IMAGE`
the image), waits for the broker's `Server startup complete` log line, runs
`dart test --tags rabbitmq` with `TOM_RABBITMQ_TEST_URL` pointing at it, and
removes the container. A run in which every test skipped is reported as a
failure, because it means the broker never answered. It needs Docker. The
suite's result: 26 passed, 1 skipped; the three untagged unit tests pass
without a broker.

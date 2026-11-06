# Kafka Message Bus

`TomKafkaMessageBus` keeps the `TomMessageBus` contract of
[`tom_core_message_bus`](../../../core/tom_core_message_bus/doc/message_bus.md)
over a Kafka cluster, reached through the Kafka REST Proxy API. This page
covers the Kafka side: how the bus connects, which proxy it needs, how each
point of the contract maps onto topics, consumer groups and offsets, how
deliveries are settled and dead-lettered, why the bus orders per key, the error
keys, and how the suite runs. The contract itself — consumer groups, at least
once, codecs, headers and trace — is in the message bus guide.

## Table of Contents

- [Connecting](#connecting)
- [The REST Proxy](#the-rest-proxy)
  - [Requests and the resilient client](#requests-and-the-resilient-client)
- [The Mapping onto Kafka](#the-mapping-onto-kafka)
  - [Topics](#topics)
  - [The record on the wire](#the-record-on-the-wire)
- [Consumer Groups](#consumer-groups)
  - [Joining a group](#joining-a-group)
  - [Ephemeral groups](#ephemeral-groups)
- [Settling and Dead Letters](#settling-and-dead-letters)
- [Ordering per Key](#ordering-per-key)
- [Publishing from the Bus Relay](#publishing-from-the-bus-relay)
- [Closing](#closing)
- [Error Keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## Connecting

`connect` answers a bus once the proxy has named the cluster it serves:

```dart
final bus = await TomKafkaMessageBus.connect(
  Uri.parse('http://kafka-rest.internal:8082'),
  partitions: 3,
  replicationFactor: 3,
  fetchWait: const Duration(milliseconds: 500),
);
```

`connect` asks the proxy for its cluster (`GET /v3/clusters`); a proxy that
does not answer, or answers without a cluster, is refused with
`message_bus.kafka.unreachable`. The constructor makes a bus without asking;
the cluster is then asked for on the first publish or subscribe, and asked
again after a failure.

```dart
final bus = TomKafkaMessageBus(
  Uri.parse('http://kafka-rest.internal:8082'),
  client: myHttpClient,
);
```

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `partitions` | 3 | The partition count of a topic the bus creates — the most consumers of a group that read at once. |
| `replicationFactor` | the cluster's default | The replication factor of a topic the bus creates. |
| `fetchWait` | 500 ms | How long one fetch waits for records; also the longest a `cancel` waits, and the pause before a failed fetch or dead letter is tried again. |
| `redeliveryDelay` | 100 ms | The pause between two attempts of a delivery (constructor only). |
| `joinTimeout` | 20 s | How long `subscribe` waits for the group to give the new consumer partitions (constructor only). |
| `client` | a `TomResilientClient` | The `package:http` client the requests go through; one the bus makes is closed by `close` (constructor only). |
| `clock` | `DateTime.now` | The publication time of a message (constructor only). |

## The REST Proxy

The bus speaks the Kafka REST Proxy API as Confluent REST Proxy
(`cp-kafka-rest`) serves it:

| Call | API | For |
| ---- | --- | --- |
| `GET /v3/clusters` | v3 | The cluster id |
| `POST /v3/clusters/<cluster>/topics`, `GET .../topics/<topic>` | v3 | Creating a topic, and telling an existing one from a refusal |
| `POST /topics/<topic>` | v2 | Producing a record (`application/vnd.kafka.json.v2+json`) |
| `POST /consumers/<group>` | v2 | Creating a consumer instance |
| `POST .../instances/<instance>/subscription` | v2 | Subscribing it to the topic |
| `GET .../instances/<instance>/records` | v2 | Fetching records |
| `GET .../instances/<instance>/assignments` | v2 | The partitions the group gave it |
| `POST .../instances/<instance>/offsets` | v2 | Committing |
| `DELETE .../instances/<instance>` | v2 | Removing it |

v2 has no topic creation, so topics are created through v3. The cluster
behind the proxy may be Kafka or Redpanda. Redpanda's own HTTP proxy does not
serve the bus: it answers no consumer assignments, refuses `auto.offset.reset`
`latest`, and creates no topics. A deployment runs Confluent REST Proxy in
front of its cluster.

A consumer instance lives in the proxy that created it. A deployment with
several proxies behind one address routes a bus to one of them, so that every
request about an instance reaches the proxy holding it.

### Requests and the resilient client

Without a `client`, the requests go through `tom_core_kernel`'s
`TomResilientClient` with the destination's policy: a timeout per attempt,
retries of idempotent calls, a circuit breaker and a bulkhead per destination.
A circuit opened by a failing proxy refuses calls until it closes again; a
record refused that way is `message_bus.kafka.publish_failed`, a consumer
instance that cannot be created or joined `message_bus.kafka.consumer_failed`.

The bulkhead limits the concurrent calls to one destination. A burst of
hundreds of concurrent publishes — `Future.wait` over a loop of `publish` — is
refused beyond that limit with `http.client.bulkhead_full`, wrapped in
`message_bus.kafka.publish_failed`. A publisher that sends many messages at
once publishes them in sequence, or passes a client with another policy.

## The Mapping onto Kafka

| Contract | Kafka |
| -------- | ----- |
| A topic | A Kafka topic of the same name, created with `partitions` partitions on first use |
| A consumer group | A Kafka consumer group of the same name |
| An ephemeral group | A consumer group of the bus's own, `<group>.<bus id>`, that commits no offset |
| Consumers of a group | Consumer instances of the group in the proxy; Kafka assigns each the partitions it reads |
| Publish | A record keyed by the message's key, its value the message envelope |
| Acknowledge | The record's offset committed |
| Reject, redelivered | Handled again in place, attempt by attempt, before the records behind it |
| Dead letter | Published to `<topic>.dlq`, then the offset committed |
| The attempt | Counted by the consumer, in place |
| Ordering per key | Declared |

### Topics

A topic is a Kafka topic name: letters, digits, `.`, `_` and `-`, at most 249
of them, and neither `.` nor `..`. `orders` and `orders.dlq` are topics; a
space or a `/` is refused with `message_bus.kafka.invalid_topic` on `publish`
and `subscribe`. `validTopic(topic)` is the same check without a bus.

The bus creates a topic the first time it publishes or subscribes to it, with
`partitions` partitions and, when set, `replicationFactor`, and remembers it
for the bus's lifetime. A topic that exists is taken as it is, with its own
partitions and retention. The proxy answers a topic that exists with the same
error code, 40002, as a creation it refuses, so after an error the bus asks for
the topic: one that exists is taken, and otherwise the call is refused with
`message_bus.kafka.topic_failed` and the creation is tried again on the next
call. A record stays for the topic's retention, which the cluster sets.

### The record on the wire

The REST Proxy API v2 carries no record headers, so the record's value is an
envelope of the message, and its key is the message's key:

```json
{
  "id": "msg-3f2a...",
  "publishedAt": "2026-11-06T12:00:00.000Z",
  "headers": {"traceparent": "00-..."},
  "payload": {"order": "o-1"}
}
```

`envelopeOf(message)` builds it, `messageOf(topic, key, value)` reads it back
(`null` for a value that is no envelope of this bus). The payload is encoded by
the subscription's `TomBusCodec`. A message without a key is a record without
one, placed in a partition by the producer.

## Consumer Groups

A group is a Kafka consumer group of the same name. Every `subscribe` is one
consumer of it: a consumer instance in the proxy, named `tom-<bus id>-<n>`,
created with the JSON format, `auto.offset.reset` `latest` and auto commit off,
and subscribed to the topic. A loop fetches its records, waiting at most
`fetchWait` per fetch, and handles them one at a time. Kafka assigns the
group's partitions among its instances, so the consumers of a group share its
records (MB-C3, KB-I2); a group with more consumers than partitions leaves some
of them idle.

A group created by its first subscription starts at the end of the topic. It
keeps its committed position while none of its consumers is subscribed, so a
message published in that time waits for the next consumer (MB-C4). A message
published before any group existed reaches no group (MB-C5).

A fetch that fails after the consumer joined is logged, and the loop tries
again after `fetchWait`. `cancel` stops the loop — waiting for the fetch or
the record under way — and deletes the instance in the proxy; one the bus
cannot delete is logged, and the proxy drops it after its own idle timeout.

### Joining a group

`subscribe` answers only once the consumer holds partitions and its position
is committed: after its first fetch it asks for its assignments, and once it
has some it commits with an empty body, which commits the positions its fetch
reached. Every message published after `subscribe` answers is therefore the
group's, and a later consumer of the group starts where this one did. A
consumer the group leaves without partitions — more consumers than partitions —
answers after `joinTimeout` and reads once a partition is free.

An instance the proxy refuses to create, a subscription it refuses, or a first
fetch that fails is refused with `message_bus.kafka.consumer_failed`.

### Ephemeral groups

A group subscribed with `ephemeral: true` is a consumer group of the bus's own,
`<group>.<bus id>`. Its consumers commit no offset, so the group keeps no
position: when the last subscription of it in the bus cancels, what it had not
read is gone with it (MB-C19), and a later subscription starts at the end of the
topic again. Two buses with the same ephemeral group name are two Kafka groups,
each receiving every message (MB-C20).

## Settling and Dead Letters

Each record goes through `tomDispatch` from `tom_core_message_bus`: the payload
is decoded, the handler runs inside `TomBusTrace.delivering`, and the outcome
is mapped onto Kafka:

| Outcome | What the consumer does |
| ------- | ---------------------- |
| Acknowledged (the handler returned or called `ack`) | Commits the record's offset |
| Requeued (the handler threw or called `reject()`) below `maxDeliveries` | Waits `redeliveryDelay` and handles the record again, as the next attempt |
| Requeued at attempt `maxDeliveries` | A dead letter with the reason `max-deliveries`, then the commit |
| Dead-lettered (`reject(requeue: false)`) | A dead letter with the delivery's reason, then the commit |
| The payload does not decode | A dead letter with the reason `undecodable`, then the commit; the handler is not called |

A commit names the record's topic, partition and offset; the proxy stores the
offset after it, the group's next position. A commit that fails is logged, and
the group delivers the record again, which at least once allows. A record whose
value is no envelope of this bus could never be handled; it is committed
without a dead letter.

A dead letter is `tomDeadLetter(message, ...)`: the original message — same
id, key, payload and headers — with the four dead-letter headers, published to
`tomDeadLetterTopic(topic)`, `<topic>.dlq`. That is a topic like any other,
created on first use; a group subscribed to it receives the dead letters. A
dead letter the cluster does not take is published again every `fetchWait`
until it is taken; the record is committed only after it.

A consumer cancelled in the middle of a record — between two attempts, or
while its dead letter is retried — leaves the record uncommitted, and the group
hands it to another consumer.

## Ordering per Key

The bus declares `TomBusCapabilities(orderedPerKey: true)`, and the
conformance suite's ordering test, MB-C18, runs and passes. Three properties
make it hold:

- **A key's records go to one partition.** The record key is the message's
  key, and Kafka places the records of one key in one partition, in publish
  order.
- **A partition is read by one consumer of the group at a time.** Kafka
  assigns each partition to one instance of the group.
- **A redelivery comes before the records behind it.** The attempts of a
  delivery are made in place, so the next record of the partition is handled
  only once this one is acknowledged or dead-lettered.

The cost is the third point: a record that fails holds its partition for up to
`maxDeliveries` attempts, `redeliveryDelay` apart.

## Publishing from the Bus Relay

`tom_core_server`'s `TomBusRelay` queues a message in the caller's database
transaction and publishes it to a bus after the commit. With this bus the
message reaches a Kafka consumer once, under the id the relay chose and with
its key (KB-I1):

```dart
final relay = TomBusRelay(bus: await TomKafkaMessageBus.connect(proxy));
```

The REST proxy has no duplicate detection by message id: a publish the relay
repeats after a crash is a second record, and a consumer that must not act
twice keeps the ids it handled, as the contract's at least once asks. See the
server's [messaging guide](../../../core/tom_core_server/doc/messaging.md#the-bus-relay).

## Closing

`close` refuses further `publish` and `subscribe` calls with
`message_bus.closed`, cancels every consumer — each finishing the record it is
handling and deleting its instance — and closes the HTTP client when the bus
made it. A second call is the same close.

## Error Keys

Every refusal is a `TomBusException`, with its key and parameters.

| Key | Raised when | Parameters |
| --- | ----------- | ---------- |
| `message_bus.kafka.unreachable` | The proxy did not name its cluster, at `connect` or on first use | `proxy` |
| `message_bus.kafka.invalid_topic` | A topic that is no Kafka topic name, on `publish` or `subscribe` | `topic` |
| `message_bus.kafka.topic_failed` | The topic could not be created and does not exist | `topic` |
| `message_bus.kafka.publish_failed` | The proxy or the cluster did not take a record — a refused request, an error code in the produce answer, a call the resilient client refused | `topic`, `message` |
| `message_bus.kafka.consumer_failed` | The group's consumer instance could not be created, subscribed or fetched from | `topic`, `group` |

The bus's own keys — `message_bus.closed`, `message_bus.subscribe.invalid`,
`message_bus.delivery.already_settled`, `message_bus.payload.not_json`,
`message_bus.payload.undecodable` — are raised as for every bus; see the
[message bus guide](../../../core/tom_core_message_bus/doc/message_bus.md#error-keys).

## Not Yet Implemented

- **No native Kafka protocol.** The bus reaches the cluster through a REST
  proxy only; there is no client of the Kafka wire protocol.
- **No duplicate detection.** A repeated publish of one id is a second record.
- **No topic configuration beyond partitions and replication.** A topic the bus
  creates takes the cluster's retention and other defaults; a topic that exists
  is not changed.
- **No record headers.** The message's headers travel inside the envelope,
  since the REST Proxy API v2 carries none.

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/kafka_bus_test.dart` | Offline, against a mock proxy. KB-U1 a topic that is no Kafka topic name refused with `message_bus.kafka.invalid_topic`; KB-U2 a message surviving its record envelope; KB-U3 an unreachable proxy refused at `connect` with `message_bus.kafka.unreachable`; KB-U4 a topic the cluster refuses to create (`message_bus.kafka.topic_failed`); KB-U5 a topic that exists taken as it is; KB-U6 a record the cluster does not take (`message_bus.kafka.publish_failed`); KB-U7 a consumer instance the proxy refuses (`message_bus.kafka.consumer_failed`); KB-U8 a closed bus refusing to publish (`message_bus.closed`); KB-U9 ordering per key declared. |
| `test/kafka_conformance_test.dart` | Tagged `kafka`. The bus's conformance suite, MB-C1 to MB-C20, against a REST proxy in front of a cluster, MB-C18 included; KB-I1 a message queued on `TomBusRelay` reaching a Kafka consumer once, under its id and key; KB-I2 two consumers of a group sharing its partitions, each of sixty keyed records handled once and both consumers handling some. Skips itself unless `TOM_KAFKA_REST_TEST_URL` names a proxy. |
| `test/example_test.dart` | Tagged `kafka`. The example runs to the end against the proxy. |

```bash
dart test                     # the unit suite; the kafka tests skip
./tool/run_kafka_tests.sh     # the kafka suite against Redpanda and REST Proxy containers
```

`tool/run_kafka_tests.sh` starts two containers on a Docker network of their
own: Redpanda (`redpandadata/redpanda:v24.2.7`, one container serving the
Kafka API, with 1 GB of memory) as the cluster, and Confluent REST Proxy
(`confluentinc/cp-kafka-rest:7.7.1`) in front of it on `127.0.0.1:18092`
(`KAFKA_REST_TEST_PORT` overrides the port, `REDPANDA_IMAGE` and
`KAFKA_REST_IMAGE` the images). It waits until the proxy answers
`/v3/clusters`, runs `dart test --tags kafka` with `TOM_KAFKA_REST_TEST_URL`
pointing at it, and removes both containers and the network. A run in which
every test skipped is reported as a failure, because it means the proxy never
answered. It needs Docker. The suite's result: 23 passed, none skipped; the
nine untagged unit tests pass without a cluster.

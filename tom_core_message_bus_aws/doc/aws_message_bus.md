# AWS Message Bus

`TomAwsMessageBus` keeps the `TomMessageBus` contract of
[`tom_core_message_bus`](../../../core/tom_core_message_bus/doc/message_bus.md)
over Amazon SNS and SQS, reached through their HTTP APIs. This page covers the
AWS side: how the bus is constructed and signs its requests, how each point of
the contract maps onto topics, queues and subscriptions, how deliveries are
settled and dead-lettered, why the bus does not order per key, the error keys,
and how the suite runs. The contract itself — consumer groups, at least once,
codecs, headers and trace — is in the message bus guide.

## Table of Contents

- [Constructing the Bus](#constructing-the-bus)
- [Credentials and Signing](#credentials-and-signing)
  - [The two APIs](#the-two-apis)
  - [Requests and the resilient client](#requests-and-the-resilient-client)
- [The Mapping onto SNS and SQS](#the-mapping-onto-sns-and-sqs)
  - [Names](#names)
  - [The message on the wire](#the-message-on-the-wire)
- [Consumer Groups](#consumer-groups)
  - [The group's queue](#the-groups-queue)
  - [Ephemeral groups](#ephemeral-groups)
- [Settling and Dead Letters](#settling-and-dead-letters)
  - [The visibility timeout](#the-visibility-timeout)
- [No Ordering per Key](#no-ordering-per-key)
- [Publishing from the Bus Relay](#publishing-from-the-bus-relay)
- [Closing](#closing)
- [Error Keys](#error-keys)
- [Not Yet Implemented](#not-yet-implemented)
- [Verification](#verification)

## Constructing the Bus

The constructor takes a region and a credentials source; nothing is asked of
AWS until the first publish or subscribe:

```dart
final bus = TomAwsMessageBus(
  region: 'eu-central-1',
  credentials: roleCredentials,
  namePrefix: 'billing',
  visibilityTimeout: const Duration(seconds: 60),
  fetchWait: const Duration(seconds: 10),
);
```

`withKeys` builds the credentials source from static keys and lets one endpoint
serve both services — LocalStack's, say:

```dart
final bus = TomAwsMessageBus.withKeys(
  region: 'us-east-1',
  accessKeyId: 'test',
  secretAccessKey: 'test',
  endpoint: Uri.parse('http://localhost:4566'),
);
```

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `region` | — | The region the topics and queues live in, and the signature's region. |
| `credentials` | — | The `TomAwsCredentialsSource` every request is signed with (constructor only; `withKeys` builds one from `accessKeyId`, `secretAccessKey` and `sessionToken`). |
| `sqsEndpoint`, `snsEndpoint` | `https://sqs.<region>.amazonaws.com/`, `https://sns.<region>.amazonaws.com/` | The two endpoints — a VPC endpoint or an emulator (constructor only; `withKeys` takes one `endpoint` for both). |
| `namePrefix` | `tombus` | The first part of every topic and queue name. |
| `visibilityTimeout` | 30 s | How long a received message stays hidden from the group's other consumers; the queue's `VisibilityTimeout`, in whole seconds (constructor only). |
| `fetchWait` | 1 s | How long one receive waits for a message, in whole seconds from 1 to 20; the longest a `cancel` waits, and the pause after a failed receive (constructor only). |
| `httpClient` | a `TomResilientClient` | The `package:http` client the requests go through; one the bus makes is closed by `close` (constructor only). |
| `clock` | `DateTime.now` | The publication time of a message and the signing time (constructor only). |

## Credentials and Signing

A `TomAwsCredentialsSource` is `tom_core_server`'s
`Future<TomAwsCredentials> Function()`. The bus calls it for **every request**,
so the source decides how long a set of credentials lives: `withKeys` answers
one fixed `TomAwsCredentials`, and a deployment on an instance profile, a
container task role or an assumed role passes a source that returns the role's
current temporary credentials, cached by the source until shortly before they
expire. The bus calls no credential endpoint of its own.

Each request is a `POST` signed with Signature Version 4 by `tom_core_server`'s
`TomAwsV4Signer`, for the service `sqs` or `sns`, over the SHA-256 of its body.
The `host` header is signed and left to the HTTP client to send, which sets it
from the URL.

### The two APIs

| Service | Protocol | Request | Answer |
| ------- | -------- | ------- | ------ |
| SQS | JSON (`content-type: application/x-amz-json-1.0`, `x-amz-target: AmazonSQS.<action>`) | A JSON body | JSON; an error's `__type` and `message` |
| SNS | Query (`Action`, `Version=2010-03-31`, form-encoded) | Form parameters | XML; an error's `Code` and `Message` |

The calls the bus makes:

| Call | For |
| ---- | --- |
| SNS `CreateTopic` | A topic's ARN; it answers the ARN of a topic that exists, so every node may call it |
| SNS `Publish` | Publishing a message and a dead letter |
| SNS `Subscribe` (`Protocol` `sqs`, `RawMessageDelivery`) | Subscribing a group's queue to its topic |
| SNS `Unsubscribe` | Removing an ephemeral group's subscription |
| SQS `CreateQueue`, `GetQueueAttributes`, `SetQueueAttributes` | Creating a group's queue, reading its ARN, setting its policy |
| SQS `ReceiveMessage` | Long-polling a queue, one message at a time |
| SQS `DeleteMessage` | Acknowledging |
| SQS `ChangeMessageVisibility` | Handing a message back to the group |
| SQS `DeleteQueue` | Removing an ephemeral group's queue |

`sqs(action, request)` and `sns(action, parameters)` are the two signed calls,
public so a test or a tool administers the same resources through them.
`xmlValue(xml, element)` reads one element of an SNS answer.

### Requests and the resilient client

Without an `httpClient`, the requests go through `tom_core_kernel`'s
`TomResilientClient` with the destination's policy: a timeout per attempt,
retries of idempotent calls, a circuit breaker and a bulkhead per destination.
The bulkhead limits the concurrent calls to one destination, so a burst of
hundreds of concurrent publishes is refused beyond that limit; a publisher that
sends many messages at once publishes them in sequence, or passes a client with
another policy.

## The Mapping onto SNS and SQS

| Contract | AWS |
| -------- | --- |
| A topic | A standard SNS topic, `<namePrefix>-<topic>-<hash>` |
| A consumer group | A standard SQS queue, `<namePrefix>-<topic>-<group>-<hash>`, subscribed to the topic with raw message delivery |
| An ephemeral group | A queue of the bus's own, created on subscription and unsubscribed and deleted when its last consumer cancels |
| Consumers of a group | Long-polling loops on the group's queue, each receiving one message at a time |
| Publish | `Publish` of the message envelope to the topic |
| Acknowledge | `DeleteMessage` |
| Reject, redelivered | `ChangeMessageVisibility` to 0: the queue delivers it again at once |
| Dead letter | Published to `<topic>.dlq`'s SNS topic, then deleted from the queue |
| The attempt | The message's `ApproximateReceiveCount` |
| Message id | Carried in the message envelope |
| Ordering per key | Not declared |

### Names

A topic's SNS name is `topicNameOf(namePrefix, topic)`: the prefix, the topic
with every character other than letters, digits, `_` and `-` replaced by `_`
and cut to 160 characters, and an eight-digit hexadecimal FNV-1a hash of the
topic as given. The hash keeps apart two topics the replacement maps alike:
`a.b` and `a_b` are two SNS topics. `orders.dlq` is `tombus-orders_dlq-<hash>`.

A group's queue name is `queueNameOf(namePrefix, topic, group)`: the prefix
cut to 30 characters, the topic and the group replaced the same way and sharing
what is left of SQS's 80 characters, and a hash of the pair; an ephemeral
group's queue adds a suffix. Every name stays within 80 characters, whatever
the lengths of its parts.

### The message on the wire

SNS carries ten message attributes at most, so the message travels as one JSON
envelope in the body, and raw message delivery puts that body into the queue
unchanged:

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
`messageOf(topic, body)` reads it back — `null` for a body that is not JSON or
is no envelope of this bus. The payload is encoded by the subscription's
`TomBusCodec`.

## Consumer Groups

A group is an SQS queue. Every `subscribe` is one consumer of it: a loop that
calls `ReceiveMessage` for one message, waiting up to `fetchWait` for one, and
handles it before it receives the next. SQS hands each message to one receiver
at a time, so the consumers of a group share its messages (MB-C3).

A receive that fails is logged, and the loop tries again after `fetchWait`.
`cancel` stops the loop, waiting for the receive or the message under way; a
message received after the cancel is handed back to the group with
`ChangeMessageVisibility` to 0.

### The group's queue

The first subscription of a durable group in a bus creates its queue —
`CreateQueue` with `VisibilityTimeout` set to `visibilityTimeout` and
`MessageRetentionPeriod` to 1209600 seconds (14 days, the most SQS keeps a
message) — reads its ARN, sets its policy and subscribes it to the topic with
raw message delivery. `subscribe` answers once that is done. The policy is
`queuePolicy(queueArn, topicArn)`: the service `sns.amazonaws.com` may call
`sqs:SendMessage` on the queue only when the source is that topic.

The queue stays when the group's consumers cancel, so a message published while
none of them is polling waits for the next (MB-C4), for up to 14 days. A
message published to a topic no queue is subscribed to reaches no one (MB-C5).
The bus deletes neither durable queues nor topics.

A queue SQS does not create — or whose attributes or subscription are refused —
is refused with `message_bus.aws.consumer_failed`; a topic SNS does not create
with `message_bus.aws.topic_failed`.

### Ephemeral groups

A group subscribed with `ephemeral: true` is a queue of the bus's own, named
with a suffix of the bus id and a random part. The name is fresh each time
the group is subscribed in the bus, because SQS refuses for 60 seconds to
create a queue under the name of one just deleted. The consumers of the group
in one bus share that queue. When the last of them cancels, its subscription
is removed with `Unsubscribe` and the queue deleted with `DeleteQueue`, and
what waited in it is gone (MB-C19); a removal that fails is logged. Two buses
with the same ephemeral group name have two queues, each receiving every
message (MB-C20).

## Settling and Dead Letters

Each message goes through `tomDispatch` from `tom_core_message_bus`: the
payload is decoded, the handler runs inside `TomBusTrace.delivering`, and the
outcome is mapped onto SQS:

| Outcome | What the consumer does |
| ------- | ---------------------- |
| Acknowledged (the handler returned or called `ack`) | `DeleteMessage` |
| Requeued (the handler threw or called `reject()`) below `maxDeliveries` | `ChangeMessageVisibility` to 0: the queue delivers it again, to any consumer of the group, as the next attempt |
| Requeued at attempt `maxDeliveries` | A dead letter with the reason `max-deliveries`, then `DeleteMessage` |
| Dead-lettered (`reject(requeue: false)`) | A dead letter with the delivery's reason, then `DeleteMessage` |
| The payload does not decode | A dead letter with the reason `undecodable`, then `DeleteMessage`; the handler is not called |

The attempt is the message's `ApproximateReceiveCount`, which SQS counts across
every receive of the message by any consumer of the group. A message whose body
is no envelope of this bus could never be handled; it is deleted without a dead
letter. A `DeleteMessage` or `ChangeMessageVisibility` that fails is logged,
and the message comes back after the visibility timeout, which at least once
allows.

A dead letter is `tomDeadLetter(message, ...)`: the original message — same
id, key, payload and headers — with the four dead-letter headers, published to
the SNS topic of `tomDeadLetterTopic(topic)`, `<topic>.dlq`. That is a topic
like any other, created on first use; a group subscribed to it receives the
dead letters. A dead letter SNS does not take is logged and the message is not
deleted: it comes back after the visibility timeout, at the next attempt, and
is settled again.

### The visibility timeout

A received message stays hidden from the group's other consumers for
`visibilityTimeout`; the bus does not extend it while the handler runs. A
handler that runs longer than that sees its message delivered again — to
another consumer, or to the same one after it finished — under the same id and
a higher attempt. A deployment whose handlers run long sets
`visibilityTimeout` above the longest of them.

## No Ordering per Key

The bus declares `const TomBusCapabilities()`, without ordering per key, and
the conformance suite's ordering test, MB-C18, is skipped. Standard SQS queues
neither order nor deduplicate: messages reach the group's consumers in no fixed
order, a redelivery goes back to the queue among the messages behind it, and a
message can, rarely, be delivered twice. The message's key travels in the
envelope and reaches the handler, but no AWS resource is keyed by it.

## Publishing from the Bus Relay

`tom_core_server`'s `TomBusRelay` queues a message in the caller's database
transaction and publishes it to a bus after the commit. With this bus the
message reaches an SQS consumer once, under the id the relay chose and with its
key (AB-I1):

```dart
final relay = TomBusRelay(
  bus: TomAwsMessageBus(region: region, credentials: source),
);
```

SNS and standard SQS have no duplicate detection by message id: a publish the
relay repeats after a crash is a second message, and a consumer that must not
act twice keeps the ids it handled, as the contract's at least once asks. See
the server's [messaging guide](../../../core/tom_core_server/doc/messaging.md#the-bus-relay).

## Closing

`close` refuses further `publish` and `subscribe` calls with
`message_bus.closed`, cancels every consumer — each finishing the message it is
handling, and an ephemeral group's last consumer removing its queue — and
closes the HTTP client when the bus made it. A second call is the same close.

## Error Keys

Every refusal is a `TomBusException`, with its key and parameters.

| Key | Raised when | Parameters |
| --- | ----------- | ---------- |
| `message_bus.aws.topic_failed` | SNS did not create the topic or answered no `TopicArn`, on `publish` or `subscribe` | `topic` |
| `message_bus.aws.publish_failed` | SNS did not take the `Publish` — a refused request, a call the resilient client refused | `topic`, `message` |
| `message_bus.aws.consumer_failed` | The group's queue could not be created, given its policy or subscribed to the topic | `topic`, `group` |

The bus's own keys — `message_bus.closed`, `message_bus.subscribe.invalid`,
`message_bus.delivery.already_settled`, `message_bus.payload.not_json`,
`message_bus.payload.undecodable` — are raised as for every bus; see the
[message bus guide](../../../core/tom_core_message_bus/doc/message_bus.md#error-keys).

## Not Yet Implemented

- **No FIFO queues.** The bus creates standard topics and queues only, so it
  declares no ordering per key and does not deduplicate.
- **No visibility extension.** A handler running longer than
  `visibilityTimeout` sees its message again; the timeout is not extended while
  the handler runs.
- **No built-in role credentials.** The instance metadata service, the
  container credentials endpoint and STS `AssumeRole` are not called by the
  package; a role is supplied as a `TomAwsCredentialsSource`.
- **No resource removal beyond ephemeral groups.** Topics and durable queues
  stay after the bus is closed; removing them is the deployment's.
- **No batching.** One `Publish` per message, one message per `ReceiveMessage`.

## Verification

| Suite | Settles |
| ----- | ------- |
| `test/aws_bus_test.dart` | Offline, against a mock client playing SNS and SQS. AB-U1 topics and queues named after their topic and group, kept apart by a hash, queues within 80 characters; AB-U2 a message surviving its envelope, a foreign body none; AB-U3 the queue policy letting the one topic, and nothing else, send to the queue; AB-U4 an XML value read and unescaped; AB-U5 a topic SNS does not create (`message_bus.aws.topic_failed`); AB-U6 a publish SNS refuses (`message_bus.aws.publish_failed`); AB-U7 a queue SQS does not create (`message_bus.aws.consumer_failed`); AB-U8 a closed bus refusing to publish (`message_bus.closed`); AB-U9 every request signed for its service, `sns` and `sqs`. |
| `test/aws_conformance_test.dart` | Tagged `aws`. The bus's conformance suite, MB-C1 to MB-C20, against SNS and SQS — MB-C18 skipped, since the bus does not declare ordering per key; AB-I1 a message queued on `TomBusRelay` reaching an SQS consumer once, under its id and key. Skips itself unless `TOM_AWS_TEST_ENDPOINT` names an endpoint. |
| `test/example_test.dart` | Tagged `aws`. The example runs to the end against the endpoint. |

```bash
dart test                   # the unit suite; the aws tests skip
./tool/run_aws_tests.sh     # the aws suite against a LocalStack container
```

`tool/run_aws_tests.sh` starts LocalStack (`localstack/localstack:3.8`, with
`SERVICES=sns,sqs`) on `127.0.0.1:14567` (`AWS_TEST_PORT` overrides the port,
`LOCALSTACK_IMAGE` the image). It waits until LocalStack's health check reports
both services, runs `dart test --tags aws` with `TOM_AWS_TEST_ENDPOINT` pointing
at it, and removes the container. A run in which every test skipped is reported
as a failure, because it means LocalStack never answered. It needs Docker. The
suite's result: 21 passed, 1 skipped (MB-C18); the nine untagged unit tests
pass without an endpoint.

LocalStack checks less than AWS. It accepts any key, so the signature is
checked offline instead — AB-U9 for the scope of each request, and
`TomAwsV4Signer` itself against AWS's published test vectors in
`tom_core_server`. It does not enforce queue policies, so a policy that would
keep the topic out is not caught there; AB-U3 checks the policy the bus writes.

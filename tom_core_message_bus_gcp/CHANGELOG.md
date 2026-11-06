# Changelog

## 0.1.0

The first release: the Google Cloud adapter of the Tom message bus, in
`tom_core_extensions`.

- **`TomPubSubMessageBus`**: a `TomMessageBus` over Google Cloud Pub/Sub,
  through its REST API, with no Google SDK. A constructor over a `projectId`
  (`token`, `endpoint` defaulting to `https://pubsub.googleapis.com/`,
  `namePrefix` `tombus`, `ackDeadline` 60 seconds, `fetchWait` 500 ms,
  `redeliveryDelay` 100 ms, `httpClient`, `clock`). The requests go through
  `tom_core_kernel`'s `TomResilientClient` unless a client is passed.
- **Authentication**: `TomGcpTokenSource`, the access token of every request;
  `serviceAccount(keyJson, projectId, endpoint, namePrefix)`, a bus
  authenticated with a service-account key file through `tom_core_server`'s
  `TomFcmServiceAccountCredential` asking for `pubsubScope`
  (`serviceAccountCredential`); `metadataServer()`, a token source asking the
  host's metadata server, cached until a minute before the token expires; no
  token for the emulator.
- **The mapping onto Pub/Sub**: a topic per topic,
  `<namePrefix>-<topic>-<hash>`; a subscription per group,
  `<namePrefix>-<topic>-<group>-<hash>`, with message ordering enabled and the
  ack deadline `ackDeadline`; an ephemeral group as a subscription of the bus's
  own, deleted when its last consumer cancels. A topic or subscription that
  exists is taken.
- **Consuming**: a loop per subscription pulling one message at a time with
  `returnImmediately`, pausing `fetchWait` when the pull is empty.
- **Settling**: acknowledge is `acknowledge`; a redelivery handles the message
  again in place, `redeliveryDelay` apart, its ack deadline extended between
  attempts, the attempt counted by the consumer; a dead letter is published to
  `<topic>.dlq`, then the message acknowledged. Each delivery goes through
  `tomDispatch`, each dead letter is `tomDeadLetter`.
- **The message**: one JSON envelope in the base64 message data,
  `{id, key, publishedAt, headers, payload}` (`envelopeOf`, `messageOf`), the
  message's key as its `orderingKey`.
- **Capabilities**: ordering per key.
- **Names and helpers**: `topicIdOf`, `subscriptionIdOf`, `topicName`; `call`,
  the REST call, and `PubSubError`, an error answer.
- **Error keys**: `message_bus.pubsub.topic_failed`,
  `message_bus.pubsub.publish_failed`, `message_bus.pubsub.consumer_failed`,
  `message_bus.pubsub.no_project`, `message_bus.pubsub.no_token`.
- **Tests**: the offline unit suite GB-U1 to GB-U10 against a mock client; the
  bus's conformance suite MB-C1 to MB-C20, the relay test GB-I1 and the example
  against the Pub/Sub emulator, tagged `gcp` and run by `tool/run_gcp_tests.sh`
  (22 passed, none skipped).
- **Example**: `example/gcp_message_bus_example.dart`.

# Changelog

## 0.1.0

The first release: the Kafka adapter of the Tom message bus, in
`tom_core_extensions`.

- **`TomKafkaMessageBus`**: a `TomMessageBus` over a Kafka cluster, reached
  through the Kafka REST Proxy API as Confluent REST Proxy serves it (v2 for
  records and consumer instances, v3 for naming the cluster and creating
  topics). A constructor over the proxy's URI (`partitions` 3,
  `replicationFactor`, `fetchWait` 500 ms, `redeliveryDelay` 100 ms,
  `joinTimeout` 20 seconds, `client`, `clock`) and `connect(proxy, ...)`, which
  answers once the proxy named its cluster. The requests go through
  `tom_core_kernel`'s `TomResilientClient` unless a client is passed.
- **The mapping onto Kafka**: a Kafka topic per topic, created on first use
  with `partitions` partitions and the optional `replicationFactor`, a topic
  that exists taken as it is; a Kafka consumer group per group, starting at the
  end of the topic with auto commit off; an ephemeral group as
  `<group>.<bus id>`, committing no offset; a consumer instance per
  subscription, `subscribe` answering once it holds partitions (or after
  `joinTimeout`) and its position is committed.
- **Settling**: acknowledge commits the record's offset; a redelivery handles
  the record again in place, `redeliveryDelay` apart; a dead letter is
  published to `<topic>.dlq`, repeated until taken, then committed. Each
  delivery goes through `tomDispatch`, each dead letter is `tomDeadLetter`.
- **The record**: keyed by the message's key, its value the envelope
  `{id, publishedAt, headers, payload}` (`envelopeOf`, `messageOf`), since the
  REST Proxy API v2 carries no record headers.
- **Capabilities**: ordering per key.
- **Topic names**: `validTopic`, letters, digits, `.`, `_` and `-`, at most
  249.
- **Content types**: `jsonRecords` and `v2`.
- **Error keys**: `message_bus.kafka.unreachable`,
  `message_bus.kafka.invalid_topic`, `message_bus.kafka.topic_failed`,
  `message_bus.kafka.publish_failed`, `message_bus.kafka.consumer_failed`.
- **Tests**: the offline unit suite KB-U1 to KB-U9 against a mock proxy; the
  bus's conformance suite MB-C1 to MB-C20, the relay test KB-I1, the
  shared-group test KB-I2 and the example against Confluent REST Proxy in front
  of Redpanda, tagged `kafka` and run by `tool/run_kafka_tests.sh` (23 passed,
  none skipped).
- **Example**: `example/kafka_message_bus_example.dart`.

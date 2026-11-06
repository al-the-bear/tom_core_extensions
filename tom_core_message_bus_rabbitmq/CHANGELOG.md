# Changelog

## 0.1.0

The first release: the RabbitMQ adapter of the Tom message bus, in
`tom_core_extensions`.

- **`TomRabbitMqMessageBus`**: a `TomMessageBus` over a RabbitMQ broker
  (AMQP 0-9-1), built on `dart_amqp` from the fork `al-the-bear/tom_dart_amqp`,
  branch `tom/0.3.1-fixes` (`0.3.1+tom.1`). A constructor over a `Client`
  (`namePrefix` `tombus`, `confirmTimeout` 10 seconds, `ownsClient`, `clock`)
  and `connect(uri, ...)`, which owns the connection it opens; `settingsOf`
  reads `amqp://user:password@host:port/vhost` (defaults `guest` / `guest`,
  5672, the virtual host `/`, `/%2F` too).
- **The mapping onto RabbitMQ**: a durable fanout exchange per topic,
  `<namePrefix>.<topic>_<hash>`; a durable queue per consumer group,
  `<namePrefix>.<topic>.<group>_<hash>`, bound to it; an ephemeral group as an
  exclusive, auto-deleted queue of the bus's connection, suffixed with the bus
  id, deleted by the broker when its last consumer cancels; a channel of its
  own with a prefetch of one per consumer.
- **Publisher confirms**: every publish is persistent and answers once the
  broker confirmed it, within `confirmTimeout`.
- **Settling**: `basic.ack` to acknowledge; a redelivery as a confirmed copy on
  the group's queue with the next attempt in `Tom-Bus-Attempt`, then the ack; a
  dead letter as a confirmed publish to `<topic>.dlq`, then the ack; a copy the
  broker does not confirm rejects the delivery back to the queue after
  200 ms. Each delivery goes through `tomDispatch`, each dead letter is
  `tomDeadLetter`.
- **Message fields**: the id as the AMQP `message-id`; `Tom-Bus-Key`,
  `Tom-Bus-Published-At` and `Tom-Bus-Attempt` (`keyHeader`,
  `publishedAtHeader`, `attemptHeader`); the body is the payload's JSON.
- **Naming helpers**: `exchangeOf` and `queueOf`.
- **Capabilities**: no ordering per key.
- **Error keys**: `message_bus.rabbitmq.unreachable`,
  `message_bus.rabbitmq.publish_failed`,
  `message_bus.rabbitmq.consumer_failed`.
- **Tests**: the offline unit suite RB-U1 to RB-U3; the bus's conformance
  suite MB-C1 to MB-C20, the relay test RB-I1, the burst test RB-I2 (500
  publishes confirmed in full), the refusals RB-E1 to RB-E4 and the example
  against a RabbitMQ broker, tagged `rabbitmq` and run by
  `tool/run_rabbitmq_tests.sh` (26 passed, MB-C18 skipped).
- **Example**: `example/rabbitmq_message_bus_example.dart`.

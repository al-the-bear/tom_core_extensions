# tom_core_message_bus_rabbitmq — documentation

The catalogue of this package's documentation. The package
[README](../README.md) says what the package is for and how a service connects
a bus; the pages below carry the detail.

| Document | Covers |
| -------- | ------ |
| [rabbitmq_message_bus.md](rabbitmq_message_bus.md) | Connecting, how the contract maps onto exchanges and queues, consumer groups (durable and ephemeral), publisher confirms, settling and dead letters, the AMQP client fork, the error keys, what is not implemented, and running the suite |
| [api/api_summary_index.md](api/api_summary_index.md) | The API reference index |
| [api/api_summary_rabbitmq_message_bus.md](api/api_summary_rabbitmq_message_bus.md) | `TomRabbitMqMessageBus`: every public member, with signatures |

**Elsewhere in the workspace:**

| Document | Covers |
| -------- | ------ |
| [`tom_core_message_bus/doc/message_bus.md`](../../../core/tom_core_message_bus/doc/message_bus.md) | The `TomMessageBus` contract, codecs, headers and trace, writing an adapter, and the conformance suite |
| [`tom_core_message_bus/doc/api/api_summary_message_bus.md`](../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md) | The contract's types: `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`, `TomBusCodec`, `TomBusException` and the rest |
| [`tom_core_server/doc/messaging.md`](../../../core/tom_core_server/doc/messaging.md#the-bus-relay) § The Bus Relay | `TomBusRelay`: messages queued in a database transaction and published to a bus after the commit |
| [`tom_core_message_bus_nats/doc/nats_message_bus.md`](../../tom_core_message_bus_nats/doc/nats_message_bus.md) | The NATS JetStream adapter |
| [`tom_core_message_bus_kafka/doc/kafka_message_bus.md`](../../tom_core_message_bus_kafka/doc/kafka_message_bus.md) | The Kafka adapter, over a REST proxy |

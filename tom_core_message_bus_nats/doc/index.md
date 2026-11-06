# tom_core_message_bus_nats — documentation

The catalogue of this package's documentation. The package
[README](../README.md) says what the package is for and how a service connects
a bus; the pages below carry the detail.

| Document | Covers |
| -------- | ------ |
| [nats_message_bus.md](nats_message_bus.md) | Connecting, how the contract maps onto JetStream, consumer groups (durable and ephemeral), settling and dead letters, retention and the duplicate window, the error keys, what is not implemented, and running the suite |
| [api/api_summary_index.md](api/api_summary_index.md) | The API reference index |
| [api/api_summary_nats_message_bus.md](api/api_summary_nats_message_bus.md) | `TomNatsMessageBus`: every public member, with signatures |

**Elsewhere in the workspace:**

| Document | Covers |
| -------- | ------ |
| [`tom_core_message_bus/doc/message_bus.md`](../../../core/tom_core_message_bus/doc/message_bus.md) | The `TomMessageBus` contract, codecs, headers and trace, writing an adapter, and the conformance suite |
| [`tom_core_message_bus/doc/api/api_summary_message_bus.md`](../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md) | The contract's types: `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`, `TomBusCodec`, `TomBusException` and the rest |
| [`tom_core_server/doc/messaging.md`](../../../core/tom_core_server/doc/messaging.md#the-bus-relay) § The Bus Relay | `TomBusRelay`: messages queued in a database transaction and published to a bus after the commit |
| [`tom_core_message_bus_rabbitmq/doc/rabbitmq_message_bus.md`](../../tom_core_message_bus_rabbitmq/doc/rabbitmq_message_bus.md) | The RabbitMQ adapter |
| [`tom_core_message_bus_kafka/doc/kafka_message_bus.md`](../../tom_core_message_bus_kafka/doc/kafka_message_bus.md) | The Kafka adapter, over a REST proxy |
| [`tom_core_message_bus_aws/doc/aws_message_bus.md`](../../tom_core_message_bus_aws/doc/aws_message_bus.md) | The AWS adapter, over SNS and SQS |
| [`tom_core_message_bus_gcp/doc/gcp_message_bus.md`](../../tom_core_message_bus_gcp/doc/gcp_message_bus.md) | The Google Cloud Pub/Sub adapter |
| [`tom_core_message_bus_azure/doc/azure_message_bus.md`](../../tom_core_message_bus_azure/doc/azure_message_bus.md) | The Azure Service Bus adapter, over AMQP 1.0 |

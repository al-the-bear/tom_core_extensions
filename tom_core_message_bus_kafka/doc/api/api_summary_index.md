# Tom Core Message Bus Kafka API Reference: Index

API summaries for `tom_core_message_bus_kafka` — the Kafka adapter of the Tom
message bus. The barrel (`lib/tom_core_message_bus_kafka.dart`) exports one
module, documented here.

Each summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors / static & instance members). Only public
members are listed; `_`-prefixed declarations are omitted.

## Quick Navigation

| Module | Summary | What it provides |
| ------ | ------- | ---------------- |
| Kafka Message Bus | [api_summary_kafka_message_bus.md](api_summary_kafka_message_bus.md) | `TomKafkaMessageBus`: the `TomMessageBus` contract over Kafka through a REST proxy, its topic check, the record envelope and the content types. |

## Modules

### Kafka Message Bus (`lib/src/kafka_bus.dart`)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `TomKafkaMessageBus` | class | A `TomMessageBus` over a Kafka cluster through the Kafka REST Proxy API: a Kafka topic per topic, a consumer group per group, ordering per key. |

## Alphabetical Type Index

| Type | Module |
| ---- | ------ |
| `TomKafkaMessageBus` | Kafka Message Bus |

The contract's own types — `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`,
`TomBusCodec`, `TomBusException` and the rest — are in
[`tom_core_message_bus`'s API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

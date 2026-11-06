# Tom Core Message Bus RabbitMQ API Reference: Index

API summaries for `tom_core_message_bus_rabbitmq` — the RabbitMQ adapter of
the Tom message bus. The barrel (`lib/tom_core_message_bus_rabbitmq.dart`)
exports one module, documented here.

Each summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors / static & instance members). Only public
members are listed; `_`-prefixed declarations are omitted.

## Quick Navigation

| Module | Summary | What it provides |
| ------ | ------- | ---------------- |
| RabbitMQ Message Bus | [api_summary_rabbitmq_message_bus.md](api_summary_rabbitmq_message_bus.md) | `TomRabbitMqMessageBus`: the `TomMessageBus` contract over RabbitMQ, its connection settings, naming helpers and header constants. |

## Modules

### RabbitMQ Message Bus (`lib/src/rabbitmq_bus.dart`)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `TomRabbitMqMessageBus` | class | A `TomMessageBus` over a RabbitMQ broker: a durable fanout exchange per topic, a durable queue per group, an exclusive auto-deleted queue per ephemeral group, publishes confirmed by the broker. |

## Alphabetical Type Index

| Type | Module |
| ---- | ------ |
| `TomRabbitMqMessageBus` | RabbitMQ Message Bus |

The contract's own types — `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`,
`TomBusCodec`, `TomBusException` and the rest — are in
[`tom_core_message_bus`'s API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

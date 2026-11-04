# Tom Core Message Bus NATS API Reference: Index

API summaries for `tom_core_message_bus_nats` — the NATS JetStream adapter of
the Tom message bus. The barrel (`lib/tom_core_message_bus_nats.dart`) exports
one module, documented here.

Each summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors / static & instance members). Only public
members are listed; `_`-prefixed declarations are omitted.

## Quick Navigation

| Module | Summary | What it provides |
| ------ | ------- | ---------------- |
| NATS Message Bus | [api_summary_nats_message_bus.md](api_summary_nats_message_bus.md) | `TomNatsMessageBus`: the `TomMessageBus` contract over NATS JetStream, its connection, naming helpers and header constants. |

## Modules

### NATS Message Bus (`lib/src/nats_bus.dart`)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `TomNatsMessageBus` | class | A `TomMessageBus` over a NATS server with JetStream: a stream per topic, a durable pull consumer per group. |

## Alphabetical Type Index

| Type | Module |
| ---- | ------ |
| `TomNatsMessageBus` | NATS Message Bus |

The contract's own types — `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`,
`TomBusCodec`, `TomBusException` and the rest — are in
[`tom_core_message_bus`'s API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

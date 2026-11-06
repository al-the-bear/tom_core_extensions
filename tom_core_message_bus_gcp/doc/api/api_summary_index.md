# Tom Core Message Bus GCP API Reference: Index

API summaries for `tom_core_message_bus_gcp` — the Google Cloud Pub/Sub adapter
of the Tom message bus. The barrel (`lib/tom_core_message_bus_gcp.dart`)
exports one module, documented here.

Each summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors / static & instance members, typedefs). Only
public members are listed; `_`-prefixed declarations are omitted.

## Quick Navigation

| Module | Summary | What it provides |
| ------ | ------- | ---------------- |
| GCP Message Bus | [api_summary_gcp_message_bus.md](api_summary_gcp_message_bus.md) | `TomPubSubMessageBus`: the `TomMessageBus` contract over Pub/Sub, its token sources, the names it gives topics and subscriptions, the message envelope and the REST call; `TomGcpTokenSource`; `PubSubError`. |

## Modules

### GCP Message Bus (`lib/src/pubsub_bus.dart`)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `TomPubSubMessageBus` | class | A `TomMessageBus` over Google Cloud Pub/Sub through its REST API: a topic per topic, a subscription per group, ordering per key. |
| `TomGcpTokenSource` | typedef | Supplies the access token a Pub/Sub request carries. |
| `PubSubError` | class | An error answer of Pub/Sub: HTTP status, gRPC status name, message. |

## Alphabetical Type Index

| Type | Module |
| ---- | ------ |
| `PubSubError` | GCP Message Bus |
| `TomGcpTokenSource` | GCP Message Bus |
| `TomPubSubMessageBus` | GCP Message Bus |

The contract's own types — `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`,
`TomBusCodec`, `TomBusException` and the rest — are in
[`tom_core_message_bus`'s API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

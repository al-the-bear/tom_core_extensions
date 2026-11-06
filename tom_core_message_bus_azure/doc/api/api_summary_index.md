# Tom Core Message Bus Azure API Reference: Index

API summaries for `tom_core_message_bus_azure` — the Azure adapter of the Tom
message bus. The barrel (`lib/tom_core_message_bus_azure.dart`) exports the bus
and the AMQP client it speaks with, documented in one summary.

Each summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors / static & instance members). Only public
members are listed; `_`-prefixed declarations are omitted.

## Quick Navigation

| Module | Summary | What it provides |
| ------ | ------- | ---------------- |
| Azure Message Bus | [api_summary_azure_message_bus.md](api_summary_azure_message_bus.md) | `TomServiceBusMessageBus` and `TomServiceBusSasKey`; the AMQP 1.0 client: `AmqpConnection`, its links and deliveries, `AmqpMessage`, the outcomes and the type codec. |

## Modules

### Azure Message Bus (`lib/src/service_bus.dart`, `lib/src/amqp/`)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `TomServiceBusMessageBus` | class | A `TomMessageBus` over Azure Service Bus through AMQP 1.0: a topic per topic, a subscription per group. |
| `TomServiceBusSasKey` | class | A shared access key: SASL `PLAIN` credentials, and the shared access signatures of the management API. |
| `AmqpConnection` | class | An AMQP 1.0 connection with one session. |
| `AmqpSasl` | sealed class | How a connection authenticates: `PLAIN` or `ANONYMOUS`. |
| `AmqpLink` / `AmqpSender` / `AmqpReceiver` | sealed class / final classes | A link attached on a connection; a sending and a receiving link. |
| `AmqpDelivery` | class | One message a receiver was given, settled once with an outcome. |
| `AmqpMessage` | class | An AMQP message: its sections and body. |
| `AmqpOutcome` / `AmqpAccepted` / `AmqpReleased` / `AmqpModified` / `AmqpRejected` | sealed class / final classes | How a receiver settles a delivery. |
| `AmqpException` | class | A failure of a connection, session or link. |
| `AmqpPerformative` / `AmqpCodes` | abstract final classes | The descriptor codes of the frames, message sections and delivery states. |
| `AmqpWriter` / `AmqpReader` | classes | The type codec. |
| `AmqpSymbol`, `AmqpUuid`, `AmqpArray`, `AmqpDescribed` | classes | The AMQP types without a Dart counterpart. |
| `AmqpUnsigned` / `AmqpUbyte` / `AmqpUshort` / `AmqpUint` / `AmqpUlong` | sealed class / final classes | The unsigned integers. |
| `AmqpCodecException` | class | Bytes that are no AMQP encoding, or a value without one. |
| `amqpEncode` / `amqpDecode` | functions | A value encoded; the value bytes encode. |

## Alphabetical Type Index

| Type | Module |
| ---- | ------ |
| `AmqpAccepted` | Azure Message Bus |
| `AmqpArray` | Azure Message Bus |
| `AmqpCodecException` | Azure Message Bus |
| `AmqpCodes` | Azure Message Bus |
| `AmqpConnection` | Azure Message Bus |
| `AmqpDelivery` | Azure Message Bus |
| `AmqpDescribed` | Azure Message Bus |
| `AmqpException` | Azure Message Bus |
| `AmqpLink` | Azure Message Bus |
| `AmqpMessage` | Azure Message Bus |
| `AmqpModified` | Azure Message Bus |
| `AmqpOutcome` | Azure Message Bus |
| `AmqpPerformative` | Azure Message Bus |
| `AmqpReader` | Azure Message Bus |
| `AmqpReceiver` | Azure Message Bus |
| `AmqpRejected` | Azure Message Bus |
| `AmqpReleased` | Azure Message Bus |
| `AmqpSasl` | Azure Message Bus |
| `AmqpSender` | Azure Message Bus |
| `AmqpSymbol` | Azure Message Bus |
| `AmqpUbyte` | Azure Message Bus |
| `AmqpUint` | Azure Message Bus |
| `AmqpUlong` | Azure Message Bus |
| `AmqpUnsigned` | Azure Message Bus |
| `AmqpUshort` | Azure Message Bus |
| `AmqpUuid` | Azure Message Bus |
| `AmqpWriter` | Azure Message Bus |
| `TomServiceBusMessageBus` | Azure Message Bus |
| `TomServiceBusSasKey` | Azure Message Bus |

The contract's own types — `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`,
`TomBusCodec`, `TomBusException` and the rest — are in
[`tom_core_message_bus`'s API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

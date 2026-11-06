# Tom Core Message Bus AWS API Reference: Index

API summaries for `tom_core_message_bus_aws` — the AWS adapter of the Tom
message bus. The barrel (`lib/tom_core_message_bus_aws.dart`) exports one
module, documented here.

Each summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors / static & instance members). Only public
members are listed; `_`-prefixed declarations are omitted.

## Quick Navigation

| Module | Summary | What it provides |
| ------ | ------- | ---------------- |
| AWS Message Bus | [api_summary_aws_message_bus.md](api_summary_aws_message_bus.md) | `TomAwsMessageBus`: the `TomMessageBus` contract over SNS and SQS, the names it gives topics and queues, the queue policy, the message envelope and the two signed calls. |

## Modules

### AWS Message Bus (`lib/src/aws_bus.dart`)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `TomAwsMessageBus` | class | A `TomMessageBus` over Amazon SNS and SQS through their HTTP APIs, signed with Signature Version 4: an SNS topic per topic, an SQS queue per group. |

## Alphabetical Type Index

| Type | Module |
| ---- | ------ |
| `TomAwsMessageBus` | AWS Message Bus |

The contract's own types — `TomMessageBus`, `TomBusMessage`, `TomBusDelivery`,
`TomBusCodec`, `TomBusException` and the rest — are in
[`tom_core_message_bus`'s API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md);
`TomAwsCredentials`, `TomAwsCredentialsSource` and `TomAwsV4Signer` in
[`tom_core_server`'s file storage API summary](../../../../core/tom_core_server/doc/api/api_summary_file_storage.md).

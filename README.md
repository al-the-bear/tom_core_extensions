# Tom Core Extensions

Non-essential services for Tom applications. `tom_core` holds what makes an
application a Tom application — the services every enterprise application
needs, provided in one consistent way. The packages here are services an
application may use or leave out, and each of them builds on `tom_core`.

## What belongs here

| Repository | Holds | Depends on |
| --- | --- | --- |
| `tom_basics` (`tom_ai/basics`) | Generic libraries usable in any Dart application, and the base libraries for a class of tools | other basics packages only |
| `tom_core` (`tom_ai/core`) | The essential services of a Tom application | basics |
| **`tom_core_extensions`** (`tom_ai/core_extension`) | **Optional services built on the core** | basics, core |
| `tom_modules` (`tom_ai/modules`) | Application-level libraries for Tom-internal reuse: models, model utilities, reusable UI components | basics, core, core extensions, other modules |

A package belongs here when an application can do without it and it needs
`tom_core` to work. A package that needs nothing from the workspace beyond
`tom_basics` belongs in `tom_basics`; a model or a UI component for Tom
applications belongs in `tom_modules`.

## Packages

| Package | What it is | Builds on |
| --- | --- | --- |
| [`tom_core_agentic`](tom_core_agentic/README.md) | Building blocks for agentic systems — placeholder resolution, path-scoped sandboxing, content-hash conventions, config read and write, the editor-facing agent data models — with two further libraries: `agent_sdk.dart`, Anthropic's Claude Agent SDK as a `tom_llm` provider (hosted or standalone transport, a session per isolate, an availability gate, the server install), and `agent_tools.dart`, the tool surface an LLM agent works through (registry, scope, consent, audit trail, in-process MCP server, preview-then-apply runs) | `tom_basics`, `tom_llm` |
| [`tom_core_sync`](tom_core_sync/README.md) | The keyed three-way merge, conflict records, history stores, and the sync engine and scheduler that pull, merge and commit through `tom_core_storage`'s compare-and-swap port | `tom_core_storage` |
| [`tom_core_secrets`](tom_core_secrets/README.md) | Cloud secret stores as secrets providers for Tom servers, one library each: AWS Secrets Manager (`aws.dart`), Azure Key Vault (`azure.dart`), HashiCorp Vault (`vault.dart`) | `tom_core_server` |
| [`tom_core_message_bus_nats`](tom_core_message_bus_nats/README.md) | The NATS JetStream adapter of the Tom message bus: `TomNatsMessageBus`, the `TomMessageBus` contract over a NATS server with JetStream — a stream per topic, a durable pull consumer per consumer group, dead letters to `<topic>.dlq`, the message id as `Nats-Msg-Id` for the server's duplicate detection — passing the bus's conformance suite | `tom_core_message_bus` |
| [`tom_core_message_bus_rabbitmq`](tom_core_message_bus_rabbitmq/README.md) | The RabbitMQ adapter of the Tom message bus: `TomRabbitMqMessageBus`, the `TomMessageBus` contract over a RabbitMQ broker — a durable fanout exchange per topic, a durable queue per consumer group, every publish confirmed by the broker, redeliveries and dead letters as confirmed publishes — on a fork of `dart_amqp` carrying the publisher-confirm fix; passing the bus's conformance suite | `tom_core_message_bus` |
| [`tom_core_message_bus_kafka`](tom_core_message_bus_kafka/README.md) | The Kafka adapter of the Tom message bus: `TomKafkaMessageBus`, the `TomMessageBus` contract over a Kafka cluster through Confluent REST Proxy — a Kafka topic per topic, a consumer group per group, acknowledgement as an offset commit, redelivery in place and ordering per key; passing the bus's conformance suite, the ordering test included | `tom_core_message_bus` |
| [`tom_core_openapi`](tom_core_openapi/README.md) | OpenAPI 3.1 for Tom servers: a server's document generated at build time from its endpoint annotations and reflected DTOs, validated against the OpenAPI meta-schema, and a typed Dart client that depends on `package:http` only; the `openapi` command-line tool | `tom_core_server` |

Each package keeps its user documentation in its own `doc/` folder. The
documentation gates of `tom_core` (`tom_ai/core/tool/check_gates.py`) read this
repository as well, so its packages are held to the same rules as the core's.

## License

BSD 3-Clause. See [LICENSE](LICENSE). A package that has to be released under
another licence — one that links GPL code, for example — lives in a repository
of its own.

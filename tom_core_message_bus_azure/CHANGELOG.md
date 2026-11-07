# Changelog

## 0.1.0

The first release: the Azure adapter of the Tom message bus, in
`tom_core_extensions`.

- **`TomServiceBusMessageBus`**: a `TomMessageBus` over Azure Service Bus.
  Messages travel over AMQP 1.0; topics and subscriptions are created through
  the management API (`api-version=2021-05`). A constructor over a `host` and a
  `TomServiceBusSasKey` (`amqpPort` 5671 over TLS, `managementEndpoint`
  `https://<host>/`, `namePrefix` `tombus`, `lockDuration` 30 seconds,
  `maxDeliveryCount` 10, `ephemeralIdle` 5 minutes, `retryDelay` 1 second,
  `httpClient`, `clock`) and `fromConnectionString`, which addresses the
  emulator for a string with `UseDevelopmentEmulator=true`.
- **The mapping onto Service Bus**: a topic per topic,
  `<namePrefix>-<topic>-<hash>`; a subscription per group, `<group>-<hash>`
  (at most 50 characters); an ephemeral group as a subscription of the bus's
  own under a fresh name, deleted when its last consumer cancels and by
  Service Bus after `ephemeralIdle`; a receiver link per consumer, granted one
  message at a time.
- **Settling**: acknowledge is `accepted` (complete); a redelivery is
  `modified` with `delivery-failed` (abandon); the attempt is the header's
  `delivery-count` plus one; a dead letter is published to `<topic>.dlq`'s
  topic, then the original completed.
- **The message**: one JSON envelope in a `data` section,
  `{id, key, publishedAt, headers, payload}` (`envelopeOf`, `messageOf`), with
  `message-id`, `content-type` and `creation-time` set.
- **Authentication**: `TomServiceBusCredential` — `TomServiceBusSasKey`
  (SASL `PLAIN`, or with `claimsBased` a shared access signature put per entity
  through claims-based security; `signature` for the management API) and
  `TomServiceBusTokenCredential` (a Microsoft Entra ID token from the
  application's function, put per entity through claims-based security and
  renewed at three quarters of its `lifetime`; a bearer token on the
  management API). `fromConnectionString` takes `claimsBased`.
- **The AMQP 1.0 client** (`AmqpConnection`): the type codec (`AmqpWriter`,
  `AmqpReader`, `amqpEncode`, `amqpDecode` and the AMQP types), the message
  format (`AmqpMessage`, the outcomes), framing, SASL `PLAIN` and `ANONYMOUS`,
  one session per connection, the claims-based security exchange
  (`putToken` on `$cbs`), sending and receiving links
  (`AmqpSender.send`, `AmqpReceiver.grant` and `deliveries`,
  `AmqpDelivery.settle`), heartbeats, and the links kept by the peer's
  handle as well as their own.
- **Capabilities**: none; ordering per key would need sessions.
- **Error keys**: `message_bus.azure.connection_string_invalid`,
  `message_bus.azure.management_failed`, `message_bus.azure.publish_failed`,
  `message_bus.azure.consumer_failed`.
- **Tests**: the offline suites ZB-U1 to ZB-U10, ZB-U14 to ZB-U18 (codec,
  message format, signature, names, management API, the error keys raised
  without a broker) and ZB-U11 to ZB-U13 (the
  connection and the claims-based exchange against a scripted AMQP peer); the
  bus's conformance suite MB-C1 to MB-C20 in both authentication modes, the
  relay test ZB-I1 and the example against the Service Bus emulator, tagged
  `azure` and run by `tool/run_azure_tests.sh` (40 passed, 2 skipped: MB-C18
  in each mode).
- **Example**: `example/azure_message_bus_example.dart`.

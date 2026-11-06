# Changelog

## 0.1.0

The first release: the NATS JetStream adapter of the Tom message bus, in
`tom_core_extensions`.

- **`TomNatsMessageBus`**: a `TomMessageBus` over a NATS server with
  JetStream, built on `dart_nats` ^1.7.0. A constructor over a connected
  `Client` (`subjectPrefix` `tombus`, `retention` 7 days, `fetchWait` 500 ms,
  `ownsClient`, `clock`) and `connect(uri, ...)`, which owns the connection it
  opens.
- **The mapping onto JetStream**: a stream per topic, `TOMBUS_<topic>_<hash>`,
  holding the subject `<subjectPrefix>.<topic>` with `retention` as its
  maximum age; a durable pull consumer per consumer group, deliver policy
  `new`, explicit acknowledgement; an ephemeral group as an unnamed pull
  consumer with `inactive_threshold` `ephemeralInactivity` (30 seconds),
  shared by the group's subscribers in one bus and deleted when the last of
  them cancels; `+ACK` to acknowledge, `-NAK` to redeliver,
  a publish to `<topic>.dlq` followed by `+TERM` to dead-letter; the attempt
  read from the delivered count of the reply subject; the message id sent as
  `Nats-Msg-Id`, so the server drops a repeated publish within its duplicate
  window.
- **The delivery step**: each delivery goes through `tom_core_message_bus`'s
  `tomDispatch`, each dead letter is its `tomDeadLetter`.
- **Message fields in headers**: `Tom-Bus-Id`, `Tom-Bus-Key` and
  `Tom-Bus-Published-At` (`idHeader`, `keyHeader`, `publishedAtHeader`); the
  payload is the message's JSON.
- **Naming helpers**: `subjectOf`, `validSubject`, `streamOf`, `consumerOf`
  and `deliveredCount`.
- **Capabilities**: no ordering per key.
- **Error keys**: `message_bus.nats.unreachable`,
  `message_bus.nats.invalid_topic`, `message_bus.nats.stream_failed`,
  `message_bus.nats.publish_failed`, `message_bus.nats.consumer_failed`.
- **Tests**: the offline unit suite NB-U1 to NB-U4; the bus's conformance suite
  MB-C1 to MB-C20, the relay tests NB-I1 and NB-I2, the refusals NB-E1 to
  NB-E4, the invalidation test NB-V1 (the server's `TomBusInvalidationChannel`
  between two isolates) and the example against a NATS server, tagged `nats`
  and run by `tool/run_nats_tests.sh` (27 passed, MB-C18 skipped).
- **Example**: `example/nats_message_bus_example.dart`.

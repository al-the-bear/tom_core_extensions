# Changelog

## 0.1.0

The first release: the AWS adapter of the Tom message bus, in
`tom_core_extensions`.

- **`TomAwsMessageBus`**: a `TomMessageBus` over Amazon SNS and SQS, through
  their HTTP APIs — the SQS JSON protocol (`application/x-amz-json-1.0`) and
  the SNS query protocol — signed with Signature Version 4 by
  `tom_core_server`'s `TomAwsV4Signer`, with no AWS SDK. A constructor over a
  `region` and a `TomAwsCredentialsSource` (`sqsEndpoint` and `snsEndpoint`
  defaulting to the region's public endpoints, `namePrefix` `tombus`,
  `visibilityTimeout` 30 seconds, `fetchWait` 1 second, `httpClient`, `clock`)
  and `withKeys(region, accessKeyId, secretAccessKey, sessionToken, endpoint,
  namePrefix)` for static keys. The requests go through `tom_core_kernel`'s
  `TomResilientClient` unless a client is passed.
- **The mapping onto SNS and SQS**: a standard SNS topic per topic,
  `<namePrefix>-<topic>-<hash>`; a standard SQS queue per group,
  `<namePrefix>-<topic>-<group>-<hash>`, kept for 14 days at most, subscribed
  to the topic with raw message delivery, its queue policy letting only that
  topic send; an ephemeral group as a queue of the bus's own under a fresh name
  each time, unsubscribed and deleted when its last consumer cancels.
- **Consuming**: a loop per subscription long-polling the group's queue, one
  message at a time, `fetchWait` in whole seconds from 1 to 20.
- **Settling**: acknowledge is `DeleteMessage`; a redelivery is
  `ChangeMessageVisibility` to 0; the attempt is the message's
  `ApproximateReceiveCount`; a dead letter is published to `<topic>.dlq`'s SNS
  topic, then the message deleted. Each delivery goes through `tomDispatch`,
  each dead letter is `tomDeadLetter`.
- **The message**: one JSON envelope in the body,
  `{id, key, publishedAt, headers, payload}` (`envelopeOf`, `messageOf`),
  since SNS carries ten message attributes at most.
- **Capabilities**: none; standard queues neither order nor deduplicate.
- **Names and helpers**: `topicNameOf`, `queueNameOf`, `queuePolicy`,
  `xmlValue`; `sqs` and `sns`, the signed calls of the two APIs.
- **Error keys**: `message_bus.aws.topic_failed`,
  `message_bus.aws.publish_failed`, `message_bus.aws.consumer_failed`.
- **Tests**: the offline unit suite AB-U1 to AB-U9 against a mock client; the
  bus's conformance suite MB-C1 to MB-C20, the relay test AB-I1 and the example
  against LocalStack's SNS and SQS, tagged `aws` and run by
  `tool/run_aws_tests.sh` (21 passed, 1 skipped: MB-C18).
- **Example**: `example/aws_message_bus_example.dart`.

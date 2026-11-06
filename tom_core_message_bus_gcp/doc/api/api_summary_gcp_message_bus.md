# Tom Core Message Bus GCP API Reference: tom_core_message_bus_gcp

The Google Cloud Pub/Sub adapter of the Tom message bus: `TomPubSubMessageBus`,
`TomGcpTokenSource` and `PubSubError`. One library,
`package:tom_core_message_bus_gcp/tom_core_message_bus_gcp.dart`.

For authentication, the REST API, the mapping onto Pub/Sub, settling, ordering
per key and the error keys, see [gcp_message_bus.md](../gcp_message_bus.md); for
the contract's types (`TomMessageBus`, `TomBusSubscription`, `TomBusCodec`,
`TomBusException`), `tom_core_message_bus`'s
[API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [TomPubSubMessageBus](#tompubsubmessagebus)
  - [PubSubError](#pubsuberror)
- [Typedefs](#typedefs)

## Overview

Source: `lib/src/pubsub_bus.dart`.

| File | Declares |
| ---- | -------- |
| `pubsub_bus.dart` | `TomGcpTokenSource`, `TomPubSubMessageBus`, `PubSubError` |

The bus is constructed over a project and a token source, or from a
service-account key file through `serviceAccount`, and is used through the
`TomMessageBus` contract.

## Class Hierarchy

```text
TomMessageBus  (tom_core_message_bus)
    └── TomPubSubMessageBus  (implements)

Exception  (dart:core)
    └── PubSubError  (implements)
```

## Classes

### TomPubSubMessageBus

A `TomMessageBus` over Google Cloud Pub/Sub, through its REST API — no Google
SDK: a topic per topic, a subscription per group with message ordering enabled,
ordering per key.

- **Implements:** `TomMessageBus` (from `tom_core_message_bus`)

#### Constructors

```dart
TomPubSubMessageBus({
  required this.projectId,
  this.token,
  Uri? endpoint,
  this.namePrefix = 'tombus',
  this.ackDeadline = const Duration(seconds: 60),
  this.fetchWait = const Duration(milliseconds: 500),
  this.redeliveryDelay = const Duration(milliseconds: 100),
  http.Client? httpClient,
  DateTime Function()? clock,
})
```

A bus in the project `projectId`. `token` supplies the access token of every
request; `null` sends none, which only an emulator accepts. `endpoint` defaults
to `https://pubsub.googleapis.com/`. `httpClient` sends the requests; a
`TomResilientClient` by default, which `close` closes. `clock` gives a
message's publication time; `DateTime.now` by default.

#### Factory Constructors

```dart
factory TomPubSubMessageBus.serviceAccount(
  String keyJson, {
  String? projectId,
  Uri? endpoint,
  String namePrefix = 'tombus',
})
```

| Factory | Description |
| ------- | ----------- |
| `serviceAccount` | A bus authenticated with the service-account key file `keyJson` (the JSON Google issues), its token from `serviceAccountCredential(keyJson)`. The project is `projectId`, else the key's `project_id`. Throws `message_bus.pubsub.no_project` when neither names one; a key file without `client_email` or `private_key` is refused by the credential with `messaging.push.bad_service_account`. The other settings take their defaults. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `serviceAccountCredential` | `static TomFcmServiceAccountCredential serviceAccountCredential(String keyJson)` | `tom_core_server`'s Google service-account credential for the key file `keyJson`, asking for `pubsubScope`: the OAuth JWT-bearer grant, its token cached until five minutes before it expires. |
| `metadataServer` | `static TomGcpTokenSource metadataServer({http.Client? httpClient, DateTime Function()? clock})` | A token source asking the metadata server of the Compute Engine, GKE or Cloud Run host for the default service account's token, cached until a minute before the `expires_in` it states (300 seconds when none). Its call throws `message_bus.pubsub.no_token` for an answer other than 200. |
| `topicIdOf` | `static String topicIdOf(String prefix, String topic)` | The topic id of `topic` under `prefix`: `<prefix>-<topic>-<hash>`, the topic's characters other than letters, digits, `_`, `-`, `.` and `~` replaced by `_` and cut to 160, the hash an eight-digit FNV-1a of the topic as given. It starts with a letter when the prefix does, as Pub/Sub requires. |
| `subscriptionIdOf` | `static String subscriptionIdOf(String prefix, String topic, String group, {String? suffix})` | The subscription id of `group` on `topic` under `prefix`: `<prefix>-<topic>-<group>-<hash>[-<suffix>]`, topic and group replaced the same way and cut to 100 each, the hash over the pair. `suffix` names an ephemeral group's own subscription. |
| `envelopeOf` | `static Map<String, Object?> envelopeOf(TomBusMessage message)` | The envelope a message's data carries: `{id, key (left out when null), publishedAt (ISO 8601 in UTC), headers, payload}`. |
| `messageOf` | `static TomBusMessage? messageOf(String topic, String? data)` | The message the base64 `data` of a message on `topic` carries; `null` when it is not base64 JSON or no envelope of this bus (not a map with a string `id`). |

#### Static Constants

| Constant | Type | Value | Description |
| -------- | ---- | ----- | ----------- |
| `pubsubScope` | `String` | `https://www.googleapis.com/auth/pubsub` | The scope Pub/Sub's REST API requires. |

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `projectId` | `String` | The project the topics and subscriptions live in. |
| `token` | `TomGcpTokenSource?` | Where the access token comes from; `null` for an emulator. |
| `endpoint` | `Uri` | The Pub/Sub endpoint. |
| `namePrefix` | `String` | The first part of every topic and subscription id. |
| `ackDeadline` | `Duration` | How long a pulled message stays with its consumer. |
| `fetchWait` | `Duration` | The pause before an empty pull is repeated; the longest a `cancel` waits. |
| `redeliveryDelay` | `Duration` | The pause between two attempts of a delivery. |
| `capabilities` | `TomBusCapabilities` | `const TomBusCapabilities(orderedPerKey: true)`. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `topicName` | `String topicName(String topic)` | The resource name of the topic `topic`: `projects/<projectId>/topics/<id>`. |
| `publish` | `Future<String> publish<T>(String topic, T payload, {String? key, Map<String, String> headers = const {}, String? id, TomBusCodec<T>? codec})` | Encodes `payload`, creates the topic if needed and publishes the envelope inside `TomBusTrace.publishing`, `key` as its `orderingKey`. Answers the message id (`id`, or a new one). Throws `message_bus.closed`, `message_bus.pubsub.topic_failed`, `message_bus.pubsub.publish_failed`, `message_bus.payload.not_json`. |
| `subscribe` | `Future<TomBusSubscription> subscribe<T>(String topic, {required String group, required TomBusHandler<T> handler, TomBusCodec<T>? codec, int maxDeliveries = 5, bool ephemeral = false})` | Checks the arguments, creates the topic if needed, creates the group's subscription with message ordering enabled (once per bus for a durable group, one of its own for an ephemeral one) and starts a pulling loop. Throws `message_bus.closed`, `message_bus.subscribe.invalid`, `message_bus.pubsub.topic_failed`, `message_bus.pubsub.consumer_failed`. |
| `call` | `Future<Map<String, Object?>> call(String method, String resource, [Map<String, Object?>? body])` | Calls Pub/Sub: `method` on `v1/<resource>` with the token and the JSON `body`, answering the decoded result. Throws a `PubSubError` for an answer with a status of 300 or more. |
| `close` | `Future<void> close()` | Refuses further calls, cancels every consumer (an ephemeral group's last one deleting its subscription) and closes the HTTP client when the bus made it. A second call answers the same future. |

### PubSubError

An error answer of Pub/Sub.

- **Implements:** `Exception`

#### Constructors

```dart
PubSubError(this.status, this.code, this.message)
```

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `status` | `int` | The HTTP status. |
| `code` | `String` | The gRPC status name, e.g. `NOT_FOUND`; empty when the answer carries none. |
| `message` | `String` | Pub/Sub's explanation; the answer's body when it is no error object. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `toString` | `String toString()` | `Pub/Sub: HTTP <status> <code> <message>`. |

## Typedefs

```dart
typedef TomGcpTokenSource = Future<String> Function();
```

| Name | Signature | Description |
| ---- | --------- | ----------- |
| `TomGcpTokenSource` | `typedef TomGcpTokenSource = Future<String> Function()` | Supplies the OAuth access token a Pub/Sub request carries. Called for every request; a source caches its token and mints a fresh one before it expires. |

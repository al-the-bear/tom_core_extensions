# Tom Core Message Bus Azure API Reference: tom_core_message_bus_azure

The Azure adapter of the Tom message bus, `TomServiceBusMessageBus`, and the
AMQP 1.0 client it speaks with. One library,
`package:tom_core_message_bus_azure/tom_core_message_bus_azure.dart`.

For the mapping onto Service Bus, settling, the limits and the error keys, see
[azure_message_bus.md](../azure_message_bus.md); for the contract's types
(`TomMessageBus`, `TomBusSubscription`, `TomBusCodec`, `TomBusException`),
`tom_core_message_bus`'s
[API summary](../../../../core/tom_core_message_bus/doc/api/api_summary_message_bus.md).

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [The Bus](#the-bus)
  - [TomServiceBusMessageBus](#tomservicebusmessagebus)
  - [TomServiceBusSasKey](#tomservicebussaskey)
  - [TomServiceBusTokenCredential](#tomservicebustokencredential)
- [The AMQP Client](#the-amqp-client)
  - [AmqpConnection](#amqpconnection)
  - [AmqpSasl](#amqpsasl)
  - [AmqpLink, AmqpSender, AmqpReceiver](#amqplink-amqpsender-amqpreceiver)
  - [AmqpDelivery](#amqpdelivery)
  - [AmqpMessage](#amqpmessage)
  - [The outcomes](#the-outcomes)
  - [AmqpException](#amqpexception)
  - [Codes](#codes)
- [The Type Codec](#the-type-codec)

## Overview

Source: `lib/src/service_bus.dart`, `lib/src/amqp/amqp_connection.dart`,
`lib/src/amqp/amqp_message.dart`, `lib/src/amqp/amqp_types.dart`.

| File | Declares |
| ---- | -------- |
| `service_bus.dart` | `TomServiceBusCredential`, `TomServiceBusSasKey`, `TomServiceBusTokenCredential`, `TomServiceBusMessageBus` |
| `amqp/amqp_connection.dart` | `AmqpConnection`, `AmqpSasl`, `AmqpLink`, `AmqpSender`, `AmqpReceiver`, `AmqpDelivery`, `AmqpException`, `AmqpPerformative` |
| `amqp/amqp_message.dart` | `AmqpMessage`, `AmqpOutcome`, `AmqpAccepted`, `AmqpReleased`, `AmqpModified`, `AmqpRejected`, `AmqpCodes` |
| `amqp/amqp_types.dart` | `AmqpWriter`, `AmqpReader`, `amqpEncode`, `amqpDecode`, `AmqpSymbol`, `AmqpUnsigned` and its four widths, `AmqpUuid`, `AmqpArray`, `AmqpDescribed`, `AmqpCodecException` |

## Class Hierarchy

```text
TomMessageBus  (tom_core_message_bus)
    └── TomServiceBusMessageBus  (implements)

TomServiceBusCredential  (sealed)
    ├── TomServiceBusSasKey
    └── TomServiceBusTokenCredential

AmqpLink  (sealed)
    ├── AmqpSender
    └── AmqpReceiver

AmqpOutcome  (sealed)
    ├── AmqpAccepted
    ├── AmqpReleased
    ├── AmqpModified
    └── AmqpRejected

AmqpUnsigned  (sealed)
    ├── AmqpUbyte
    ├── AmqpUshort
    ├── AmqpUint
    └── AmqpUlong

Exception
    ├── AmqpException
    └── AmqpCodecException
```

## The Bus

### TomServiceBusMessageBus

A `TomMessageBus` over Azure Service Bus: messages over AMQP 1.0, topics and
subscriptions through the management API.

#### Constructors

```dart
TomServiceBusMessageBus({
  required String host,
  required TomServiceBusCredential credential,
  int amqpPort = 5671,
  bool secure = true,
  Uri? managementEndpoint,
  String namePrefix = 'tombus',
  Duration lockDuration = const Duration(seconds: 30),
  int maxDeliveryCount = 10,
  Duration ephemeralIdle = const Duration(minutes: 5),
  Duration retryDelay = const Duration(seconds: 1),
  http.Client? httpClient,
  DateTime Function()? clock,
})

factory TomServiceBusMessageBus.fromConnectionString(
  String connectionString, {
  int? amqpPort,
  int? managementPort,
  String namePrefix = 'tombus',
  bool claimsBased = false,
})
```

`fromConnectionString` reads `Endpoint`, `SharedAccessKeyName` and
`SharedAccessKey` (refusing a string without them,
`message_bus.azure.connection_string_invalid`); with
`UseDevelopmentEmulator=true` it addresses the emulator — AMQP without TLS on
`amqpPort` (5672) and the management API over HTTP on `managementPort` (5300).

#### Properties

| Property | Type | Description |
| -------- | ---- | ----------- |
| `host` | `String` | The namespace's host name. |
| `credential` | `TomServiceBusCredential` | How the bus authenticates. |
| `amqpPort` | `int` | The AMQP port. |
| `secure` | `bool` | Whether AMQP runs over TLS. |
| `managementEndpoint` | `Uri` | The management API's base address. |
| `namePrefix` | `String` | The first part of every topic name. |
| `lockDuration` | `Duration` | How long a received message is locked to its consumer. |
| `maxDeliveryCount` | `int` | The subscriptions' own delivery limit. |
| `ephemeralIdle` | `Duration` | How long an abandoned ephemeral subscription is kept. |
| `retryDelay` | `Duration` | The wait before a failed consumer attaches again. |
| `capabilities` | `TomBusCapabilities` | None: no ordering per key. |

#### Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `publish` | `Future<String> publish<T>(String topic, T payload, {String? key, Map<String, String> headers = const {}, String? id, TomBusCodec<T>? codec})` | Sends the message to the topic (created on first use) and answers its id. |
| `subscribe` | `Future<TomBusSubscription> subscribe<T>(String topic, {required String group, required TomBusHandler<T> handler, TomBusCodec<T>? codec, int maxDeliveries = 5, bool ephemeral = false})` | Creates the group's subscription (or an ephemeral one) and attaches a consumer. |
| `close` | `Future<void> close()` | Cancels every consumer and closes the connection. |
| `management` | `Future<int> management(String method, String path, {String? body, Set<int> accept = const {}})` | A signed request to the management API; answers the status, throwing `message_bus.azure.management_failed` for one of 300 or above outside `accept`. |

#### Static Methods

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `topicNameOf` | `static String topicNameOf(String prefix, String topic)` | The topic name: prefix, sanitised topic, FNV-1a hash. |
| `subscriptionNameOf` | `static String subscriptionNameOf(String group, {String? suffix})` | The subscription name, at most 50 characters. |
| `isoDuration` | `static String isoDuration(Duration duration)` | The duration as `PT<seconds>S`. |
| `envelopeOf` | `static Map<String, Object?> envelopeOf(TomBusMessage message)` | The JSON envelope a message body carries. |
| `messageOf` | `static TomBusMessage? messageOf(String topic, List<int> body)` | The message a body carries, or `null` for one that is no envelope. |

### TomServiceBusSasKey

A shared access key of a namespace's policy (a `TomServiceBusCredential`).

```dart
const TomServiceBusSasKey(String keyName, String key, {bool claimsBased = false})
```

| Member | Signature | Description |
| ------ | --------- | ----------- |
| `keyName` | `String` | The policy's name. |
| `key` | `String` | The policy's key. |
| `claimsBased` | `bool` | Whether the AMQP connection is authorized through claims-based security (a signature put per entity on `$cbs`) instead of SASL `PLAIN`. |
| `signature` | `String signature(Uri resource, {Duration validFor = const Duration(hours: 1), DateTime? now})` | `SharedAccessSignature sr=...&sig=...&se=...&skn=...` for the resource. |

### TomServiceBusTokenCredential

A Microsoft Entra ID credential (a `TomServiceBusCredential`): tokens put per
entity on the connection's `$cbs` node (type `jwt`) and renewed at three
quarters of `lifetime`; a bearer token on the management API.

```dart
const TomServiceBusTokenCredential(
  Future<String> Function() token, {
  Duration lifetime = const Duration(hours: 1),
})
```

| Member | Type | Description |
| ------ | ---- | ----------- |
| `token` | `Future<String> Function()` | Answers a current access token for Service Bus (scope `https://servicebus.azure.net/.default`). |
| `lifetime` | `Duration` | How long one token is valid. |

## The AMQP Client

### AmqpConnection

An open AMQP 1.0 connection with one session.

| Member | Signature | Description |
| ------ | --------- | ----------- |
| `connect` | `static Future<AmqpConnection> connect(String host, int port, {required AmqpSasl sasl, bool secure = false, String? hostname, String? containerId, Duration timeout = const Duration(seconds: 30)})` | Opens the socket (TLS when `secure`), authenticates, exchanges `open` and begins the session. |
| `attachSender` | `Future<AmqpSender> attachSender(String address, {String? name, Map<AmqpSymbol, Object?>? properties})` | A link sending to `address`. |
| `attachReceiver` | `Future<AmqpReceiver> attachReceiver(String address, {String? name, String? target, Map<AmqpSymbol, Object?>? filter, Map<AmqpSymbol, Object?>? properties})` | A link receiving from `address`. |
| `putToken` | `Future<void> putToken({required String audience, required String token, required String type, DateTime? expiresAt})` | The claims-based security exchange: puts the token for `audience` on `$cbs` (`jwt`, or `servicebus.windows.net:sastoken`); throws an `AmqpException` unless the peer answers 200 or 202. |
| `close` | `Future<void> close()` | Ends the session and closes the connection. |
| `done` | `Future<void>` | Completes when the connection ended, with the failure that ended it as an error. |
| `isOpen` | `bool` | Whether the connection is open. |
| `containerId` | `String` | The container id announced. |
| `hostname` | `String` | The host name announced in `open`. |
| `frameLog` | `static void Function(String frame)?` | Told of every frame sent and received, when set. |

### AmqpSasl

```dart
const factory AmqpSasl.plain(String username, String password)
const factory AmqpSasl.anonymous()
```

### AmqpLink, AmqpSender, AmqpReceiver

| Member | Of | Signature | Description |
| ------ | -- | --------- | ----------- |
| `name` | `AmqpLink` | `String` | The link name. |
| `handle` | `AmqpLink` | `int` | This side's handle. |
| `address` | `AmqpLink` | `String` | The address at the peer. |
| `isReceiver` | `AmqpLink` | `bool` | Whether the link receives. |
| `detached` | `AmqpLink` | `Future<AmqpException>` | Completes with the error the link was detached with. |
| `isAttached` | `AmqpLink` | `bool` | Whether the link is attached. |
| `close` | `AmqpLink` | `Future<void> close()` | Detaches the link: its deliveries stop at once, and the peer's answer is awaited for at most ten seconds. |
| `send` | `AmqpSender` | `Future<Object?> send(AmqpMessage message)` | Sends unsettled, waiting for credit; completes with the peer's outcome, fails with an `AmqpException` on `rejected` or a detach. |
| `deliveries` | `AmqpReceiver` | `Stream<AmqpDelivery>` | The deliveries, in arrival order. |
| `grant` | `AmqpReceiver` | `void grant(int credit)` | Gives the sender more credit. |

### AmqpDelivery

| Member | Signature | Description |
| ------ | --------- | ----------- |
| `deliveryId` | `int` | The delivery id within the session. |
| `message` | `AmqpMessage` | The message. |
| `settle` | `void settle(AmqpOutcome outcome)` | Settles the delivery; a second call does nothing. |

### AmqpMessage

```dart
AmqpMessage({
  Uint8List? data,
  Object? value,
  Object? messageId,
  Object? correlationId,
  String? to,
  String? subject,
  String? replyTo,
  String? contentType,
  DateTime? creationTime,
  Map<String, Object?>? applicationProperties,
  Map<AmqpSymbol, Object?>? messageAnnotations,
  int deliveryCount = 0,
  bool durable = true,
})

factory AmqpMessage.decode(Uint8List bytes)
```

| Member | Signature | Description |
| ------ | --------- | ----------- |
| `encode` | `Uint8List encode()` | The message's sections, encoded one after another. |
| `data`, `value` | `Uint8List?`, `Object?` | The body: one `data` section, or an `amqp-value`. |
| `messageId`, `correlationId`, `to`, `subject`, `replyTo`, `contentType`, `creationTime` | — | The `properties` section. |
| `applicationProperties`, `messageAnnotations` | maps | Those sections. |
| `deliveryCount`, `durable` | `int`, `bool` | The `header` section. |

### The outcomes

| Type | Constructor | Encoded as |
| ---- | ----------- | ---------- |
| `AmqpAccepted` | `const AmqpAccepted()` | `accepted` — Service Bus: complete |
| `AmqpReleased` | `const AmqpReleased()` | `released` |
| `AmqpModified` | `const AmqpModified({bool deliveryFailed = true})` | `modified` — Service Bus: abandon |
| `AmqpRejected` | `const AmqpRejected({String? condition, String? description})` | `rejected` with an error |

Each has `AmqpDescribed get encoded`, the outcome as a disposition's `state`.

### AmqpException

```dart
const AmqpException(String condition, String description)
static AmqpException? of(Object? value)
```

`condition` is the AMQP error condition (`amqp:not-found`, ...), `description`
what went wrong; `of` reads an AMQP `error` value.

### Codes

`AmqpPerformative` holds the frames' descriptor codes (`open`, `begin`,
`attach`, `flow`, `transfer`, `disposition`, `detach`, `end`, `close`,
`saslMechanisms`, `saslInit`, `saslOutcome`, `source`, `target`); `AmqpCodes`
the message sections' (`header`, `deliveryAnnotations`, `messageAnnotations`,
`properties`, `applicationProperties`, `data`, `amqpSequence`, `amqpValue`,
`footer`), the delivery states' (`received`, `accepted`, `rejected`,
`released`, `modified`) and `error`.

## The Type Codec

| Member | Signature | Description |
| ------ | --------- | ----------- |
| `amqpEncode` | `Uint8List amqpEncode(Object? value)` | The value encoded. |
| `amqpDecode` | `Object? amqpDecode(Uint8List bytes)` | The value the bytes encode. |
| `AmqpWriter` | `write(Object? value)`, `takeBytes()`, `length` | Writes values into a growing buffer, in the compact encodings where they fit. |
| `AmqpReader` | `AmqpReader(Uint8List bytes, [int offset = 0])`, `read()`, `isAtEnd`, `offset` | Reads values in turn. |
| `AmqpSymbol` | `const AmqpSymbol(String name)` | A symbol. |
| `AmqpUbyte`, `AmqpUshort`, `AmqpUint`, `AmqpUlong` | `const AmqpUint(int value)`, ... | The unsigned integers; each `value`. |
| `AmqpUuid` | `AmqpUuid(List<int> bytes)` | A uuid of sixteen bytes. |
| `AmqpArray` | `const AmqpArray(String elementType, List<Object?> elements)` | An array written with one constructor (`symbol`, `string`, `uint`, `ulong`, `long`, `boolean`); it reads back as a `List`. |
| `AmqpDescribed` | `const AmqpDescribed(Object descriptor, Object? value)`, `code` | A described value; `code` is a numeric descriptor's value. |
| `AmqpCodecException` | `const AmqpCodecException(String message)` | Bytes that are no AMQP encoding, or a value without one. |

Dart `null`, `bool`, `int` (a `long`), `double`, `String`, `Uint8List`
(`binary`), `DateTime` (`timestamp`), `List` and `Map` encode as the matching
AMQP types.

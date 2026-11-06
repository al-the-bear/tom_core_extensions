/// The AMQP 1.0 message format (part 3): the sections a bare message is made of,
/// and the delivery states a transfer is settled with.
library;

import 'dart:typed_data';

import 'amqp_types.dart';

/// The descriptor codes of the message sections and delivery states.
abstract final class AmqpCodes {
  /// `header`.
  static const header = 0x70;

  /// `delivery-annotations`.
  static const deliveryAnnotations = 0x71;

  /// `message-annotations`.
  static const messageAnnotations = 0x72;

  /// `properties`.
  static const properties = 0x73;

  /// `application-properties`.
  static const applicationProperties = 0x74;

  /// `data`.
  static const data = 0x75;

  /// `amqp-sequence`.
  static const amqpSequence = 0x76;

  /// `amqp-value`.
  static const amqpValue = 0x77;

  /// `footer`.
  static const footer = 0x78;

  /// The `received` delivery state.
  static const received = 0x23;

  /// The `accepted` outcome.
  static const accepted = 0x24;

  /// The `rejected` outcome.
  static const rejected = 0x25;

  /// The `released` outcome.
  static const released = 0x26;

  /// The `modified` outcome.
  static const modified = 0x27;

  /// The `error` type.
  static const error = 0x1d;
}

/// An AMQP message: the sections a sender writes and a receiver reads.
///
/// Only what this package uses is modelled by name; every section arrives in
/// the map or list it was sent as.
class AmqpMessage {
  /// A message with [data] as its body — or [value] as an `amqp-value` body —
  /// and the given sections.
  AmqpMessage({
    this.data,
    this.value,
    this.messageId,
    this.correlationId,
    this.to,
    this.subject,
    this.replyTo,
    this.contentType,
    this.creationTime,
    Map<String, Object?>? applicationProperties,
    Map<AmqpSymbol, Object?>? messageAnnotations,
    this.deliveryCount = 0,
    this.durable = true,
  }) : applicationProperties = applicationProperties ?? {},
       messageAnnotations = messageAnnotations ?? {};

  /// The body as one `data` section, or `null`.
  final Uint8List? data;

  /// The body as an `amqp-value` section, when [data] is `null`.
  final Object? value;

  /// `properties.message-id`.
  final Object? messageId;

  /// `properties.correlation-id`.
  final Object? correlationId;

  /// `properties.to`.
  final String? to;

  /// `properties.subject`.
  final String? subject;

  /// `properties.reply-to`.
  final String? replyTo;

  /// `properties.content-type`.
  final String? contentType;

  /// `properties.creation-time`.
  final DateTime? creationTime;

  /// The `application-properties` section.
  final Map<String, Object?> applicationProperties;

  /// The `message-annotations` section.
  final Map<AmqpSymbol, Object?> messageAnnotations;

  /// `header.delivery-count`: how many earlier deliveries of the message
  /// failed.
  final int deliveryCount;

  /// `header.durable`.
  final bool durable;

  /// The message as the payload of a transfer: its sections, encoded one after
  /// another.
  Uint8List encode() {
    final writer = AmqpWriter();
    writer.write(
      AmqpDescribed(const AmqpUlong(AmqpCodes.header), [
        durable,
        null,
        null,
        null,
        AmqpUint(deliveryCount),
      ]),
    );
    if (messageAnnotations.isNotEmpty) {
      writer.write(
        AmqpDescribed(
          const AmqpUlong(AmqpCodes.messageAnnotations),
          messageAnnotations,
        ),
      );
    }
    final props = <Object?>[
      messageId,
      null,
      to,
      subject,
      replyTo,
      correlationId,
      contentType == null ? null : AmqpSymbol(contentType!),
      null,
      null,
      creationTime,
    ];
    while (props.isNotEmpty && props.last == null) {
      props.removeLast();
    }
    if (props.isNotEmpty) {
      writer.write(AmqpDescribed(const AmqpUlong(AmqpCodes.properties), props));
    }
    if (applicationProperties.isNotEmpty) {
      writer.write(
        AmqpDescribed(
          const AmqpUlong(AmqpCodes.applicationProperties),
          applicationProperties,
        ),
      );
    }
    if (data != null) {
      writer.write(AmqpDescribed(const AmqpUlong(AmqpCodes.data), data));
    } else {
      writer.write(AmqpDescribed(const AmqpUlong(AmqpCodes.amqpValue), value));
    }
    return writer.takeBytes();
  }

  /// The message a transfer's payload [bytes] carry.
  factory AmqpMessage.decode(Uint8List bytes) {
    final reader = AmqpReader(bytes);
    List<Object?> header = const [];
    List<Object?> props = const [];
    Map<String, Object?> application = {};
    Map<AmqpSymbol, Object?> annotations = {};
    final data = BytesBuilder(copy: false);
    var hasData = false;
    Object? value;
    while (!reader.isAtEnd) {
      final section = reader.read();
      if (section is! AmqpDescribed) {
        throw const AmqpCodecException('A message section is not described.');
      }
      final content = section.value;
      switch (section.code) {
        case AmqpCodes.header:
          header = content as List<Object?>;
        case AmqpCodes.messageAnnotations:
          annotations = {
            for (final e in (content as Map).entries)
              if (e.key is AmqpSymbol) e.key as AmqpSymbol: e.value,
          };
        case AmqpCodes.properties:
          props = content as List<Object?>;
        case AmqpCodes.applicationProperties:
          application = {
            for (final e in (content as Map).entries) '${e.key}': e.value,
          };
        case AmqpCodes.data:
          hasData = true;
          data.add(content as Uint8List);
        case AmqpCodes.amqpValue:
          value = content;
        default:
          break;
      }
    }
    Object? at(List<Object?> list, int i) => i < list.length ? list[i] : null;
    final count = at(header, 4);
    return AmqpMessage(
      data: hasData ? data.takeBytes() : null,
      value: value,
      messageId: at(props, 0),
      to: at(props, 2) as String?,
      subject: at(props, 3) as String?,
      replyTo: at(props, 4) as String?,
      correlationId: at(props, 5),
      contentType: (at(props, 6) as AmqpSymbol?)?.name,
      creationTime: at(props, 9) as DateTime?,
      applicationProperties: application,
      messageAnnotations: annotations,
      deliveryCount: count is AmqpUnsigned ? count.value : 0,
      durable: at(header, 0) == true,
    );
  }
}

/// How a receiver settles a delivery.
sealed class AmqpOutcome {
  const AmqpOutcome();

  /// The outcome as the `state` of a disposition.
  AmqpDescribed get encoded;
}

/// `accepted`: the message was processed (Service Bus: complete).
final class AmqpAccepted extends AmqpOutcome {
  /// The accepted outcome.
  const AmqpAccepted();

  @override
  AmqpDescribed get encoded =>
      const AmqpDescribed(AmqpUlong(AmqpCodes.accepted), <Object?>[]);
}

/// `released`: the message goes back to the source untouched.
final class AmqpReleased extends AmqpOutcome {
  /// The released outcome.
  const AmqpReleased();

  @override
  AmqpDescribed get encoded =>
      const AmqpDescribed(AmqpUlong(AmqpCodes.released), <Object?>[]);
}

/// `modified`: the message goes back to the source, counted as a failed
/// delivery when [deliveryFailed] (Service Bus: abandon).
final class AmqpModified extends AmqpOutcome {
  /// The modified outcome.
  const AmqpModified({this.deliveryFailed = true});

  /// Whether the delivery counts as failed.
  final bool deliveryFailed;

  @override
  AmqpDescribed get encoded =>
      AmqpDescribed(const AmqpUlong(AmqpCodes.modified), [deliveryFailed]);
}

/// `rejected`: the message cannot be processed (Service Bus: dead-letter).
final class AmqpRejected extends AmqpOutcome {
  /// The rejected outcome, with [condition] and [description].
  const AmqpRejected({this.condition, this.description});

  /// The error condition.
  final String? condition;

  /// What went wrong.
  final String? description;

  @override
  AmqpDescribed get encoded =>
      AmqpDescribed(const AmqpUlong(AmqpCodes.rejected), [
        if (condition != null)
          AmqpDescribed(const AmqpUlong(AmqpCodes.error), [
            AmqpSymbol(condition!),
            description,
          ]),
      ]);
}

/// The AMQP 1.0 type system (OASIS AMQP 1.0, part 1): how values are written
/// to and read from bytes.
///
/// Dart values map onto AMQP types as follows. Reading answers the same Dart
/// types, so a value read back compares equal to the value written — except an
/// array, which reads back as a `List` of its elements.
///
/// | Dart | AMQP |
/// | ---- | ---- |
/// | `null` | null |
/// | `bool` | boolean |
/// | `int` | long (written as `smalllong` when it fits a byte) |
/// | `double` | double |
/// | `String` | string (UTF-8) |
/// | `Uint8List` | binary |
/// | `DateTime` | timestamp (milliseconds since the epoch, UTC) |
/// | `List` | list |
/// | `Map` | map |
/// | [AmqpSymbol] | symbol |
/// | [AmqpUbyte], [AmqpUshort], [AmqpUint], [AmqpUlong] | the unsigned integers |
/// | [AmqpUuid] | uuid |
/// | [AmqpArray] | array (one element type) |
/// | [AmqpDescribed] | a described type: a descriptor and a value |
///
/// Unsigned values read back as their wrapper types, so the performatives'
/// fields keep their declared types on a round trip.
library;

import 'dart:convert';
import 'dart:typed_data';

/// An AMQP symbol: an ASCII name, distinct from a string on the wire.
class AmqpSymbol {
  /// The symbol [name].
  const AmqpSymbol(this.name);

  /// The name.
  final String name;

  @override
  bool operator ==(Object other) => other is AmqpSymbol && other.name == name;

  @override
  int get hashCode => name.hashCode ^ 0x5a5a;

  @override
  String toString() => ':$name';
}

/// An unsigned integer of the given AMQP width, carried as a Dart `int`.
sealed class AmqpUnsigned {
  const AmqpUnsigned(this.value);

  /// The value.
  final int value;

  @override
  bool operator ==(Object other) =>
      other is AmqpUnsigned &&
      other.runtimeType == runtimeType &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => '$value';
}

/// An AMQP `ubyte`.
final class AmqpUbyte extends AmqpUnsigned {
  /// The ubyte [value].
  const AmqpUbyte(super.value);
}

/// An AMQP `ushort`.
final class AmqpUshort extends AmqpUnsigned {
  /// The ushort [value].
  const AmqpUshort(super.value);
}

/// An AMQP `uint`.
final class AmqpUint extends AmqpUnsigned {
  /// The uint [value].
  const AmqpUint(super.value);
}

/// An AMQP `ulong`.
final class AmqpUlong extends AmqpUnsigned {
  /// The ulong [value].
  const AmqpUlong(super.value);
}

/// An AMQP `uuid`: sixteen bytes.
class AmqpUuid {
  /// The uuid of [bytes] (sixteen).
  AmqpUuid(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  /// The bytes.
  final Uint8List bytes;

  @override
  bool operator ==(Object other) =>
      other is AmqpUuid && _sameBytes(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() {
    final hex = [
      for (final b in bytes) b.toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// An AMQP array: [elements] all written with one constructor, the one
/// [elementType] names (`'symbol'`, `'string'`, `'uint'`, `'ulong'`, ...).
class AmqpArray {
  /// An array of [elements] of [elementType].
  const AmqpArray(this.elementType, this.elements);

  /// The type every element is written as.
  final String elementType;

  /// The elements.
  final List<Object?> elements;

  @override
  bool operator ==(Object other) =>
      other is AmqpArray &&
      other.elementType == elementType &&
      _sameList(other.elements, elements);

  @override
  int get hashCode => Object.hash(elementType, Object.hashAll(elements));

  @override
  String toString() => 'array<$elementType>$elements';
}

/// A described type: [descriptor] (a numeric [AmqpUlong] code or an
/// [AmqpSymbol] name) and the [value] it describes.
class AmqpDescribed {
  /// A value described by [descriptor].
  const AmqpDescribed(this.descriptor, this.value);

  /// The descriptor.
  final Object descriptor;

  /// The value.
  final Object? value;

  /// The numeric descriptor code, or `null` for a symbolic descriptor.
  int? get code =>
      descriptor is AmqpUlong ? (descriptor as AmqpUlong).value : null;

  @override
  bool operator ==(Object other) =>
      other is AmqpDescribed &&
      other.descriptor == descriptor &&
      _equal(other.value, value);

  @override
  int get hashCode => Object.hash(descriptor, value);

  @override
  String toString() => 'described($descriptor, $value)';
}

/// Raised for bytes that are not a valid AMQP encoding, or a value that has no
/// AMQP encoding.
class AmqpCodecException implements Exception {
  /// An exception saying [message].
  const AmqpCodecException(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => 'AmqpCodecException: $message';
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameList(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_equal(a[i], b[i])) return false;
  }
  return true;
}

bool _equal(Object? a, Object? b) {
  if (a is Uint8List && b is Uint8List) return _sameBytes(a, b);
  if (a is List && b is List) return _sameList(a, b);
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_equal(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

/// Writes AMQP values into a growing buffer.
class AmqpWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  /// The bytes written so far.
  Uint8List takeBytes() => _out.takeBytes();

  /// The number of bytes written so far.
  int get length => _out.length;

  void _byte(int value) => _out.addByte(value & 0xff);

  void _bytes(List<int> value) => _out.add(value);

  void _u16(int value) => _bytes([(value >> 8) & 0xff, value & 0xff]);

  void _u32(int value) => _bytes([
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);

  void _u64(int value) {
    final data = ByteData(8)..setInt64(0, value);
    _bytes(data.buffer.asUint8List());
  }

  /// Writes [value].
  void write(Object? value) {
    switch (value) {
      case null:
        _byte(0x40);
      case bool b:
        _byte(b ? 0x41 : 0x42);
      case AmqpUbyte(:final value):
        _byte(0x50);
        _byte(value);
      case AmqpUshort(:final value):
        _byte(0x60);
        _u16(value);
      case AmqpUint(:final value):
        if (value == 0) {
          _byte(0x43);
        } else if (value < 256) {
          _byte(0x52);
          _byte(value);
        } else {
          _byte(0x70);
          _u32(value);
        }
      case AmqpUlong(:final value):
        if (value == 0) {
          _byte(0x44);
        } else if (value > 0 && value < 256) {
          _byte(0x53);
          _byte(value);
        } else {
          _byte(0x80);
          _u64(value);
        }
      case int i:
        if (i >= -128 && i <= 127) {
          _byte(0x55);
          _byte(i);
        } else {
          _byte(0x81);
          _u64(i);
        }
      case double d:
        _byte(0x82);
        final data = ByteData(8)..setFloat64(0, d);
        _bytes(data.buffer.asUint8List());
      case DateTime t:
        _byte(0x83);
        _u64(t.toUtc().millisecondsSinceEpoch);
      case AmqpUuid u:
        _byte(0x98);
        _bytes(u.bytes);
      case Uint8List b:
        _variable(0xa0, 0xb0, b);
      case String s:
        _variable(0xa1, 0xb1, utf8.encode(s));
      case AmqpSymbol s:
        _variable(0xa3, 0xb3, ascii.encode(s.name));
      case AmqpDescribed d:
        _byte(0x00);
        write(d.descriptor);
        write(d.value);
      case AmqpArray a:
        _array(a);
      case List l:
        _list(l);
      case Map m:
        _map(m);
      default:
        throw AmqpCodecException(
          'A ${value.runtimeType} has no AMQP encoding.',
        );
    }
  }

  void _variable(int short, int long, List<int> bytes) {
    if (bytes.length < 256) {
      _byte(short);
      _byte(bytes.length);
    } else {
      _byte(long);
      _u32(bytes.length);
    }
    _bytes(bytes);
  }

  void _list(List<Object?> list) {
    if (list.isEmpty) {
      _byte(0x45);
      return;
    }
    final inner = AmqpWriter();
    for (final element in list) {
      inner.write(element);
    }
    final body = inner.takeBytes();
    if (body.length + 1 < 256 && list.length < 256) {
      _byte(0xc0);
      _byte(body.length + 1);
      _byte(list.length);
    } else {
      _byte(0xd0);
      _u32(body.length + 4);
      _u32(list.length);
    }
    _bytes(body);
  }

  void _map(Map<Object?, Object?> map) {
    final inner = AmqpWriter();
    for (final entry in map.entries) {
      inner.write(entry.key);
      inner.write(entry.value);
    }
    final body = inner.takeBytes();
    final count = map.length * 2;
    if (body.length + 1 < 256 && count < 256) {
      _byte(0xc1);
      _byte(body.length + 1);
      _byte(count);
    } else {
      _byte(0xd1);
      _u32(body.length + 4);
      _u32(count);
    }
    _bytes(body);
  }

  /// An array element's constructor, and how one element's bytes are written
  /// after it.
  static (int, void Function(AmqpWriter, Object?)) _arrayElement(String type) =>
      switch (type) {
        'symbol' => (
          0xb3,
          (w, v) {
            final bytes = ascii.encode((v! as AmqpSymbol).name);
            w._u32(bytes.length);
            w._bytes(bytes);
          },
        ),
        'string' => (
          0xb1,
          (w, v) {
            final bytes = utf8.encode(v! as String);
            w._u32(bytes.length);
            w._bytes(bytes);
          },
        ),
        'uint' => (0x70, (w, v) => w._u32((v! as AmqpUint).value)),
        'ulong' => (0x80, (w, v) => w._u64((v! as AmqpUlong).value)),
        'long' => (0x81, (w, v) => w._u64(v! as int)),
        'boolean' => (0x56, (w, v) => w._byte(v! as bool ? 1 : 0)),
        _ => throw AmqpCodecException('Arrays of $type are not written.'),
      };

  void _array(AmqpArray array) {
    final (constructor, element) = _arrayElement(array.elementType);
    final inner = AmqpWriter();
    inner._byte(constructor);
    for (final value in array.elements) {
      element(inner, value);
    }
    final body = inner.takeBytes();
    _byte(0xf0);
    _u32(body.length + 4);
    _u32(array.elements.length);
    _bytes(body);
  }
}

/// Reads AMQP values from [bytes], from [offset] on.
class AmqpReader {
  /// A reader of [bytes] at [offset].
  AmqpReader(this.bytes, [this.offset = 0])
    : _data = ByteData.sublistView(bytes);

  /// The bytes read.
  final Uint8List bytes;

  /// The position of the next value.
  int offset;

  final ByteData _data;

  /// Whether every byte has been read.
  bool get isAtEnd => offset >= bytes.length;

  void _need(int count) {
    if (offset + count > bytes.length) {
      throw AmqpCodecException(
        'The encoding ends at ${bytes.length} where $count more bytes were '
        'expected at $offset.',
      );
    }
  }

  int _u8() {
    _need(1);
    return bytes[offset++];
  }

  int _u16() {
    _need(2);
    final v = _data.getUint16(offset);
    offset += 2;
    return v;
  }

  int _u32() {
    _need(4);
    final v = _data.getUint32(offset);
    offset += 4;
    return v;
  }

  int _i64() {
    _need(8);
    final v = _data.getInt64(offset);
    offset += 8;
    return v;
  }

  Uint8List _take(int count) {
    _need(count);
    final v = Uint8List.fromList(bytes.sublist(offset, offset + count));
    offset += count;
    return v;
  }

  /// Reads the next value.
  Object? read() => _readWith(_u8());

  Object? _readWith(int constructor) {
    switch (constructor) {
      case 0x00:
        final descriptor = read();
        return AmqpDescribed(descriptor!, read());
      case 0x40:
        return null;
      case 0x41:
        return true;
      case 0x42:
        return false;
      case 0x56:
        return _u8() != 0;
      case 0x50:
        return AmqpUbyte(_u8());
      case 0x60:
        return AmqpUshort(_u16());
      case 0x70:
        return AmqpUint(_u32());
      case 0x52:
        return AmqpUint(_u8());
      case 0x43:
        return const AmqpUint(0);
      case 0x80:
        return AmqpUlong(_i64());
      case 0x53:
        return AmqpUlong(_u8());
      case 0x44:
        return const AmqpUlong(0);
      case 0x51:
        return _u8().toSigned(8);
      case 0x61:
        return _u16().toSigned(16);
      case 0x71:
        return _u32().toSigned(32);
      case 0x54:
        return _u8().toSigned(8);
      case 0x81:
        return _i64();
      case 0x55:
        return _u8().toSigned(8);
      case 0x72:
        _need(4);
        final f = _data.getFloat32(offset);
        offset += 4;
        return f;
      case 0x82:
        _need(8);
        final d = _data.getFloat64(offset);
        offset += 8;
        return d;
      case 0x73:
        return String.fromCharCode(_u32());
      case 0x74:
        return _take(4);
      case 0x84:
        return _take(8);
      case 0x94:
        return _take(16);
      case 0x83:
        return DateTime.fromMillisecondsSinceEpoch(_i64(), isUtc: true);
      case 0x98:
        return AmqpUuid(_take(16));
      case 0xa0:
        return _take(_u8());
      case 0xb0:
        return _take(_u32());
      case 0xa1:
        return utf8.decode(_take(_u8()));
      case 0xb1:
        return utf8.decode(_take(_u32()));
      case 0xa3:
        return AmqpSymbol(ascii.decode(_take(_u8())));
      case 0xb3:
        return AmqpSymbol(ascii.decode(_take(_u32())));
      case 0x45:
        return <Object?>[];
      case 0xc0:
        _u8();
        return _elements(_u8());
      case 0xd0:
        _u32();
        return _elements(_u32());
      case 0xc1:
        _u8();
        return _entries(_u8());
      case 0xd1:
        _u32();
        return _entries(_u32());
      case 0xe0:
        _u8();
        return _arrayOf(_u8());
      case 0xf0:
        _u32();
        return _arrayOf(_u32());
      default:
        throw AmqpCodecException(
          'Unknown constructor 0x${constructor.toRadixString(16)} at '
          '${offset - 1}.',
        );
    }
  }

  List<Object?> _elements(int count) => [
    for (var i = 0; i < count; i++) read(),
  ];

  Map<Object?, Object?> _entries(int count) {
    final map = <Object?, Object?>{};
    for (var i = 0; i < count ~/ 2; i++) {
      final key = read();
      map[key] = read();
    }
    return map;
  }

  List<Object?> _arrayOf(int count) {
    if (count == 0) {
      _u8();
      return <Object?>[];
    }
    var constructor = _u8();
    Object? descriptor;
    if (constructor == 0x00) {
      descriptor = read();
      constructor = _u8();
    }
    final values = [for (var i = 0; i < count; i++) _readWith(constructor)];
    return descriptor == null
        ? values
        : [for (final v in values) AmqpDescribed(descriptor, v)];
  }
}

/// [value] encoded.
Uint8List amqpEncode(Object? value) => (AmqpWriter()..write(value)).takeBytes();

/// The value [bytes] encode.
Object? amqpDecode(Uint8List bytes) => AmqpReader(bytes).read();

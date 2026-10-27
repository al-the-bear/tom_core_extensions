/// Builds the domain-specific exception a [MapFieldReader] throws when a
/// typed field read fails.
///
/// Every reader supplies its own factory so the thrown error *type* stays
/// domain-specific (e.g. `FormatException` at an untrusted-input boundary,
/// or a loader's own exception class) while the type-checking logic is
/// shared. The factory receives the fully-formed, engineer-readable
/// message and wraps it in the caller's error type.
typedef MapFieldErrorFactory = Object Function(String message);

/// Type-safe accessors over a plain `Map<Object?, Object?>` whose values
/// arrive from an untrusted boundary (decoded JSON, d4rt script input,
/// hand-edited config).
///
/// It is the plain-map sibling of [YamlConfigReader]: the same descriptive
/// "field X must be a Y (got Z)" discipline, but over the
/// `Map`/`List`/`String`/`num`/`bool` primitives a dynamic boundary
/// produces rather than `package:yaml` nodes. A bare `as` cast on such a
/// value throws an opaque `TypeError` framed far from the field that was
/// malformed; routing the read through this reader surfaces a located,
/// engineer-readable error instead.
///
/// Construction is cheap and typically inline at the call site:
///
/// ```dart
/// const reader = MapFieldReader(FormatException.new);
/// final version = reader.optionalNum(decl, 'version', 'proposeNodeType.version');
/// final schema = reader.optionalMap(decl, 'schema', 'proposeNodeType.schema');
/// ```
///
/// **Path argument.** Every accessor takes a `path` — the dotted location
/// of the value (e.g. `proposeNodeType.schema.title.type`). It appears
/// verbatim in error messages so a failure points straight at the
/// offending field.
final class MapFieldReader {
  /// Wraps a message in the caller's error type.
  final MapFieldErrorFactory errorFactory;

  const MapFieldReader(this.errorFactory);

  Never _fail(String message) => throw errorFactory(message);

  // ---------------------------------------------------------------
  // Keyed field accessors (read `map[key]`).
  // ---------------------------------------------------------------

  /// Returns the string at [key], or `null` when absent; throws when
  /// present but non-string.
  String? optionalString(Map<Object?, Object?> map, String key, String path) =>
      stringValue(map[key], path, allowNull: true);

  /// Returns the string at [key]; throws when missing or non-string.
  String requireString(Map<Object?, Object?> map, String key, String path) {
    if (!map.containsKey(key) || map[key] == null) {
      _fail('Missing required field: $path');
    }
    return stringValue(map[key], path)!;
  }

  /// Returns the number at [key], or `null` when absent; throws when
  /// present but non-numeric.
  num? optionalNum(Map<Object?, Object?> map, String key, String path) {
    final v = map[key];
    if (v == null) return null;
    if (v is! num) {
      _fail('$path must be a number (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the bool at [key], or `null` when absent; throws when
  /// present but non-bool.
  bool? optionalBool(Map<Object?, Object?> map, String key, String path) {
    final v = map[key];
    if (v == null) return null;
    if (v is! bool) {
      _fail('$path must be a boolean (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the map at [key], or `null` when absent; throws when present
  /// but non-map.
  Map<Object?, Object?>? optionalMap(
    Map<Object?, Object?> map,
    String key,
    String path,
  ) => mapValue(map[key], path, allowNull: true);

  /// Returns the list at [key], or `null` when absent; throws when present
  /// but non-list.
  List<Object?>? optionalList(
    Map<Object?, Object?> map,
    String key,
    String path,
  ) {
    final v = map[key];
    if (v == null) return null;
    if (v is! List) {
      _fail('$path must be a list (got ${v.runtimeType}).');
    }
    return v;
  }

  // ---------------------------------------------------------------
  // Value accessors (validate a value already in hand — list elements,
  // map entry keys/values).
  // ---------------------------------------------------------------

  /// Asserts [value] is a string. When [allowNull] is set a `null`
  /// returns `null`; otherwise `null` is a type mismatch.
  String? stringValue(Object? value, String path, {bool allowNull = false}) {
    if (value == null && allowNull) return null;
    if (value is! String) {
      _fail('$path must be a string (got ${value.runtimeType}).');
    }
    return value;
  }

  /// Asserts [value] is a map. When [allowNull] is set a `null` returns
  /// `null`; otherwise `null` is a type mismatch.
  Map<Object?, Object?>? mapValue(
    Object? value,
    String path, {
    bool allowNull = false,
  }) {
    if (value == null && allowNull) return null;
    if (value is! Map) {
      _fail('$path must be a map (got ${value.runtimeType}).');
    }
    return value;
  }
}

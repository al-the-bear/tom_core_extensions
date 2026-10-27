// JSON decode helpers with a single defensive discipline.
//
// Any store that persists a value map as a JSON column repeats the same
// decode: read the column, `jsonDecode` it, and assert it is a JSON
// object before treating it as a `Map<String, Object?>`. The recurring
// failure mode is a corrupt or hand-edited row that decodes to a
// non-object (a bare list, number, or string); the defensive style
// surfaces that as a context-tagged `StateError` rather than a raw
// `CastError` ten frames away from the column it came from.

import 'dart:convert';

/// Decodes [json] into a `Map<String, Object?>`, throwing a
/// [StateError] tagged with [context] when the payload is present but
/// is not a JSON object.
///
/// A `null` [json] returns the canonical empty map — the convention
/// stores use for "no attributes". A non-object payload (list, number,
/// string, bool) throws `'<context> is not a JSON object: <type>'` so
/// the operator can locate the offending column. The decoded entries
/// are copied into a fresh mutable map keyed by `String`.
Map<String, Object?> decodeJsonObject(String? json, {required String context}) {
  if (json == null) return const <String, Object?>{};
  final raw = jsonDecode(json);
  if (raw is! Map) {
    throw StateError('$context is not a JSON object: ${raw.runtimeType}');
  }
  return <String, Object?>{
    for (final entry in raw.entries) entry.key as String: entry.value,
  };
}

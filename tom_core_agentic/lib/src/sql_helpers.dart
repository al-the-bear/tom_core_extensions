// SQLite query-building helpers.
//
// Any SQLite-backed store repeats the same domain-free idioms: a
// `?,?,?` placeholder run for an `IN (…)` clause, a non-cryptographic
// hash to disambiguate a derived identifier, a "string → safe SQL
// identifier" sanitiser, and the cast that normalises a dynamically-typed
// BLOB column read into a `Uint8List`. Each was hand-rolled at every call
// site, and the placeholder separator even drifted (`','` vs `', '`).
// These are those idioms, with one definition each.

import 'dart:typed_data';

/// Builds a comma-separated run of `count` bind placeholders for an
/// `IN (…)` clause: `sqlPlaceholders(3)` ⇒ `'?,?,?'`.
///
/// [count] must be non-negative; `0` yields the empty string (the
/// caller is responsible for not emitting an empty `IN ()`). The
/// [separator] defaults to `','` — pass `', '` only when a human will
/// read the SQL, since the two are equivalent to SQLite.
String sqlPlaceholders(int count, {String separator = ','}) {
  if (count < 0) {
    throw ArgumentError.value(count, 'count', 'must be non-negative');
  }
  return List<String>.filled(count, '?').join(separator);
}

/// FNV-1a 32-bit hash of [s], computed over its UTF-16 code units.
///
/// FNV-1a is **not** cryptographic. Its only job here is to
/// disambiguate the readable prefix of a derived identifier (e.g. a
/// per-model vector table name) so two similar inputs do not collide on
/// the truncated, sanitised portion. The actual collision detector is
/// whatever `UNIQUE` constraint guards the derived name; a collision in
/// the astronomically-unlikely worst case surfaces there.
int fnv1a32(String s) {
  const int offset = 0x811c9dc5;
  const int prime = 0x01000193;
  var hash = offset;
  for (var i = 0; i < s.length; i++) {
    hash ^= s.codeUnitAt(i) & 0xff;
    hash = (hash * prime) & 0xffffffff;
  }
  return hash;
}

/// Lowercases [input] and replaces every character outside `[a-z0-9_]`
/// with `_`, capping the result at [maxLength] characters.
///
/// Produces the readable, SQL-safe prefix portion of a derived
/// identifier. It is deliberately lossy and **not** injective — pair it
/// with a hash suffix (see [fnv1a32]) when uniqueness matters.
String sqlSafeIdentifier(String input, {int maxLength = 32}) {
  if (maxLength < 0) {
    throw ArgumentError.value(maxLength, 'maxLength', 'must be non-negative');
  }
  final lower = input.toLowerCase();
  final out = StringBuffer();
  for (var i = 0; i < lower.length && out.length < maxLength; i++) {
    final ch = lower.codeUnitAt(i);
    final isAlnum =
        (ch >= 0x30 && ch <= 0x39) || // 0-9
        (ch >= 0x61 && ch <= 0x7a); // a-z
    final isUnderscore = ch == 0x5f; // _
    out.write(isAlnum || isUnderscore ? String.fromCharCode(ch) : '_');
  }
  return out.toString();
}

/// Normalises a dynamically-typed BLOB column read into a [Uint8List],
/// or returns `null` when [raw] is neither a `Uint8List` nor a
/// `List<int>`.
///
/// `sqlite3` returns a fresh `Uint8List` for BLOB columns under most
/// builds, but the dynamic typing of a result `Row` hands the caller
/// `Object?`. This collapses the recurring `is Uint8List` / `is
/// List<int>` cast. Use [blobFromColumn] when a non-blob is a hard
/// error; use this variant when the caller filters malformed rows out
/// of a bulk read.
Uint8List? blobFromColumnOrNull(Object? raw) {
  if (raw is Uint8List) return raw;
  if (raw is List<int>) return Uint8List.fromList(raw);
  return null;
}

/// Normalises a dynamically-typed BLOB column read into a [Uint8List],
/// throwing a [StateError] tagged with [context] when [raw] is not a
/// BLOB.
///
/// [context] names the column so a corrupt row points the operator at
/// the offending table.column (e.g. `'pending_vector_writes.payload_blob'`).
Uint8List blobFromColumn(Object? raw, {required String context}) {
  final blob = blobFromColumnOrNull(raw);
  if (blob == null) {
    throw StateError('$context: expected BLOB, got ${raw.runtimeType}');
  }
  return blob;
}

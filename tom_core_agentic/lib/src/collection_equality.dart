// Structural equality for maps, sets, and lists.
//
// Value types that carry a `Map`, `Set`, or `List` field repeat the
// same hand-rolled `==` body: compare lengths, then walk one side and
// check membership/value on the other. Each copy is a place the
// element-comparison can silently drift (`containsKey` vs `[]`,
// `identical` short-circuit present or not). This is that comparison,
// with one definition, so a node and an edge that both hold an attrs
// map share the exact same notion of "equal".

/// Structural equality of two maps by key set and per-key value.
///
/// Returns `true` when [a] and [b] have the same length, the same keys,
/// and `a[k] == b[k]` for every key. Short-circuits on `identical`.
/// Values are compared with `==`, so nested collections are compared by
/// reference unless they define their own structural equality.
bool mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Structural equality of two sets by membership.
///
/// Returns `true` when [a] and [b] have the same length and every
/// element of [a] is contained in [b]. Short-circuits on `identical`.
bool setEquals<E>(Set<E> a, Set<E> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final element in a) {
    if (!b.contains(element)) return false;
  }
  return true;
}

/// Structural equality of two lists by length and positional value.
///
/// Returns `true` when [a] and [b] have the same length and `a[i] == b[i]`
/// for every index. Short-circuits on `identical`.
bool listEquals<E>(List<E> a, List<E> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Deep equality for a value that may be a scalar or an arbitrarily nested
/// `List` of scalars/lists.
///
/// Two `null`s are equal; a `null` and a non-`null` are not. Two `List`s
/// compare element-wise (recursively, so nested lists are compared by their
/// contents rather than by reference). Every other value falls back to `==`.
/// Short-circuits on `identical`.
///
/// This is the comparison a typed attribute value needs when it holds either
/// a plain scalar or a list of scalars — where [listEquals] (which compares
/// elements with `==`) would compare nested lists by reference.
bool deepValueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Hash companion to [deepValueEquals].
///
/// `null` hashes to 0, a `List` hashes by its (ordered) elements **hashed
/// recursively** (so a nested list contributes its contents' hash, not its
/// identity), and every other value uses its own `hashCode`. Recursing mirrors
/// [deepValueEquals], keeping the equals/hash contract: values that compare
/// equal hash equal.
int deepValueHash(Object? v) {
  if (v == null) return 0;
  if (v is List) return Object.hashAll(v.map(deepValueHash));
  return v.hashCode;
}

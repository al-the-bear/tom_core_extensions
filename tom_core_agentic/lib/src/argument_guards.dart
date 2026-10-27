// Constructor argument-validation guards.
//
// Value objects and limiters across agentic systems re-write the same
// `if (x.isEmpty) throw ArgumentError.value(x, name, 'must be
// non-empty')` guard at every required-string boundary. Centralised here
// so the guard and its message text are written once.

/// Returns [value] unchanged when it is non-empty; otherwise throws an
/// [ArgumentError] naming [name]. Use in a constructor body or at an
/// untrusted boundary to reject an empty required string with a uniform
/// message.
///
/// This checks emptiness only (length 0). A field that must also reject
/// whitespace-only input (e.g. a free-text prompt) keeps its own
/// `value.trim().isEmpty` check — the semantics differ.
String requireNonEmpty(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-empty');
  }
  return value;
}

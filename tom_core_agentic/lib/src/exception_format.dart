// Canonical `toString` formatting for typed exception families.
//
// A sealed exception hierarchy almost always wants the same base
// `toString`: the concrete subtype name, an optional context fragment
// in parentheses, then the human-readable message. Repeating that
// format string across every family drifts (one uses `: `, another
// `-`, a third forgets the runtime type), so the shape lives here with
// exactly one definition.

/// Formats an exception's `toString` as `'<runtimeType>: <message>'`,
/// or `'<runtimeType>(<context>): <message>'` when [context] is given.
///
/// Pass `this` as [exception] so the concrete subtype name is used —
/// `runtimeType` resolves to the most-derived class even when the call
/// lives on a sealed base. [context] is a domain-specific fragment
/// (a type name, an endpoint pair, …); omit it for a bare type +
/// message line. An empty [context] is rendered literally as `()`,
/// matching the caller's intent to show an empty fragment rather than
/// suppressing it.
String formatException(Object exception, String message, {String? context}) {
  final type = exception.runtimeType;
  return context == null ? '$type: $message' : '$type($context): $message';
}

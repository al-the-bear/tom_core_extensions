// PlaceholderExpressions — the seam through which a [PlaceholderResolver]
// evaluates the `${{ … }}` expression form.
//
// The resolver core lives in `tom_core_agentic` so every config layer and
// the engine share it; but the `${{ … }}` form is a *d4rt* expression, and
// `tom_core_agentic` keeps no d4rt dependency. This interface is the
// inversion point: the brain engine supplies a d4rt-backed implementation
// (`D4rtExpressionContext` in `tom_brain_procedure`) for prompt assembly,
// while a config-layer resolver is built with **no** backing — so a stray
// `${{ … }}` in a config value fails fast rather than silently passing
// through.

/// Evaluates the `${{ … }}` placeholder form against a binding scope.
abstract interface class PlaceholderExpressions {
  /// Evaluates the expression [body] (the text between `${{` and `}}`)
  /// against [scope] — the flattened binding view the simple `${name}`
  /// form also reads — and returns the resulting value.
  ///
  /// Implementations should surface a parse/runtime failure as a
  /// [PlaceholderExpressionException] (imported from `placeholder_errors`).
  Future<Object?> evaluate(String body, Map<String, Object?> scope);
}

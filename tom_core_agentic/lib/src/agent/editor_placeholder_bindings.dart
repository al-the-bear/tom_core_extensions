// Editor-facing placeholder bindings (no JS).
//
// A thin, deliberately limited binder over the shared
// [PlaceholderResolver]. The TomSpecs editor reuses the brain's resolver for
// `${name}`, `${name?}` and `${env:NAME}`, plus a `{{name}}` mustache alias,
// but it runs in **sync + lenient** mode and **does not** wire the
// `${{ … }}` expression seam: encountering an expression form yields a clear
// "expressions unsupported" error rather than executing any code (the editor
// has no d4rt evaluator and must never run untrusted expressions).
//
// What it owns is the binding namespace and two rules: the mustache alias and
// the refusal of expressions. Everything else is a deliberate limit, not a
// gap:
//
// * **One capability level.** Every template gets the same forms; there is no
//   per-caller or per-template tiering of what may be resolved.
// * **No I/O.** The binder resolves only what it is handed — [bindings] and
//   the environment. It does not read files or locate a workspace folder, so
//   the reserved `${file:…}` / `${state:…}` forms pass through verbatim, as
//   they do in the resolver. A caller that wants a file's contents or a
//   workspace path in a template reads it and passes the value in as a
//   binding. That keeps resolution synchronous and side-effect free, which is
//   what a preview rendered on every keystroke needs.
library;

import '../placeholders/placeholder_resolver.dart';

/// Thrown when a template contains a `${{ … }}` expression form, which the
/// editor deliberately does not support.
final class PlaceholderExpressionsUnsupportedError extends Error {
  PlaceholderExpressionsUnsupportedError(this.expression);

  /// The offending expression body (trimmed), for diagnostics.
  final String expression;

  @override
  String toString() =>
      'PlaceholderExpressionsUnsupportedError: the \${{ … }} expression form '
      'is unsupported in the editor (found: "$expression")';
}

/// Resolves the editor's supported placeholder forms against a fixed set of
/// [bindings] (e.g. chat variables) and the process environment.
final class EditorPlaceholderBindings {
  /// Creates a binder over [bindings]; unknown `${name}` / `${env:NAME}`
  /// render as empty (lenient) by default, matching the editor's preview
  /// semantics. Pass [environment] to make `${env:NAME}` deterministic.
  EditorPlaceholderBindings({
    Map<String, String> bindings = const <String, String>{},
    this.strict = false,
    Map<String, String>? environment,
  }) : _bindings = Map<String, String>.unmodifiable(bindings),
       _environment = environment;

  final Map<String, String> _bindings;
  final Map<String, String>? _environment;

  /// When true, an unknown `${name}` / `${env:NAME}` throws instead of
  /// rendering empty. Defaults to false (lenient) for the editor.
  final bool strict;

  /// The bindings this binder resolves `${name}` / `{{name}}` against.
  Map<String, String> get bindings => _bindings;

  /// Expands the supported placeholder forms in [template].
  ///
  /// Translates the `{{name}}` alias to `${name}`, then resolves through the
  /// shared sync resolver. Throws [PlaceholderExpressionsUnsupportedError] if
  /// the template contains a `${{ … }}` expression form.
  String resolve(String template) {
    _rejectExpressions(template);
    final aliased = _expandMustacheAlias(template);

    final resolver = PlaceholderResolver(
      strict: strict,
      environment: _environment,
    );
    resolver.stack.bindAll(_bindings);
    return resolver.resolveSync(aliased);
  }

  /// Throws if [template] holds a `${{` expression opener. Done before the
  /// mustache alias pass so the inner `{{` of `${{ … }}` is never rewritten.
  void _rejectExpressions(String template) {
    final at = template.indexOf(r'${{');
    if (at < 0) return;
    final end = template.indexOf('}}', at + 3);
    final body = end < 0
        ? template.substring(at + 3)
        : template.substring(at + 3, end);
    throw PlaceholderExpressionsUnsupportedError(body.trim());
  }

  /// Rewrites every `{{ name }}` mustache token to `${name}` so the shared
  /// resolver's simple form handles it. Assumes `${{ … }}` has already been
  /// rejected, so no expression opener is touched.
  static String _expandMustacheAlias(String template) =>
      template.replaceAllMapped(_mustache, (m) => '\${${m.group(1)!.trim()}}');

  static final RegExp _mustache = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');
}

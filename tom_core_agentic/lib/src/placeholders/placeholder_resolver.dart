// PlaceholderResolver — expands the four placeholder forms in a scaffold.
//
// The single, shared placeholder engine for the whole brain stack. It lives
// in `tom_core_agentic` so the substrate / access / memory config loaders and
// the engine all resolve through one mechanism: a `${…}` must mean the same
// thing in a config file as in a prompt template, which it cannot if each
// layer carries its own expander.
//
// Forms:
//   ${name}      simple-identifier fast path — reads a binding from the
//                current scope. It is NOT interchangeable with
//                `${{ name }}`; see "Simple vs expression form" below.
//   ${name?}     OPTIONAL simple lookup:
//                an unbound name renders as the empty string regardless of
//                the resolver's strict/lenient mode — the injection slot
//                simply vanishes. A bound name renders its value exactly like
//                `${name}`. Optionality is a property of the call site (the
//                `?` in the template), not of the binding, and is scoped to
//                the simple form only — `${env:NAME?}` and `${{ … ?}}` do NOT
//                take the marker (the `?` is then just part of the name/body).
//   ${{ expr }}  an arbitrary expression evaluated through the injected
//                [PlaceholderExpressions] backing (d4rt in the engine).
//   ${env:NAME}  process-environment read — the one pure, non-expression
//                form, and the *only* way to reach the environment.
//   ${file:…}    reserved prefixes: recognised and never resolved. They
//   ${state:…}   pass through verbatim and are not re-scanned, so a template
//                author can write them without collision. The resolver does
//                no I/O; a caller that wants a file's contents or a state
//                value in a template supplies it as a binding.
//
// Simple vs expression form. The expression form does not subsume the
// simple one — `${{ name }}` is a *superset in expressive power only*, and
// the two diverge on three axes:
//   1. Backing. `${name}` always resolves; `${{ name }}` requires a
//      [PlaceholderExpressions] backing and throws without one. Config-layer
//      resolvers are deliberately built with none (see
//      `placeholder_expressions.dart`), so a stray `${{ … }}` in a config
//      value fails fast rather than passing through silently.
//   2. Entry point. `${name}` resolves on both entry points; `${{ name }}`
//      throws on [resolveSync] even when a backing is configured.
//   3. Unbound names. `${name}` consults [strict] — throw, or render empty
//      under lenient. `${{ name }}` consults *neither*: the unbound case is
//      the backing's to decide, so the resolver's mode does not reach it.
// The two agree on exactly one case: a bound name, resolved through
// [resolve], against a backing that reads the flattened scope.
//
// After each substitution pass the result is re-scanned; expansion repeats
// up to [maxRecursion] levels (default 10) and then errors with
// `placeholder.recursion.exceeded`.
//
// What is re-scanned is the WHOLE text, so a substituted value is scanned
// again whatever form produced it, and what it can reference is every
// namespace this resolver has: a binding value may reference the environment,
// an environment value may reference a binding, and an expression result is
// text like any other. The only thing not re-scanned is a reserved
// `${file:…}` / `${state:…}` form, which is never substituted at any level.
//
// That is the composition feature and the trust boundary at once. Any text
// this resolver expands - an environment variable, a config value read from a
// file, an evaluator's return value - is expanded against the full namespace
// rather than inserted as data, so a value arriving from outside the program
// that happens to contain `${…}` is not inert. To resolve untrusted text,
// give it a resolver with nothing to reach: an empty `environment` over a
// fresh stack, in strict mode, refuses an unknown reference rather than
// rendering it away. There is no per-value "insert as data" mode.
//
// Strict vs lenient: an unknown `${name}` / `${env:NAME}` either
// errors (`placeholder.unresolved`, strict) or renders as an empty string
// (lenient). The default is strict.
//
// Two entry points:
//   [resolve]     async — supports every form, including `${{ … }}`.
//   [resolveSync] sync  — supports `${name}` / `${env:NAME}` / reserved
//                 only; a `${{ … }}` form throws. This is the env-only /
//                 binding-only path the config loaders use, which never
//                 needs asynchronous expression evaluation.

import 'dart:io';

import 'placeholder_errors.dart';
import 'placeholder_expressions.dart';
import 'placeholder_stack.dart';

/// Which kind of placeholder a scan found.
enum _PlaceholderForm { simple, env, expression, reserved }

/// One placeholder token located by the scanner.
typedef _Token = ({
  int start,
  int tokenEnd,
  _PlaceholderForm form,
  String body,
  // True only for the optional simple form `${name?}`: an unbound name
  // renders empty regardless of [PlaceholderResolver.strict]. Always false
  // for env / expression / reserved forms.
  bool optional,
});

/// Resolves placeholder scaffolds against a [PlaceholderStack] of bindings,
/// the process environment, and an optional [PlaceholderExpressions]
/// backing for the `${{ … }}` form.
///
/// Callers push / pop / bind on `resolver.stack` to model nested call
/// frames, then [resolve] (or [resolveSync]) a scaffold against the current
/// scope.
final class PlaceholderResolver {
  /// Creates a resolver over [stack] (a fresh standalone stack by default),
  /// in [strict] or lenient unknown-handling mode, capping recursive
  /// expansion at [maxRecursion] levels.
  ///
  /// [expressions] backs the `${{ … }}` form; when `null` (the config-layer
  /// default) an expression form fails with a
  /// [PlaceholderExpressionException] rather than silently passing through.
  PlaceholderResolver({
    PlaceholderStack? stack,
    this.expressions,
    this.strict = true,
    this.maxRecursion = 10,
    Map<String, String>? environment,
  }) : stack = stack ?? PlaceholderStack(),
       environment = environment ?? Platform.environment;

  /// The live binding namespace both the simple and expression forms read.
  final PlaceholderStack stack;

  /// Backs the `${{ … }}` form; `null` in the config-layer (no d4rt).
  final PlaceholderExpressions? expressions;

  /// The environment `${env:NAME}` reads from. Defaults to the live
  /// process environment ([Platform.environment]); an explicit map makes
  /// the env form injectable (config loaders pass a fixed map so a
  /// `${env:NAME}` apiKey resolves deterministically).
  final Map<String, String> environment;

  /// When true, an unknown `${name}` / `${env:NAME}` errors with
  /// [PlaceholderUnresolvedException]; when false it renders as empty.
  final bool strict;

  /// Maximum number of re-scan passes before declaring non-convergence.
  final int maxRecursion;

  /// Expands every resolvable placeholder in [template], re-scanning until
  /// the text converges or the recursion cap is hit. Supports every form,
  /// including `${{ … }}`.
  ///
  /// Reserved (`${file:…}` / `${state:…}`) placeholders are left verbatim
  /// and do not count as resolvable, so a template of only reserved
  /// placeholders converges immediately.
  Future<String> resolve(String template) async {
    var current = template;
    var level = 0;
    while (_hasResolvable(current)) {
      if (level >= maxRecursion) {
        throw PlaceholderRecursionException(
          maxRecursion: maxRecursion,
          residue: current,
        );
      }
      current = await _expandOnce(current);
      level++;
    }
    return current;
  }

  /// Synchronous expansion supporting `${name}` / `${env:NAME}` / reserved
  /// only. A `${{ … }}` expression form throws a
  /// [PlaceholderExpressionException] — the synchronous path has no way to
  /// await an evaluator. This is the env-only / binding-only path the
  /// config loaders use.
  String resolveSync(String template) {
    var current = template;
    var level = 0;
    while (_hasResolvable(current)) {
      if (level >= maxRecursion) {
        throw PlaceholderRecursionException(
          maxRecursion: maxRecursion,
          residue: current,
        );
      }
      current = _expandOnceSync(current);
      level++;
    }
    return current;
  }

  /// One left-to-right async substitution pass.
  Future<String> _expandOnce(String input) async {
    final out = StringBuffer();
    var index = 0;
    while (index < input.length) {
      final token = _nextToken(input, index);
      if (token == null) {
        out.write(input.substring(index));
        break;
      }
      out.write(input.substring(index, token.start));
      switch (token.form) {
        case _PlaceholderForm.reserved:
          out.write(input.substring(token.start, token.tokenEnd));
        case _PlaceholderForm.env:
          out.write(_resolveEnv(token.body));
        case _PlaceholderForm.simple:
          out.write(_resolveSimple(token.body, optional: token.optional));
        case _PlaceholderForm.expression:
          out.write(_render(await _evaluateExpression(token.body)));
      }
      index = token.tokenEnd;
    }
    return out.toString();
  }

  /// One left-to-right synchronous substitution pass; a `${{ … }}` form is
  /// rejected.
  String _expandOnceSync(String input) {
    final out = StringBuffer();
    var index = 0;
    while (index < input.length) {
      final token = _nextToken(input, index);
      if (token == null) {
        out.write(input.substring(index));
        break;
      }
      out.write(input.substring(index, token.start));
      switch (token.form) {
        case _PlaceholderForm.reserved:
          out.write(input.substring(token.start, token.tokenEnd));
        case _PlaceholderForm.env:
          out.write(_resolveEnv(token.body));
        case _PlaceholderForm.simple:
          out.write(_resolveSimple(token.body, optional: token.optional));
        case _PlaceholderForm.expression:
          throw PlaceholderExpressionException(
            expression: token.body,
            cause: StateError(
              r'the ${{ … }} expression form is unavailable in resolveSync(); '
              'use resolve()',
            ),
          );
      }
      index = token.tokenEnd;
    }
    return out.toString();
  }

  /// Whether [input] still holds a *resolvable* placeholder (reserved
  /// prefixes do not count).
  bool _hasResolvable(String input) {
    var index = 0;
    while (true) {
      final token = _nextToken(input, index);
      if (token == null) {
        return false;
      }
      if (token.form != _PlaceholderForm.reserved) {
        return true;
      }
      index = token.tokenEnd;
    }
  }

  Future<Object?> _evaluateExpression(String body) {
    final backing = expressions;
    if (backing == null) {
      throw PlaceholderExpressionException(
        expression: body,
        cause: StateError(
          r'no PlaceholderExpressions backing is configured; the ${{ … }} '
          'form is unavailable in this resolver',
        ),
      );
    }
    return backing.evaluate(body, stack.flatten());
  }

  String _resolveEnv(String name) {
    final value = environment[name];
    if (value != null) {
      return value;
    }
    if (strict) {
      throw PlaceholderUnresolvedException('env:$name');
    }
    return '';
  }

  String _resolveSimple(String name, {bool optional = false}) {
    if (stack.has(name)) {
      return _render(stack.lookup(name));
    }
    // The optional marker (`${name?}`) overrides strict mode for this slot:
    // an unbound optional name vanishes rather than throwing.
    if (optional) {
      return '';
    }
    if (strict) {
      throw PlaceholderUnresolvedException(name);
    }
    return '';
  }

  static String _render(Object? value) => value == null ? '' : '$value';

  /// Locates the next placeholder at or after [from], or `null` if none.
  ///
  /// Recognises `${{ … }}` (expression, brace-balanced) before `${…}`
  /// (simple / env / reserved). An unterminated `${` is skipped so it is
  /// emitted as literal text rather than swallowing the rest of the input.
  _Token? _nextToken(String input, int from) {
    var search = from;
    while (true) {
      final open = input.indexOf(r'${', search);
      if (open < 0) {
        return null;
      }
      if (input.startsWith(r'${{', open)) {
        final end = _findExpressionEnd(input, open + 3);
        if (end < 0) {
          search = open + 3;
          continue;
        }
        return (
          start: open,
          tokenEnd: end + 2,
          form: _PlaceholderForm.expression,
          body: input.substring(open + 3, end).trim(),
          optional: false,
        );
      }
      final close = input.indexOf('}', open + 2);
      if (close < 0) {
        search = open + 2;
        continue;
      }
      final raw = input.substring(open + 2, close).trim();
      final form = _classify(raw);
      // The optional marker is scoped to the simple binding form only: a
      // trailing `?` on `${name?}` makes the slot vanish when unbound. `?` is
      // not a valid identifier character, so a trailing `?` is unambiguous.
      final optional = form == _PlaceholderForm.simple && raw.endsWith('?');
      return (
        start: open,
        tokenEnd: close + 1,
        form: form,
        body: optional
            ? raw.substring(0, raw.length - 1).trimRight()
            : _bodyOf(raw),
        optional: optional,
      );
    }
  }

  static _PlaceholderForm _classify(String raw) {
    if (raw.startsWith('env:')) {
      return _PlaceholderForm.env;
    }
    if (raw.startsWith('file:') || raw.startsWith('state:')) {
      return _PlaceholderForm.reserved;
    }
    return _PlaceholderForm.simple;
  }

  /// The lookup key for a `${…}` body: the env name without its `env:`
  /// prefix, or the raw body for the simple / reserved forms (reserved
  /// bodies are copied verbatim from the source, so the key is unused).
  static String _bodyOf(String raw) =>
      raw.startsWith('env:') ? raw.substring('env:'.length).trim() : raw;

  /// Index of the first `}` of the closing `}}` for an expression that
  /// opened at [start] (just past the `${{`), or `-1` if unterminated.
  ///
  /// Tracks nested `{ }` so an inner brace (e.g. a map literal in the
  /// expression) does not close the placeholder early.
  static int _findExpressionEnd(String input, int start) {
    var depth = 0;
    for (var i = start; i < input.length; i++) {
      final char = input[i];
      if (char == '{') {
        depth++;
      } else if (char == '}') {
        if (depth > 0) {
          depth--;
        } else if (i + 1 < input.length && input[i + 1] == '}') {
          return i;
        } else {
          return -1;
        }
      }
    }
    return -1;
  }
}

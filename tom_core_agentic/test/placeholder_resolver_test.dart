// Tests for the shared `PlaceholderResolver` — the single `${…}` engine the
// whole brain stack resolves through. It lives in `tom_core_agentic` so the
// substrate / access / memory / run config loaders and the engine all share
// one mechanism, and a `${…}` therefore means the same thing wherever it is
// written.
//
// What this file pins (the four forms + the two entry points):
//   * `${env:NAME}` is the *only* way to reach the environment.
//   * a bare `${name}` reads a stack binding; unbound → strict error, or
//     empty in lenient mode.
//   * `${{ expr }}` evaluates through the injected `PlaceholderExpressions`
//     backing on the async path; on `resolveSync` (and with no backing) it
//     is a located error.
//   * reserved `${file:…}` / `${state:…}` pass through verbatim.
//   * recursive expansion converges, and over-deep expansion errors.
//
// The d4rt-backed `${{ … }}` evaluation is exercised end-to-end in
// `tom_brain_procedure` (where the evaluator lives); here the expression seam
// is a trivial fake so the resolver's wiring is tested in isolation.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

/// A trivial [PlaceholderExpressions] backing: renders `${{ body }}` as
/// `<body=scope[body]>` so a test can assert both that the body and the
/// flattened scope reached the seam.
final class _FakeExpressions implements PlaceholderExpressions {
  @override
  Future<Object?> evaluate(String body, Map<String, Object?> scope) async =>
      scope.containsKey(body) ? scope[body] : '<$body>';
}

void main() {
  group(r'PlaceholderResolver — env form (${env:NAME})', () {
    test('resolves an env var only through the env: prefix', () {
      final r = PlaceholderResolver(environment: const {'TOKEN': 'secret'});
      expect(r.resolveSync(r'Bearer ${env:TOKEN}'), 'Bearer secret');
    });

    test('an undefined env var is a strict error naming env:NAME', () {
      final r = PlaceholderResolver(environment: const {});
      expect(
        () => r.resolveSync(r'${env:MISSING}'),
        throwsA(
          isA<PlaceholderUnresolvedException>().having(
            (e) => e.reference,
            'reference',
            'env:MISSING',
          ),
        ),
      );
    });

    test('an undefined env var renders empty in lenient mode', () {
      final r = PlaceholderResolver(environment: const {}, strict: false);
      expect(r.resolveSync(r'[${env:MISSING}]'), '[]');
    });
  });

  group(r'PlaceholderResolver — simple form (${name})', () {
    test(r'a bare ${name} reads a stack binding, NOT the environment', () {
      final r = PlaceholderResolver(environment: const {'NAME': 'from-env'});
      r.stack.bind('NAME', 'from-binding');
      // The bare form never reaches the environment: it reads the binding.
      expect(r.resolveSync(r'${NAME}'), 'from-binding');
    });

    test(r'an unbound ${name} is a strict error (no env fallback)', () {
      final r = PlaceholderResolver(environment: const {'NAME': 'from-env'});
      expect(
        () => r.resolveSync(r'${NAME}'),
        throwsA(
          isA<PlaceholderUnresolvedException>().having(
            (e) => e.reference,
            'reference',
            'NAME',
          ),
        ),
      );
    });

    test(r'an unbound ${name} renders empty in lenient mode', () {
      final r = PlaceholderResolver(environment: const {}, strict: false);
      expect(r.resolveSync(r'[${nope}]'), '[]');
    });
  });

  group(r'PlaceholderResolver — optional form (${name?})', () {
    test(r'an unbound ${name?} renders empty even in strict mode', () {
      // strict is the default — the ? overrides it for this slot only.
      final r = PlaceholderResolver(environment: const {});
      expect(r.resolveSync(r'[${absent?}]'), '[]');
    });

    test(r'a bound ${name?} renders its value', () {
      final r = PlaceholderResolver(environment: const {});
      r.stack.bind('todo_list', '- buy milk');
      expect(r.resolveSync(r'${todo_list?}'), '- buy milk');
    });

    test(r'a bare ${name} (no ?) still throws in strict mode', () {
      // The ? is per-slot: the strict default is untouched for bare lookups.
      final r = PlaceholderResolver(environment: const {});
      expect(
        () => r.resolveSync(r'${absent}'),
        throwsA(
          isA<PlaceholderUnresolvedException>().having(
            (e) => e.reference,
            'reference',
            'absent',
          ),
        ),
      );
    });

    test(r'${name?} works identically on the async resolve() path', () async {
      final r = PlaceholderResolver(
        environment: const {},
        expressions: _FakeExpressions(),
      );
      expect(await r.resolve(r'[${absent?}]'), '[]');
      r.stack.bind('present', 'X');
      expect(await r.resolve(r'${present?}'), 'X');
    });

    test(r'a bound ${name?} re-scans its value like a bare binding', () {
      final r = PlaceholderResolver(environment: const {'ROOT': '/srv'});
      r.stack.bind('hint', r'${env:ROOT}/x');
      expect(r.resolveSync(r'${hint?}'), '/srv/x');
    });

    test(r'the optional marker does not apply to ${env:NAME?}', () {
      // Optionality is scoped to the simple binding form only;
      // an env name carrying a trailing ? is just an unresolvable env lookup.
      final r = PlaceholderResolver(environment: const {'TOKEN': 'secret'});
      expect(
        () => r.resolveSync(r'${env:TOKEN?}'),
        throwsA(
          isA<PlaceholderUnresolvedException>().having(
            (e) => e.reference,
            'reference',
            'env:TOKEN?',
          ),
        ),
      );
    });

    test(r'a literal ? outside a placeholder is untouched', () {
      final r = PlaceholderResolver(environment: const {});
      r.stack.bind('name', 'Tom');
      expect(r.resolveSync(r'${name}, are you there?'), 'Tom, are you there?');
    });

    test(r'whitespace around the ? is tolerated (${ name ? })', () {
      // The optional marker is as whitespace-forgiving as the bare form: the
      // trailing ? is stripped and the remainder right-trimmed, so `${ name ? }`
      // optionally resolves the binding `name`.
      final r = PlaceholderResolver(environment: const {});
      r.stack.bind('name', 'Tom');
      expect(r.resolveSync(r'[${ name ? }]'), '[Tom]');
      // …and an unbound spaced optional still vanishes rather than throwing.
      expect(r.resolveSync(r'[${ absent ? }]'), '[]');
    });

    test(r'optional overrides lenient mode identically to strict', () {
      // D1.5: an unbound ${name?} renders empty whether the resolver is strict
      // or lenient — the marker's whole purpose is "render empty".
      final lenient = PlaceholderResolver(strict: false, environment: const {});
      expect(lenient.resolveSync(r'[${absent?}]'), '[]');
      lenient.stack.bind('present', 'X');
      expect(lenient.resolveSync(r'${present?}'), 'X');
    });
  });

  group(r'PlaceholderResolver — expression form (${{ … }})', () {
    test('resolveSync rejects an expression form', () {
      final r = PlaceholderResolver(environment: const {});
      expect(
        () => r.resolveSync(r'${{ 1 + 1 }}'),
        throwsA(isA<PlaceholderExpressionException>()),
      );
    });

    test('resolve with no backing is a located expression error', () {
      final r = PlaceholderResolver(environment: const {});
      expect(
        () => r.resolve(r'${{ 1 + 1 }}'),
        throwsA(isA<PlaceholderExpressionException>()),
      );
    });

    test(
      'resolve evaluates through the injected backing with the scope',
      () async {
        final r = PlaceholderResolver(
          environment: const {},
          expressions: _FakeExpressions(),
        );
        r.stack.bind('who', 'world');
        // Bound name → the backing returns the scope value.
        expect(await r.resolve(r'hello ${{ who }}'), 'hello world');
        // Unbound body → the fake renders <body>.
        expect(await r.resolve(r'${{ other }}'), '<other>');
      },
    );

    // Calling `${name}` "equivalent to `${{ name }}`" is the natural summary
    // and is wrong: the forms agree on exactly one case and diverge on three
    // axes. The three tests below pin each axis so the wording in
    // `doc/placeholders.md` and the resolver header cannot drift to it.

    test('the two forms agree only on a bound name via resolve + backing', () {
      // The single case in which substituting one form for the other is
      // behaviour-preserving.
      final r = PlaceholderResolver(
        environment: const {},
        expressions: _FakeExpressions(),
      );
      r.stack.bind('name', 'Tom');
      expect(r.resolve(r'${name}'), completion(equals('Tom')));
      expect(r.resolve(r'${{ name }}'), completion(equals('Tom')));
    });

    test('axis 1+2: the simple form needs neither a backing nor resolve', () {
      // Backing: without one, `${name}` resolves and `${{ name }}` throws.
      final bare = PlaceholderResolver(environment: const {});
      bare.stack.bind('name', 'Tom');
      expect(bare.resolveSync(r'${name}'), 'Tom');
      expect(
        () => bare.resolve(r'${{ name }}'),
        throwsA(isA<PlaceholderExpressionException>()),
      );

      // Entry point: even *with* a backing, the expression form is
      // unavailable synchronously — so the config loaders, which only ever
      // call resolveSync, can never reach an expression at all.
      final backed = PlaceholderResolver(
        environment: const {},
        expressions: _FakeExpressions(),
      );
      backed.stack.bind('name', 'Tom');
      expect(backed.resolveSync(r'${name}'), 'Tom');
      expect(
        () => backed.resolveSync(r'${{ name }}'),
        throwsA(isA<PlaceholderExpressionException>()),
      );
    });

    test('axis 3: an unbound expression body ignores strict AND lenient', () {
      // The simple form routes an unbound name through the resolver's mode;
      // the expression form hands it to the backing, which decides. So the
      // mode is not merely bypassed under strict — it is never consulted,
      // which is why the divergence survives switching to lenient.
      for (final strict in [true, false]) {
        final r = PlaceholderResolver(
          strict: strict,
          environment: const {},
          expressions: _FakeExpressions(),
        );
        // Simple form: mode-dependent.
        if (strict) {
          expect(
            () => r.resolveSync(r'${missing}'),
            throwsA(isA<PlaceholderUnresolvedException>()),
            reason: 'strict must reject an unbound simple name',
          );
        } else {
          expect(r.resolveSync(r'${missing}'), '');
        }
        // Expression form: identical under both modes — the backing owns it.
        expect(
          r.resolve(r'${{ missing }}'),
          completion(equals('<missing>')),
          reason: 'the backing decides, regardless of strict=$strict',
        );
      }
    });
  });

  group('PlaceholderResolver — the simple form has no grammar', () {
    test('a non-identifier body is a lookup key like any other', () {
      // `_classify` routes on prefix alone, so anything that is not env: /
      // file: / state: is a simple lookup. `isSimpleIdentifier` describes the
      // d4rt-locals shape, not this form's accepted shape — a dotted name
      // (the shape of the substrate's `role.anchor` built-in) resolves fine.
      final r = PlaceholderResolver(environment: const {});
      r.stack.bind('role.anchor', 'ANCHOR');
      r.stack.bind('a.b c', 'SPACED');
      expect(r.resolveSync(r'${role.anchor}'), 'ANCHOR');
      expect(r.resolveSync(r'${a.b c}'), 'SPACED');
    });

    test('an unbound non-identifier body fails as unresolved, not as a '
        'malformed name', () {
      // The failure names the reference, so a template typo like ${a.b}
      // reports the thing that was not found rather than a grammar error.
      final r = PlaceholderResolver(environment: const {});
      expect(
        () => r.resolveSync(r'${a.b}'),
        throwsA(
          isA<PlaceholderUnresolvedException>().having(
            (e) => e.reference,
            'reference',
            'a.b',
          ),
        ),
      );
    });

    test('the resolver hands the backing every binding, unfiltered', () {
      // The identifier filter belongs to the backing. If the resolver applied
      // it here, a backing with different name rules could not see bindings
      // it is perfectly able to express.
      final r = PlaceholderResolver(
        environment: const {},
        expressions: _FakeExpressions(),
      );
      r.stack.bind('role.anchor', 'ANCHOR');
      r.stack.bind('ok', 1);
      expect(
        r.stack.flatten().keys,
        containsAll(<String>['role.anchor', 'ok']),
      );
    });
  });

  group('PlaceholderResolver — reserved prefixes', () {
    test(
      r'${file:…} / ${state:…} pass through verbatim and do not recurse',
      () {
        final r = PlaceholderResolver(environment: const {});
        expect(
          r.resolveSync(r'${file:/etc/x} and ${state:run.id}'),
          r'${file:/etc/x} and ${state:run.id}',
        );
      },
    );
  });

  group('PlaceholderResolver — recursion', () {
    test('a binding that references another binding expands transitively', () {
      final r = PlaceholderResolver(environment: const {'ROOT': '/srv'});
      r.stack.bindAll({'base': r'${env:ROOT}/brain', 'full': r'${base}/db'});
      expect(r.resolveSync(r'${full}'), '/srv/brain/db');
    });

    test('a self-referential binding errors at the recursion cap', () {
      final r = PlaceholderResolver(environment: const {}, maxRecursion: 5);
      r.stack.bind('loop', r'${loop}');
      expect(
        () => r.resolveSync(r'${loop}'),
        throwsA(isA<PlaceholderRecursionException>()),
      );
    });
  });

  group('PlaceholderResolver — passthrough', () {
    test(r'an unterminated ${ (no closing brace) is left verbatim', () {
      final r = PlaceholderResolver(environment: const {});
      expect(r.resolveSync(r'cost ${UNCLOSED here'), r'cost ${UNCLOSED here');
    });

    test('a bare \$ without a brace is left verbatim', () {
      final r = PlaceholderResolver(environment: const {});
      expect(r.resolveSync(r'price $5'), r'price $5');
    });
  });

  // Characterization tests. These pin behaviours the resolver and its failure
  // types already implement so a future refactor cannot silently change them:
  // the typed wire codes, the brace-balanced expression scan, and the
  // unterminated-`${{` passthrough.
  group('PlaceholderResolver — typed failure wire codes', () {
    test('recursion failure carries its code and a descriptive message', () {
      const e = PlaceholderRecursionException(
        maxRecursion: 3,
        residue: r'${loop}',
      );
      expect(e.code, placeholderRecursionExceededCode);
      expect(e.message, allOf(contains('3'), contains('residue')));
      expect(e.toString(), contains(e.message));
    });

    test('unresolved failure carries its code and names the reference', () {
      const e = PlaceholderUnresolvedException('topic');
      expect(e.code, placeholderUnresolvedCode);
      expect(e.message, contains('topic'));
      expect(e.toString(), contains(e.message));
    });

    test('expression failure carries its code and names the expression', () {
      final e = PlaceholderExpressionException(
        expression: 'x + 1',
        cause: StateError('boom'),
      );
      expect(e.code, placeholderExpressionFailedCode);
      expect(e.message, allOf(contains('x + 1'), contains('boom')));
      expect(e.toString(), contains(e.message));
    });
  });

  group('PlaceholderResolver — expression brace balancing', () {
    test(r'a ${{ … }} body with a nested { } is captured whole', () async {
      // The scan must track the inner `{ }` of a map literal so the closing
      // `}}` is the *outer* one, not the inner brace.
      final r = PlaceholderResolver(
        environment: const {},
        expressions: _FakeExpressions(),
      );
      // The fake renders an unbound body as `<body>`; the body must arrive as
      // the full `{'a': 1}`, proving the nested brace did not close early.
      expect(
        await r.resolve(r"pre ${{ {'a': 1} }} post"),
        r"pre <{'a': 1}> post",
      );
    });

    test(r'an unterminated ${{ (no closing }}) is left verbatim', () {
      final r = PlaceholderResolver(environment: const {});
      expect(r.resolveSync(r'cost ${{ 1 + 1 here'), r'cost ${{ 1 + 1 here');
    });
  });

  group('PlaceholderResolver — what a substituted value can reach', () {
    // The loop re-scans `current` — the whole output of a pass — so a
    // substituted value is scanned again whatever form produced it. Only the
    // transitive-binding half of that was documented or tested, and the rest
    // is the half that decides whether feeding untrusted text to a resolver is
    // safe: an environment variable, a config value or an expression result
    // that happens to contain `${…}` reaches every namespace the resolver can
    // reach, not just its own.
    //
    // Each case below is one (source of the value → namespace it reaches)
    // pair. They are written out rather than parameterised because the point
    // is that the answer is the same for all of them, and a table would hide
    // the one that stopped being true.

    test('a binding value reaches the binding namespace', () {
      final stack = PlaceholderStack()
        ..bind('a', r'${b}')
        ..bind('b', 'B');
      final r = PlaceholderResolver(stack: stack, environment: const {});
      expect(r.resolveSync(r'${a}'), 'B');
    });

    test('an environment value reaches the binding namespace', () {
      // The case that makes this a boundary rather than a convenience: the
      // environment is outside the program, and a value taken from it is
      // expanded against bindings the template author chose.
      final stack = PlaceholderStack()..bind('secret', 'CLASSIFIED');
      final r = PlaceholderResolver(
        stack: stack,
        environment: const {'GREETING': r'hi ${secret}'},
      );
      expect(r.resolveSync(r'${env:GREETING}'), 'hi CLASSIFIED');
    });

    test('an environment value reaches the environment namespace', () {
      final r = PlaceholderResolver(
        environment: const {'A': r'${env:B}', 'B': 'bee'},
      );
      expect(r.resolveSync(r'${env:A}'), 'bee');
    });

    test('a binding value reaches the environment namespace', () {
      final stack = PlaceholderStack()..bind('x', r'${env:TOKEN}');
      final r = PlaceholderResolver(
        stack: stack,
        environment: const {'TOKEN': 'tok-value'},
      );
      expect(r.resolveSync(r'${x}'), 'tok-value');
    });

    test('the optional form is re-scanned like the plain one', () {
      // `${name?}` differs from `${name}` only in how an *unbound* name is
      // handled; a bound one renders identically, re-scan included.
      final stack = PlaceholderStack()
        ..bind('o', r'${b}')
        ..bind('b', 'B');
      final r = PlaceholderResolver(stack: stack, environment: const {});
      expect(r.resolveSync(r'${o?}'), 'B');
    });

    test('an expression result is re-scanned too', () async {
      final stack = PlaceholderStack()
        ..bind('e', r'${b}')
        ..bind('b', 'B');
      final r = PlaceholderResolver(
        stack: stack,
        expressions: _FakeExpressions(),
        environment: const {},
      );
      expect(await r.resolve(r'${{ e }}'), 'B');
    });

    test('a reserved form in a value stays verbatim', () {
      // The one exception, and it is not an exception to the rule: a reserved
      // placeholder is never substituted at any level, so there is nothing to
      // re-scan. A value that looks like one survives the round trip.
      final stack = PlaceholderStack()..bind('r', r'${file:secret.txt}');
      final r = PlaceholderResolver(stack: stack, environment: const {});
      expect(r.resolveSync(r'${r}'), r'${file:secret.txt}');
    });

    test('an unresolvable injected reference is silent under lenient', () {
      // The half that makes a malformed injection hard to notice: the
      // reference renders as nothing rather than failing, so the output looks
      // merely odd instead of wrong.
      final r = PlaceholderResolver(
        strict: false,
        environment: const {'G': r'hi ${nope}'},
      );
      expect(r.resolveSync(r'${env:G}'), 'hi ');
    });

    test('an empty stack and an empty environment isolate a template', () {
      // The mitigation, pinned so it stays available: a resolver with nothing
      // in either namespace has nothing an injected reference can reach, and
      // under strict it refuses rather than rendering empty.
      final r = PlaceholderResolver(environment: const {});
      expect(
        () => r.resolveSync(r'hi ${secret}'),
        throwsA(
          isA<PlaceholderUnresolvedException>().having(
            (e) => e.reference,
            'reference',
            'secret',
          ),
        ),
      );
    });
  });

  group('PlaceholderResolver — an explicitly supplied stack', () {
    // `stack` is the one constructor parameter that lets two resolvers share a
    // namespace, which is the shape `placeholder_stack.dart`'s own header
    // describes: nested procedure frames resolving against one set of
    // bindings. Every construction in this package took the default, so a
    // regression that dropped the parameter and always allocated a fresh stack
    // would have passed the whole suite.

    test('the resolver holds the supplied stack, not a copy of it', () {
      final mine = PlaceholderStack();
      final r = PlaceholderResolver(stack: mine, environment: const {});
      expect(identical(r.stack, mine), isTrue);
    });

    test('a binding made after construction is visible to the resolver', () {
      // Liveness rather than seeding: binding before construction would pass
      // even against an implementation that copied the frames.
      final mine = PlaceholderStack();
      final r = PlaceholderResolver(stack: mine, environment: const {});
      mine.bind('who', 'world');
      expect(r.resolveSync(r'hello ${who}'), 'hello world');
    });

    test('two resolvers over one stack see the same bindings', () {
      final shared = PlaceholderStack()..bind('topic', 'whales');
      final first = PlaceholderResolver(stack: shared, environment: const {});
      final second = PlaceholderResolver(
        stack: shared,
        strict: false,
        environment: const {'ROOT': '/srv'},
      );

      expect(first.resolveSync(r'${topic}'), 'whales');
      expect(second.resolveSync(r'${topic}'), 'whales');

      // ... and a binding written through one resolver's view of the stack is
      // read by the other. The two resolvers differ in mode and environment,
      // so what they share is the namespace and nothing else.
      first.stack.bind('depth', 'deep');
      expect(second.resolveSync(r'${depth}'), 'deep');
      // The environment is NOT shared: `second` was built with one and
      // `first` was not, so the same template resolves for one and is a
      // strict failure for the other. What the stack parameter shares is the
      // binding namespace and nothing else.
      expect(second.resolveSync(r'${env:ROOT}'), '/srv');
      expect(
        () => first.resolveSync(r'${env:ROOT}'),
        throwsA(isA<PlaceholderUnresolvedException>()),
      );
    });

    test('two resolvers left to default do NOT share a stack', () {
      // The control. Without it every assertion above would also pass against
      // an implementation that handed every resolver one process-wide stack,
      // which is the opposite defect and a worse one.
      final first = PlaceholderResolver(strict: false, environment: const {});
      final second = PlaceholderResolver(strict: false, environment: const {});
      first.stack.bind('leak', 'visible');

      expect(identical(first.stack, second.stack), isFalse);
      expect(first.resolveSync(r'${leak}'), 'visible');
      expect(second.resolveSync(r'${leak}'), '');
    });

    test('push and pop on a shared stack move both resolvers together', () {
      // The frame shape the module exists for: a child frame shadows the
      // parent for every reader of the stack, and pop restores it for both.
      final shared = PlaceholderStack()..bind('scope', 'outer');
      final a = PlaceholderResolver(stack: shared, environment: const {});
      final b = PlaceholderResolver(stack: shared, environment: const {});

      shared.push(<String, Object?>{'scope': 'inner'});
      expect(a.resolveSync(r'${scope}'), 'inner');
      expect(b.resolveSync(r'${scope}'), 'inner');

      shared.pop();
      expect(a.resolveSync(r'${scope}'), 'outer');
      expect(b.resolveSync(r'${scope}'), 'outer');
    });
  });
}

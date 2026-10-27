// Runnable demo of the shared placeholder engine.
//
// Walks the placeholder forms (simple, optional, env, expression, reserved),
// the two entry points (resolveSync / resolve), the lexical scope stack with
// its shadow/restore semantics, transitive recursion, and the typed failures.
// An explicit `environment:` map is passed so the demo is deterministic and
// does not read the real process environment.
//
// Run with:
//   dart run --enable-asserts example/placeholders/placeholders_example.dart

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../require_asserts.dart';

Future<void> main() async {
  requireAsserts();
  _demoSimpleAndEnv();
  _demoOptional();
  _demoScopeStack();
  _demoSharedStack();
  _demoRecursion();
  await _demoExpression();
  _demoFailures();

  print('\nplaceholders demo completed.');
}

// ---------------------------------------------------------------------------
// Simple bindings and the env: form — the synchronous, config-layer path.
// ---------------------------------------------------------------------------
void _demoSimpleAndEnv() {
  print('== simple + env ==');
  final r = PlaceholderResolver(environment: const {'ROOT': '/srv'});
  r.stack.bind('name', 'Tom');

  // ${name} reads a binding; ${env:NAME} is the only way to the environment.
  print('  ${r.resolveSync(r'${name} lives under ${env:ROOT}')}');
  assert(
    r.resolveSync(r'${name} lives under ${env:ROOT}') == 'Tom lives under /srv',
  );

  // Reserved prefixes pass through verbatim.
  final reserved = r.resolveSync(r'${file:/etc/x} ${state:run.id}');
  print('  reserved untouched: $reserved');
  assert(reserved == r'${file:/etc/x} ${state:run.id}');
}

// ---------------------------------------------------------------------------
// The optional ${name?} form vanishes when unbound, in any mode.
// ---------------------------------------------------------------------------
void _demoOptional() {
  print('== optional ==');
  final r = PlaceholderResolver(environment: const {}); // strict by default
  r.stack.bind('present', 'X');

  // Bound → value; unbound optional → empty even though the resolver is strict.
  final out = r.resolveSync(r'[${present?}][${absent?}]');
  print('  $out');
  assert(out == '[X][]');
}

// ---------------------------------------------------------------------------
// The scope stack: a child frame shadows the parent; pop restores it.
// ---------------------------------------------------------------------------
void _demoScopeStack() {
  print('== scope stack ==');
  final r = PlaceholderResolver(environment: const {});
  r.stack.bind('topic', 'whales');

  r.stack.push({'topic': 'penguins'}); // child shadows parent
  print('  in child:  ${r.resolveSync(r'${topic}')}');
  assert(r.resolveSync(r'${topic}') == 'penguins');

  r.stack.pop(); // parent restored
  print('  in parent: ${r.resolveSync(r'${topic}')}');
  assert(r.resolveSync(r'${topic}') == 'whales');
}

// ---------------------------------------------------------------------------
// One stack, two resolvers — the shape nested call frames resolve against.
// ---------------------------------------------------------------------------
void _demoSharedStack() {
  print('== shared stack ==');

  // `stack:` is the parameter that lets two resolvers share a namespace. Left
  // out, each resolver allocates its own, which is why the demos above can use
  // `r.stack` without disturbing one another.
  final shared = PlaceholderStack()..bind('topic', 'whales');
  final prompt = PlaceholderResolver(stack: shared, environment: const {});
  final config = PlaceholderResolver(
    stack: shared,
    environment: const {'ROOT': '/srv'},
  );

  print('  prompt: ${prompt.resolveSync(r'about ${topic}')}');
  print('  config: ${config.resolveSync(r'${env:ROOT}/${topic}')}');
  assert(prompt.resolveSync(r'about ${topic}') == 'about whales');
  assert(config.resolveSync(r'${env:ROOT}/${topic}') == '/srv/whales');

  // A binding written through one is read by the other, and a pushed frame
  // moves both — they share the namespace and nothing else, so `config` keeps
  // its environment and `prompt` still has none.
  prompt.stack.bind('depth', 'deep');
  shared.push(<String, Object?>{'topic': 'squid'});
  print('  after push: ${config.resolveSync(r'${topic} ${depth}')}');
  assert(config.resolveSync(r'${topic} ${depth}') == 'squid deep');
  shared.pop();
  assert(prompt.resolveSync(r'${topic}') == 'whales');

  print('  one namespace, two resolvers; pop restored the parent frame');
}

// ---------------------------------------------------------------------------
// Recursion: a binding that references another expands transitively.
// ---------------------------------------------------------------------------
void _demoRecursion() {
  print('== recursion ==');
  final r = PlaceholderResolver(environment: const {'ROOT': '/srv'});
  r.stack.bindAll({'base': r'${env:ROOT}/brain', 'full': r'${base}/db'});
  final out = r.resolveSync(r'${full}');
  print('  $out');
  assert(out == '/srv/brain/db');
}

// ---------------------------------------------------------------------------
// The ${{ … }} expression form evaluates through an injected backing.
// ---------------------------------------------------------------------------
Future<void> _demoExpression() async {
  print('== expression seam ==');
  final r = PlaceholderResolver(
    environment: const {},
    expressions: _UppercaseExpressions(),
  );
  r.stack.bind('who', 'world');

  // The backing receives the body and the flattened scope.
  final out = await r.resolve(r'hello ${{ who }}');
  print('  $out');
  assert(out == 'hello WORLD');
}

// ---------------------------------------------------------------------------
// Typed failures: each carries a stable wire code.
// ---------------------------------------------------------------------------
void _demoFailures() {
  print('== failures ==');
  final strict = PlaceholderResolver(environment: const {});

  // Unknown ${name} under strict mode.
  try {
    strict.resolveSync(r'${missing}');
  } on PlaceholderUnresolvedException catch (e) {
    print('  unresolved -> ${e.code}');
    assert(e.code == placeholderUnresolvedCode);
  }

  // A ${{ … }} on the sync path (or with no backing) is a located error.
  try {
    strict.resolveSync(r'${{ 1 + 1 }}');
  } on PlaceholderExpressionException catch (e) {
    print('  expression -> ${e.code}');
    assert(e.code == placeholderExpressionFailedCode);
  }

  // A cyclic binding hits the recursion cap.
  final capped = PlaceholderResolver(environment: const {}, maxRecursion: 5)
    ..stack.bind('loop', r'${loop}');
  try {
    capped.resolveSync(r'${loop}');
  } on PlaceholderRecursionException catch (e) {
    print('  recursion  -> ${e.code} (cap ${e.maxRecursion})');
    assert(e.code == placeholderRecursionExceededCode);
  }
}

/// A trivial [PlaceholderExpressions] backing that upper-cases the scope value
/// named by the expression body — standing in for the engine's d4rt backing.
final class _UppercaseExpressions implements PlaceholderExpressions {
  @override
  Future<Object?> evaluate(String body, Map<String, Object?> scope) async {
    final value = scope[body];
    return value is String ? value.toUpperCase() : value;
  }
}

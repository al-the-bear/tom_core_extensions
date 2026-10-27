# Tom Core Agentic API Summary: `placeholders`

Sources: `lib/src/placeholders/placeholder_errors.dart`, `lib/src/placeholders/placeholder_expressions.dart`, `lib/src/placeholders/placeholder_resolver.dart`, `lib/src/placeholders/placeholder_stack.dart`, `lib/src/placeholders/placeholders.dart`.

Symbol-level mirror of `lib/src/placeholders/`: every type, top-level function
and constant the unit's barrel exports, one section each. `doc/placeholders.md`
explains the forms, the scope rule and the two entry points; this page is the
surface.

Ten exported names across thirty-five public members. Six types, one function,
three constants.

| Symbol | Kind |
| ------ | ---- |
| [`PlaceholderResolver`](#placeholderresolver) | final class |
| [`PlaceholderStack`](#placeholderstack) | final class |
| [`PlaceholderExpressions`](#placeholderexpressions) | abstract interface class |
| [`PlaceholderRecursionException`](#placeholderrecursionexception) | final class |
| [`PlaceholderUnresolvedException`](#placeholderunresolvedexception) | final class |
| [`PlaceholderExpressionException`](#placeholderexpressionexception) | final class |
| [`isSimpleIdentifier`](#issimpleidentifier) | function |
| [`placeholderRecursionExceededCode`](#placeholderrecursionexceededcode) | `const String` |
| [`placeholderUnresolvedCode`](#placeholderunresolvedcode) | `const String` |
| [`placeholderExpressionFailedCode`](#placeholderexpressionfailedcode) | `const String` |

## The expander

### PlaceholderResolver

`final class`. Expands the four placeholder forms in a template, re-scanning
after each pass until nothing resolvable remains.

```dart
PlaceholderResolver({
  PlaceholderStack? stack,
  PlaceholderExpressions? expressions,
  bool strict = true,
  int maxRecursion = 10,
  Map<String, String>? environment,
});

Future<String> resolve(String template);
String resolveSync(String template);
```

**Every parameter is optional.** `stack` defaults to a fresh standalone
`PlaceholderStack` and `environment` to `Platform.environment`, so
`PlaceholderResolver()` is a working strict resolver over its own empty scope
and the live process environment. The two nullable parameters become
non-nullable fields — `stack` and `environment` are never `null` on the
instance, whatever the caller passed.

| Member | Meaning |
| ------ | ------- |
| `stack` | The binding chain `${name}` reads and `${{ … }}` is handed flattened. |
| `expressions` | The `${{ … }}` backing, or `null`. A config-layer resolver is built with none on purpose, so a stray expression fails fast instead of passing through. |
| `environment` | The map `${env:NAME}` reads. Defaults to `Platform.environment`; passing one explicitly is what keeps a resolver off the live environment, which is how the config loaders make an `${env:NAME}` resolve deterministically. |
| `strict` | Whether an unbound `${name}` / `${env:NAME}` throws (the default) or renders empty. |
| `maxRecursion` | Level cap on re-expansion, default 10. |
| `resolve` | Async. Supports every form. |
| `resolveSync` | Sync. `${name}`, `${env:NAME}` and the reserved prefixes only; a `${{ … }}` form throws even when a backing is configured. |

**The two entry points are not the same function with a different colour.**
`resolveSync` refuses `${{ … }}` unconditionally — the backing's `evaluate`
returns a `Future`, so there is nothing to wait on synchronously — and that is
the whole reason the config loaders can use it without an expression evaluator.

**A substituted value is re-scanned.** The loop re-scans the whole text, so
what a value can reference is every namespace the resolver has — a binding
value may reference the environment and an environment value may reference a
binding. Only a reserved form is exempt, because it is never substituted. That
is the composition feature and the trust boundary at once: text from outside
the program is expanded rather than inserted as data. `doc/placeholders.md`
§ *What a Substituted Value Can Reach* has the table and the isolation a caller
has.

**The four forms.** `${name}` and `${name?}` read a binding, the second
rendering empty for an unbound name whatever `strict` says. `${{ expr }}` goes
to the backing. `${env:NAME}` reads `environment` and is the only route to it.
`${file:…}` and `${state:…}` are reserved: recognised, passed through verbatim,
and not re-scanned.

**`${{ name }}` does not subsume `${name}`.** They differ on the backing (the
simple form always resolves), on the entry point (the expression form throws on
`resolveSync`), and on an unbound name (the simple form consults `strict`; the
expression form leaves the case to the backing, so the resolver's mode never
reaches it). They agree on exactly one case: a bound name, through `resolve`,
against a backing that reads the flattened scope.

## The scope chain

### PlaceholderStack

`final class`. Lexical, shadowing scope as a stack of binding frames. Starts
with one root frame.

```dart
PlaceholderStack();

int get depth;
void push([Map<String, Object?>? initial]);
void pop();
void bind(String name, Object? value);
void bindAll(Map<String, Object?> values);
bool has(String name);
Object? lookup(String name);
Map<String, Object?> flatten();
```

| Member | Meaning |
| ------ | ------- |
| `depth` | Frames on the stack; the root counts as 1. |
| `push` | Opens a child frame, optionally seeded. The seed is **copied**, so later mutation of the map does not leak in. |
| `pop` | Discards the top frame. Throws `StateError` on the root — the root is never popped. |
| `bind` | Writes to the current frame, shadowing a same-named parent binding for as long as the frame lives. |
| `bindAll` | `bind` for every entry of a map. |
| `has` | Whether **any** frame binds the name. |
| `lookup` | The nearest enclosing binding, or `null`. |
| `flatten` | The whole chain as one map, children winning — the view `${{ … }}` evaluates against. |

**`lookup` returning `null` is ambiguous and deliberately so.** A binding may
hold `null`, so a caller that must tell "absent" from "bound to null" consults
`has` first. The two methods exist as a pair for that reason.

**`bind` validates nothing.** Any string is a legal binding name and the simple
form will resolve it; `${role.anchor}` is a real, dotted, resolvable name. Only
an expression backing constrains the shape — see `isSimpleIdentifier`.

### PlaceholderExpressions

`abstract interface class`. The seam through which the `${{ … }}` form is
evaluated.

```dart
Future<Object?> evaluate(String body, Map<String, Object?> scope);
```

The inversion point that keeps this package free of a d4rt dependency: the
engine supplies a d4rt-backed implementation, while a config-layer resolver is
built with none. An implementation surfaces a parse or runtime failure as a
`PlaceholderExpressionException`.

### isSimpleIdentifier

`bool isSimpleIdentifier(String name)` — whether `name` is a bare Dart
identifier (`^[a-zA-Z_$][a-zA-Z0-9_$]*$`).

**This is not the grammar of the simple form.** That form has no grammar: the
scanner routes on prefix alone, so every body that is not `env:` / `file:` /
`state:` becomes a lookup key. What the predicate describes is the shape a
binding must have to become a **d4rt expression local**, because such a local
becomes a parameter name in the synthesised function. The backing applies it,
filtering `PlaceholderStack.flatten` before synthesising the parameter list.

The consequence is an asymmetry worth knowing: a non-identifier binding is
visible to `${name}` and invisible to `${{ … }}`, dropped from the expression's
locals silently rather than reported.

## Failures

The three exceptions share a shape: a `code` getter carrying the wire string, a
`message` getter reused by `toString`, and the fields that say what failed.

### PlaceholderRecursionException

`final class`. Expansion did not converge within the resolver's cap.

```dart
const PlaceholderRecursionException({
  required int maxRecursion,
  required String residue,
});

String get code;     // placeholderRecursionExceededCode
String get message;
```

`residue` is the partially expanded text still holding placeholders at the cap,
so a trail entry shows what failed to converge. A cyclic binding is the typical
cause.

### PlaceholderUnresolvedException

`final class`. An unknown `${name}` / `${env:NAME}` under **strict** mode; in
lenient mode the same situation renders empty and raises nothing.

```dart
const PlaceholderUnresolvedException(String reference);

String get code;     // placeholderUnresolvedCode
String get message;
```

`reference` is the text as written inside the braces — `topic` for `${topic}`,
`env:HOME` for `${env:HOME}`.

### PlaceholderExpressionException

`final class`. A `${{ … }}` that threw, would not parse, or met a resolver with
no backing at all.

```dart
const PlaceholderExpressionException({
  required String expression,
  required Object cause,
});

String get code;     // placeholderExpressionFailedCode
String get message;
```

Carrying both `expression` and `cause` is what lets a failure say *which*
expression failed and *why*; the no-backing case arrives here too, with the
absence as the cause.

## Wire codes

The three are **wire contract**, not internal labels: they leave the process in
trail entries and error payloads and consumers route on the exact string.
Renaming one breaks every such consumer, so the spellings are fixed even where
a tidier word exists. Each is a named constant so a caller matches an
identifier rather than retyping a literal.

### placeholderRecursionExceededCode

`const String` — `'placeholder.recursion.exceeded'`. Carried by
`PlaceholderRecursionException.code`.

### placeholderUnresolvedCode

`const String` — `'placeholder.unresolved'`. Carried by
`PlaceholderUnresolvedException.code`.

### placeholderExpressionFailedCode

`const String` — `'placeholder.expression.failed'`. Carried by
`PlaceholderExpressionException.code`.

## Global Functions and Constants

| Name | Declaration | Description |
| ---- | ----------- | ----------- |
| `isSimpleIdentifier` | `bool isSimpleIdentifier(String name)` | Returns whether [name] is a bare Dart identifier. |

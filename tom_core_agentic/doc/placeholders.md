# Placeholders Module

The single `${…}` substitution engine the whole brain stack resolves through —
every config layer (substrate / access / memory / run) and the prompt engine
share this one mechanism, so a placeholder means the same thing everywhere. The
module owns four parts: the lexical scope chain (`PlaceholderStack`), the typed
failures (`placeholder_errors`), the `${{ … }}` expression seam
(`PlaceholderExpressions`), and the resolver itself (`PlaceholderResolver`).

> **Looking for a signature?** This page explains behaviour.
> [`doc/api/api_summary_placeholders.md`](api/api_summary_placeholders.md) is
> the symbol-level mirror: six types, one function and three constants with a
> section each. `test/api_summary_test.dart` derives the required set from the
> barrel, so it cannot fall behind the code.

## Table of Contents

- [Overview](#overview)
- [The Placeholder Forms](#the-placeholder-forms)
- [Two Entry Points: resolve vs resolveSync](#two-entry-points-resolve-vs-resolvesync)
- [The Scope Stack](#the-scope-stack)
- [The Expression Seam](#the-expression-seam)
- [Strict vs Lenient, and Recursion](#strict-vs-lenient-and-recursion)
- [What a Substituted Value Can Reach](#what-a-substituted-value-can-reach)
- [Failure Types](#failure-types)
- [Core Components](#core-components)
- [Dependencies](#dependencies)

---

## Overview

| Symbol | Kind | Purpose |
| ------ | ---- | ------- |
| `PlaceholderResolver` | final class | Expands every placeholder form in a template; `resolve` (async) / `resolveSync` |
| `PlaceholderStack` | final class | Lexical, shadowing scope chain the simple and expression forms both read |
| `PlaceholderExpressions` | abstract interface class | The seam the `${{ … }}` form evaluates through (d4rt in the engine, absent in config layers) |
| `isSimpleIdentifier` | function | Whether a name is a bare Dart identifier — the d4rt expression-locals shape, applied by the backing. *Not* the simple form's grammar, which has none |
| `PlaceholderRecursionException` | final class | Expansion did not converge within `maxRecursion` levels |
| `PlaceholderUnresolvedException` | final class | An unknown `${name}` / `${env:NAME}` under strict mode |
| `PlaceholderExpressionException` | final class | A `${{ … }}` that threw, would not parse, or had no backing |
| `placeholderRecursionExceededCode` / `placeholderUnresolvedCode` / `placeholderExpressionFailedCode` | `const String` | The three stable wire codes (one per failure) |

## The Placeholder Forms

| Form | Meaning |
| ---- | ------- |
| `${name}` | Simple fast path — reads a binding from the current scope. Never reaches the environment. Not interchangeable with `${{ name }}` — see below. |
| `${name?}` | **Optional** simple lookup — an unbound name renders as the empty string *regardless* of strict/lenient mode; a bound name renders its value exactly like `${name}`. Optionality is a property of the call site (the `?`), scoped to the simple form only. |
| `${{ expr }}` | An arbitrary expression evaluated through the injected `PlaceholderExpressions` backing (d4rt in the engine). Brace-balanced, so an inner map literal does not close it early. |
| `${env:NAME}` | A process-environment read — the one pure, non-expression form, and the *only* way to reach the environment. |
| `${file:…}` / `${state:…}` | Reserved prefixes — recognised and never resolved. They pass through verbatim and are not re-scanned, so a template author can write them without collision. The resolver does no I/O: a caller that wants a file's contents or a state value supplies it as a binding. |

The optional marker is scoped deliberately: `${env:NAME?}` and `${{ … ?}}` do
**not** take the marker — there the `?` is just part of the name or body.

**`${{ name }}` does not subsume `${name}`.** The expression form is a superset
in *expressive power*, not in behaviour: the two forms diverge on three axes.

| Axis | `${name}` | `${{ name }}` |
| ---- | --------- | ------------- |
| **Backing** | Always resolves. | Requires a `PlaceholderExpressions` backing; without one it throws `PlaceholderExpressionException`. Config-layer resolvers deliberately have no backing. |
| **Entry point** | Resolves on both `resolve` and `resolveSync`. | Throws on `resolveSync` even when a backing *is* configured. |
| **Unbound name** | Consults `strict` — throws, or renders empty under lenient. | Consults *neither* mode; the unbound case belongs to the backing, so the resolver's strict/lenient setting never reaches it. |

The forms agree on exactly one case: a **bound** name, resolved through
**`resolve`**, against a backing that reads the flattened scope. Everywhere
else, substituting one for the other changes behaviour. This is by design —
the no-backing failure is what makes a stray `${{ … }}` in a config value fail
fast instead of passing through silently (see
[The Expression Seam](#the-expression-seam)).

## Two Entry Points: resolve vs resolveSync

- **`resolve` (async)** supports *every* form, including `${{ … }}`. This is the
  engine's prompt-assembly path.
- **`resolveSync`** supports `${name}` / `${env:NAME}` / reserved only; a
  `${{ … }}` form throws a `PlaceholderExpressionException`. The synchronous path
  has no way to await an evaluator, so it is the env-only / binding-only path the
  config loaders use — they never need asynchronous expression evaluation.

```dart
final resolver = PlaceholderResolver(environment: const {'ROOT': '/srv'});
resolver.stack.bindAll({'base': r'${env:ROOT}/brain', 'full': r'${base}/db'});

// Synchronous, env + binding only:
resolver.resolveSync(r'${full}');           // '/srv/brain/db'

// Asynchronous, with an expression backing:
final engine = PlaceholderResolver(
  environment: const {},
  expressions: myD4rtBacking,
);
await engine.resolve(r'hello ${{ who }}');  // evaluated through the backing
```

## The Scope Stack

`PlaceholderStack` models the d4rt lexical scope chain as a stack of binding
frames. Each nested procedure / `sub.llm` frame pushes a child; a child may bind
its own variables — even same-named ones, shadowing the parent — and on `pop` the
child is discarded so lower-level writes never leak upward.

```dart
final stack = resolver.stack;
stack.bind('topic', 'whales');     // writes to the current (top) frame
stack.push({'topic': 'penguins'}); // child shadows the parent
stack.lookup('topic');             // 'penguins'  (top → root)
stack.pop();
stack.lookup('topic');             // 'whales'    (parent restored)
```

Both forms read **one** namespace: the simple `${name}` form reads a binding
directly from the stack, and the `${{ … }}` form receives the stack `flatten`ed
(child frames winning collisions) as the locals it evaluates against. Because a
binding may legitimately hold `null`, distinguish "absent" from "bound to null"
with `has` before `lookup`.

One namespace is not the same as one *visible* namespace. `bind` accepts any
string as a name and the simple form resolves any body, but a d4rt local has to
be an identifier, so `D4rtExpressionContext` filters `flatten()` through
`isSimpleIdentifier` before building its parameter list. A non-identifier
binding is therefore readable as `${name}` and silently absent from
`${{ … }}` — dropped, not an error. The brain substrate relies on exactly this:
`role.anchor` is a dotted built-in that its system scaffold resolves through
the simple form.

## The Expression Seam

`PlaceholderExpressions` is the inversion point for the `${{ … }}` form. The
resolver core lives here in `tom_core_agentic` so every layer shares it, but the
`${{ … }}` form is a *d4rt* expression and this package keeps **no** d4rt
dependency. So the engine (in `tom_brain_procedure`, which owns d4rt) supplies a
d4rt-backed implementation, while a config-layer resolver is built with **no**
backing — a stray `${{ … }}` in a config value then fails fast (a
`PlaceholderExpressionException`) rather than silently passing through.

## Strict vs Lenient, and Recursion

- **Strict (default)** — an unknown `${name}` / `${env:NAME}` throws
  `PlaceholderUnresolvedException`. **Lenient** — the same case renders as an
  empty string. The optional `${name?}` form renders empty in *both* modes.
- **Recursion** — after each substitution pass the result is re-scanned;
  expansion repeats up to `maxRecursion` levels (default 10) and then throws
  `PlaceholderRecursionException` carrying the partially-expanded residue (a
  cyclic binding is the typical cause). Reserved prefixes are not resolvable, so
  a template of only reserved placeholders converges immediately.

## What a Substituted Value Can Reach

The re-scan is of the whole text, not only of the parts that were already
there, so **a substituted value is scanned again whatever form produced it** —
and what it can reference is every namespace the resolver has. There is no
per-form rule; the table is one answer repeated:

| A value taken from | can reference | Example |
| ------------------ | ------------- | ------- |
| a binding | a binding | `a = '${b}'` renders `b`'s value |
| a binding | the environment | `x = '${env:TOKEN}'` renders the variable |
| the environment | a binding | `GREETING='hi ${secret}'` renders the *binding* `secret` |
| the environment | the environment | `A='${env:B}'` renders `B` |
| a `${{ … }}` result | either | the evaluator's return value is text like any other |
| a `${name?}` value | either | optionality changes only the unbound case |

The one thing not re-scanned is a **reserved** `${file:…}` / `${state:…}` form,
and that is not an exception to the rule: a reserved placeholder is never
substituted at any level, so a value that looks like one survives the round
trip verbatim.

**The composition feature and the trust boundary are the same mechanism.** A
binding whose value is itself a template is why the re-scan exists. The
consequence is that any text the resolver expands — an environment variable, a
config value read from a file, an expression result — is expanded against the
resolver's full namespace rather than inserted as data, so a value arriving
from outside the program that happens to contain `${…}` is not inert.

Two properties make a bad case quiet rather than loud:

- Under **lenient** mode an injected reference that resolves to nothing renders
  as the empty string, so the output reads as merely odd rather than wrong.
- When strict mode does raise, the failure names the *reference* and not where
  it came from, so the diagnostic points at the injected text rather than at
  the value that carried it.

**If a template is untrusted, give it a resolver with nothing to reach.**
`PlaceholderResolver(environment: const {})` over a fresh stack has an empty
binding namespace and an empty environment, and under the default strict mode
it refuses an unknown reference instead of rendering it away. That is the
isolation available today: there is no per-value "insert as data" mode, and
adding one would have to answer for bindings as well as the environment, since
both carry the same property.

## Failure Types

Each failure carries a stable `code` (one of the three module constants) so a
caller can route on the code without string-matching the message:

| Exception | `code` | Raised when |
| --------- | ------ | ----------- |
| `PlaceholderRecursionException` | `placeholder.recursion.exceeded` | Expansion did not converge within `maxRecursion` levels |
| `PlaceholderUnresolvedException` | `placeholder.unresolved` | An unknown `${name}` / `${env:NAME}` under strict mode |
| `PlaceholderExpressionException` | `placeholder.expression.failed` | A `${{ … }}` threw, would not parse, or had no backing |

## Core Components

- **`PlaceholderResolver`** — the engine: the form scanner, the strict/lenient
  and recursion policy, and the `resolve` / `resolveSync` entry points.
- **`PlaceholderStack`** — the push/pop/bind/lookup/flatten scope chain.
- **`PlaceholderExpressions`** — the `${{ … }}` evaluation seam.
- **Error types + wire codes** — `PlaceholderRecursionException`,
  `PlaceholderUnresolvedException`, `PlaceholderExpressionException`, and their
  three `placeholder.*` codes.

## Dependencies

| Dependency | Kind | Imported by | For |
| ---------- | ---- | ----------- | --- |
| `dart:io` | dart | `placeholder_resolver.dart` | `PlaceholderResolver` imports `dart:io` for the `Platform.environment` default behind the `environment` constructor parameter. It is one of fourteen `dart:io` importers in the package and one of five coupled barrel exports (see the README's `dart:io` coupling section), so it is not an exception to a `dart:io`-free package — no such package-wide property exists. What is specific to this module is that its coupling is **incidental rather than inherent**: unlike `path_scope_io.dart` or the `agent/` stores, which exist to touch the filesystem, this one only supplies a default. Two consequences follow. Passing an explicit `environment:` map avoids the dependency at runtime, which every config-layer call site and every test already does; and removing the import — deferred rather than planned — would un-couple not just this module but `yaml_config_reader.dart`, whose only path to `dart:io` runs through here |

- No other `tom_core_agentic` module.

# Bearer Auth Module

The transport-neutral half of bearer-token authentication: an authenticator
interface, a rejection exception, and a closed set of three failure reasons.
Nothing here names a transport. A bearer token arrives, something validates it,
and the validation either yields a principal or fails for one of three reasons —
that sequence is identical whether the token rode in on an HTTP `Authorization`
header, an MCP `initialize` `_meta` field, a WebSocket handshake, or a queue
message envelope, so an edge on any of them reuses this module as-is.

The MCP-specific constants (the `_meta` slot and the JSON-RPC refusal code) live
one module over, in [MCP Auth](mcp_auth.md), and import this one. The direction
matters: MCP depends on the taxonomy, the taxonomy does not depend on MCP.

> **Looking for a signature?** This page is the mirror. `bearer_auth` is under
> the ten-type threshold in
> [`doc/api/api_summary_index.md`](api/api_summary_index.md), so it has no
> separate summary — and the Overview table below is held to every
> exported type, function and constant by `test/api_summary_test.dart`.

## Table of Contents

- [Overview](#overview)
- [Why It Is Its Own Module](#why-it-is-its-own-module)
- [Authenticators](#authenticators)
- [Failure Taxonomy](#failure-taxonomy)
- [What Stays Domain-Specific](#what-stays-domain-specific)
- [Core Components](#core-components)
- [Dependencies](#dependencies)

---

## Overview

| Symbol | Kind | Purpose |
| ------ | ---- | ------- |
| `BearerTokenAuthenticator<P>` | abstract interface class | Validates a token and resolves it to a principal of type `P` |
| `BearerAuthFailure` | final class | Raised when a token is rejected; carries a stable `reason` + a server-only `message` |
| `BearerAuthFailureReason` | enum | Closed set: `missing`, `malformed`, `rejected` |

## Why It Is Its Own Module

The natural home for these three types is the same file as the MCP wire
constants, under `mcp_auth/` — MCP is the edge that first needs them. They are
transport-independent there too, but a non-MCP edge cannot reach them without
importing a `_meta` key and a JSON-RPC error code it has no use for, so edges
re-declare the taxonomy instead of importing it. `tom_brain_access`'s HTTP edge
carries a copy of `BearerAuthFailure` whose `toString` is byte-identical to the
one here, and it carries that copy *while already depending on
`tom_core_agentic`*: the dependency is there, the reuse is not. Bundling, not
availability, is the obstacle.

Splitting the file is what makes the reuse claim checkable rather than
aspirational. `test/bearer_auth_test.dart` imports
`src/bearer_auth/bearer_auth_contract.dart` directly rather than the package
barrel, so the separation is a compile-time fact: if the taxonomy were ever
folded back in beside the constants, that test would stop compiling.

## Authenticators

An edge binds one `BearerTokenAuthenticator<P>`, parameterised on its
principal type. The interface is responsible for **authentication only** —
turning a token string into a principal, or rejecting it. *Authorisation* (role
/ entitlement checks against the principal) is the consuming edge's job, not the
contract's.

```dart
final class StaticAuthenticator implements BearerTokenAuthenticator<String> {
  final Map<String, String> _tokens;
  const StaticAuthenticator(this._tokens);

  @override
  String authenticate(String token) {
    if (token.isEmpty) {
      throw const BearerAuthFailure(BearerAuthFailureReason.missing, 'No token.');
    }
    final principal = _tokens[token];
    if (principal == null) {
      throw const BearerAuthFailure(BearerAuthFailureReason.rejected, 'Unknown token.');
    }
    return principal;
  }
}
```

That one is a lookup, and a lookup can only ever answer two of the three
reasons: with no parse step there is nothing for `malformed` to describe. An
authenticator that reads a structured token has a parse arm, and the arm is
what the third reason is about:

```dart
final Map<String, Object?> claims;
try {
  final segments = token.split('.');
  if (segments.length != 3) {
    throw const FormatException('expected three dot-separated segments');
  }
  final decoded = jsonDecode(utf8.decode(base64Url.decode(segments[1])));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('claims payload is not a JSON object');
  }
  claims = decoded;
} on FormatException catch (error) {
  throw BearerAuthFailure(
    BearerAuthFailureReason.malformed,
    'Token did not parse: ${error.message}',
  );
}
// Past here the token is understood, so every refusal is `rejected`.
```

`example/mcp_auth/mcp_auth_example.dart` runs that authenticator end to end and
`test/bearer_auth_test.dart` pins each category, so all three have a producer
rather than only a definition.

Implementations **must be synchronous**. Every transport that presents a bearer
token does so at a connection or request boundary that is on the hot path, so
this layer must not make an LLM / network call. The principal type parameter is
what keeps the contract identity-agnostic — a framework server binds
`BearerTokenAuthenticator<TomPrincipal>`, while a test or a different host binds
any other type. Because the parameter is covariant, a `<String>` authenticator is
also a `BearerTokenAuthenticator<Object>`, so generic plumbing can accept the raw
interface while a server holds the narrowly-typed one.

## Failure Taxonomy

`BearerAuthFailure` carries a stable `BearerAuthFailureReason` tag plus a
human-readable `message`. The tag is for telemetry and tests; the message is for
**server-side logs only**.

| Reason | Meaning |
| ------ | ------- |
| `missing` | No bearer token was presented at all when the edge requires one |
| `malformed` | The token was present but could not be parsed (bad JWT, unknown format) |
| `rejected` | The token parsed but failed authentication (guest, expired, unknown subject) |

The three categories are the ones every transport can tell apart from the token
alone, which is what keeps them neutral: *where* the token was supposed to be is
the edge's business, not the enum's. An HTTP edge that finds no `Authorization`
header and an MCP server that finds no `_meta` entry both report `missing`.

**`malformed` versus `rejected` is one question: did the server learn who was
claimed?** If the token never parsed, it did not, so it cannot have refused an
identity — that is `malformed`. If the token parsed and the identity was then
found wanting, that is `rejected`, and it stays `rejected` however the identity
failed. Three consequences worth stating, because each is a coin-flip to an
implementer meeting the enum for the first time:

- **An expired token is `rejected`.** It was perfectly well-formed; it simply no
  longer authenticates.
- **A signature that fails verification is `rejected`.** The token parsed — that
  is how its signature was found and checked at all.
- **Claims that parse but carry no subject are `malformed`.** The envelope was
  fine and the JSON was fine, and there is still no identity to reject.

Collapsing the two is the failure the tag exists to prevent: with one reason for
both, no dashboard built on it can tell a broken client from a hostile one.

> **Only the `reason` tag belongs on the wire.** Each edge translates a
> `BearerAuthFailure` into its own refusal — an HTTP 401, the JSON-RPC
> `bearerAuthRpcErrorCode`, a closed socket — but must **not** leak the
> underlying `message` to the client, because token-introspection error detail
> is a side channel for token-guessing attacks. No transport code lives on the
> exception itself; the mapping belongs to the edge. The reason set is closed by
> design: adding a category is a version bump, not a silent extension.

## What Stays Domain-Specific

This module is deliberately the *contract* only. The concrete authenticators
that bind a framework `TomPrincipal` (JWT-backed, static-token, …) and their
conformance tests live in their owning package (e.g. `tom_brain_memory`),
because they pull in `tom_core_kernel` identity types. Keeping the principal a
type parameter here is what lets the contract sit in the `tom_basics`-only tier.

## Core Components

- **`BearerTokenAuthenticator<P>`** — the synchronous, principal-parameterised
  authentication interface.
- **`BearerAuthFailure` / `BearerAuthFailureReason`** — the rejection exception
  and its closed reason set.

## Dependencies

- None. The contract file has no import directives at all — not `dart:async`,
  not another `tom_core_agentic` module — so it is reusable from any tier,
  including `dart:io`-forbidding consumers.

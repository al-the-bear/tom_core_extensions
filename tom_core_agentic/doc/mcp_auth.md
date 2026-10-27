# MCP Auth Module

The two MCP-specific facts about bearer-token authentication, shared so that
every MCP (Model Context Protocol) server in the framework refuses the same way
and every client has one slot to fill: *where* a token is carried at
`initialize` time, and *which* JSON-RPC error code an authentication failure
returns. Both are constants; there is no logic in this module.

The interface an authenticator implements and the failure taxonomy it throws are
**not** MCP facts and are not here. They live in [Bearer Auth](bearer_auth.md),
which this module imports and which an HTTP or WebSocket edge reuses without
taking on anything below.

> **Looking for a signature?** This page is the mirror. `mcp_auth` is under
> the ten-type threshold in
> [`doc/api/api_summary_index.md`](api/api_summary_index.md), so it has no
> separate summary — and the Overview table below is held to every
> exported type, function and constant by `test/api_summary_test.dart`.

## Table of Contents

- [Overview](#overview)
- [The Wire Contract](#the-wire-contract)
- [Translating a Failure](#translating-a-failure)
- [Core Components](#core-components)
- [Dependencies](#dependencies)

---

## Overview

| Symbol | Kind | Purpose |
| ------ | ---- | ------- |
| `bearerTokenMetaKey` | `const String` | The JSON-RPC `_meta` key a client uses to carry the bearer token at `initialize` |
| `bearerAuthRpcErrorCode` | `const int` | The JSON-RPC error code (`-32001`) a server returns when bearer auth fails |

## The Wire Contract

The MCP wire protocol does **not** carry an `Authorization` header on
stdio / UNIX-socket transports. The only request-level extensibility point at the
`initialize` boundary is the JSON-RPC `_meta` map, so the token rides there under
a well-known, namespaced key:

```dart
// Client side: place the token in _meta at initialize.
final initializeMeta = <String, Object?>{
  bearerTokenMetaKey: '<bearer-token>',
};
```

The key is namespaced (`tomBearerToken`) so it cannot collide with the MCP
standard `_meta.progressToken` reservation or with any other `_meta` consumer a
host layers on.

The `tom` prefix scopes it to the **framework**, not to a package in it. The
value read `tomBrainBearerToken` while the constant lived in `tom_brain`, which
would have had every future MCP server here — a planning server, a procedure
server — presenting its token under a key named for a package it does not depend
on. This is the one value in the module worth being careful about: every other
part of the contract is a Dart symbol a consumer can rename freely, whereas the
`_meta` key is the single thing a client and a server agree on **out of band**,
so it is the hardest element to change once independent implementations exist.

## Translating a Failure

A server holds a `BearerTokenAuthenticator<P>` from
[Bearer Auth](bearer_auth.md), calls it with whatever it found under
`bearerTokenMetaKey`, and turns a thrown `BearerAuthFailure` into a JSON-RPC
error:

```dart
final token = meta[bearerTokenMetaKey] as String? ?? '';
try {
  principal = authenticator.authenticate(token);
} on BearerAuthFailure catch (failure) {
  // Only the reason tag goes on the wire — never failure.message.
  respondWithError(code: bearerAuthRpcErrorCode, data: failure.reason.name);
}
```

`bearerAuthRpcErrorCode` (`-32001`) sits inside the JSON-RPC 2.0 server-defined
implementation range (`-32099 … -32000`); it is named so the value is never a
bare literal at the throw site, and shared so every MCP server in the framework
refuses with the same code. It is the **MCP half** of the translation — an HTTP
edge maps the same `BearerAuthFailureReason` onto a 401 instead, which is why
the code is here and the taxonomy is not.

## Core Components

- **`bearerTokenMetaKey`** — the `_meta` slot the token rides in at
  `initialize`.
- **`bearerAuthRpcErrorCode`** — the JSON-RPC code an MCP server refuses with.

## Dependencies

| Dependency | Kind | Imported by | For |
| ---------- | ---- | ----------- | --- |
| [bearer_auth](bearer_auth.md) | module | `mcp_bearer_wire.dart` | `BearerAuthFailure` and `BearerTokenAuthenticator`, the types the constants are used with |

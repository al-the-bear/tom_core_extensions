# tom_core_agentic API Reference: Mcp Auth Module

The public surface of `lib/src/mcp_auth/`, as its barrel exports it: the two
wire values every MCP server in the framework and its clients agree on for
bearer authentication. The authenticator contract and the failure taxonomy
they refer to live in `bearer_auth`; this module carries only what crosses the
MCP wire. `doc/mcp_auth.md` explains the handshake.

## Overview

Sources: `lib/src/mcp_auth/mcp_auth.dart`, `lib/src/mcp_auth/mcp_bearer_wire.dart`.

## Classes

None — this module exports constants only.

## Global Functions and Constants

| Name | Declaration | Description |
| ---- | ----------- | ----------- |
| `bearerTokenMetaKey` | `const bearerTokenMetaKey = 'tomBearerToken'` | The JSON-RPC `_meta` key under which a client places the bearer token at `initialize` time. |
| `bearerAuthRpcErrorCode` | `const bearerAuthRpcErrorCode = -32001` | The JSON-RPC error code an MCP server returns when a `BearerAuthFailure` is raised during `initialize`. |

### bearerTokenMetaKey

```dart
const bearerTokenMetaKey = 'tomBearerToken';
```

The JSON-RPC `_meta` key under which a client places the bearer token at
`initialize` time, when the server is configured with a
`BearerTokenAuthenticator`. The MCP wire carries no `Authorization` header on
stdio and UNIX-socket transports, and `_meta` is the one request-level
extensibility point at the `initialize` boundary. The `tom` prefix namespaces
the key to the framework, away from the standard `_meta.progressToken`
reservation and any other `_meta` consumer a host layers on.

### bearerAuthRpcErrorCode

```dart
const bearerAuthRpcErrorCode = -32001;
```

The JSON-RPC error code an MCP server returns when a `BearerAuthFailure` is
raised during the `initialize` handshake. It sits in the JSON-RPC 2.0
server-defined range (-32099 … -32000) and is shared, so every MCP server in the
framework refuses with the same code. An HTTP edge maps the same
`BearerAuthFailureReason` onto a 401 instead.

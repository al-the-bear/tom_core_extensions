# tom_core_agentic API Reference: Bearer Auth Module

The public surface of `lib/src/bearer_auth/`, as its barrel exports it.

## Overview

Sources: `lib/src/bearer_auth/bearer_auth.dart`, `lib/src/bearer_auth/bearer_auth_contract.dart`.

## Classes

### BearerAuthFailure

**Kind:** `final class`

Raised when a bearer token cannot be accepted.

#### Properties and Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `message` | `final String message` | Human-readable diagnostic, intended for server-side logs only. |
| `reason` | `final BearerAuthFailureReason reason` | Stable enum-like tag for the failure category. |

### BearerTokenAuthenticator

**Kind:** `abstract interface class`

Validates a bearer token and resolves it to a principal of type [P].

#### Properties and Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `authenticate` | `P authenticate(String token)` | Validates [token] and returns the resulting principal. |

## Enums

### BearerAuthFailureReason

Categories of bearer-token authentication failure.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `malformed` | `malformed` | The token string was present but could not be parsed (malformed JWT, unknown format, …). |
| `missing` | `missing` | No bearer token was presented at all when the edge requires one. |
| `rejected` | `rejected` | The token parsed but failed authentication (guest principal, expired, unknown subject, …). |

## Global Functions and Constants

None — this module exports types only.

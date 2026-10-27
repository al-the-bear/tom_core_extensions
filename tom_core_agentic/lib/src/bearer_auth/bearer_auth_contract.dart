// Transport-neutral bearer-token authentication contract.
//
// A bearer token arrives, something validates it, and the validation
// either yields a principal or fails for one of three reasons. That
// sequence is identical whether the token rode in on an HTTP
// `Authorization` header, an MCP `initialize` `_meta` field, a
// WebSocket handshake, or a queue message envelope — none of the types
// below name a transport, and none of them should.
//
// The natural home for this file is inside `mcp_auth/` next to the MCP
// wire constants, since MCP is the edge that first needs it. Bundling
// them means a non-MCP edge cannot reuse the taxonomy without importing
// MCP concepts it has no use for, so edges re-declare it instead —
// `tom_brain_access`'s HTTP edge carries a byte-identical copy of
// `BearerAuthFailure` for exactly that reason. The types are here,
// transport-free, so that reuse costs nothing. The MCP-specific wire
// constants stay in `mcp_auth/mcp_bearer_wire.dart` and import this
// contract, not the other way round.
//
// What stays domain-specific (and therefore does *not* live here): the
// concrete authenticators that turn a token into a framework principal
// (`TomPrincipal`). Those bind `tom_core_kernel` types and stay in their
// owning package. This contract keeps the principal type a parameter
// ([BearerTokenAuthenticator]'s `P`) so it can be reused without dragging
// the kernel into `tom_core_agentic` — which is `tom_basics`-only by
// design.

/// Validates a bearer token and resolves it to a principal of type [P].
///
/// Implementations are responsible for **authentication only** —
/// converting a token string into a principal or rejecting it.
/// Authorisation (role / entitlement checks against the principal) is
/// the consuming edge's job.
///
/// The principal type is a parameter so this contract stays free of any
/// particular auth model: a server that authenticates to a
/// framework `TomPrincipal` binds `BearerTokenAuthenticator<TomPrincipal>`;
/// a test or a different host can bind any other identity type.
///
/// Implementations must be synchronous. Every transport that presents a
/// bearer token does so at a connection or request boundary that is on
/// the hot path, so this layer must not make an LLM / network call.
abstract interface class BearerTokenAuthenticator<P extends Object> {
  /// Validates [token] and returns the resulting principal.
  ///
  /// Throws [BearerAuthFailure] if [token] is missing, malformed, or
  /// otherwise rejected.
  P authenticate(String token);
}

/// Raised when a bearer token cannot be accepted.
///
/// Carries a stable [reason] tag — useful for telemetry and tests —
/// plus a human-readable [message]. Each transport translates this into
/// its own refusal (an HTTP 401, a JSON-RPC error code, a closed
/// socket); the mapping belongs to the edge, which is why no code lives
/// on this type.
///
/// The [message] is **not** leaked to the client unmodified, whichever
/// transport does the translating, because token-introspection error
/// details can be a side channel for token-guessing attacks. Only the
/// [reason] tag belongs on the wire.
final class BearerAuthFailure implements Exception {
  /// Stable enum-like tag for the failure category.
  final BearerAuthFailureReason reason;

  /// Human-readable diagnostic, intended for server-side logs only.
  final String message;

  const BearerAuthFailure(this.reason, this.message);

  @override
  String toString() => 'BearerAuthFailure(${reason.name}): $message';
}

/// Categories of bearer-token authentication failure.
///
/// The set is closed by design — adding a new category is a version
/// bump, not a silent extension. The three categories are the ones
/// every transport can tell apart with the token alone, which is what
/// keeps them transport-neutral: where the token was *supposed* to be
/// is the edge's business, not this enum's.
enum BearerAuthFailureReason {
  /// No bearer token was presented at all when the edge requires one.
  missing,

  /// The token string was present but could not be parsed (malformed
  /// JWT, unknown format, …).
  malformed,

  /// The token parsed but failed authentication (guest principal,
  /// expired, unknown subject, …).
  rejected,
}

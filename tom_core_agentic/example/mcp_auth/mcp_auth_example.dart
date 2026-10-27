// Runnable demo of the generic MCP bearer-auth contract.
//
// It plays both sides of an MCP `initialize` handshake without any real
// transport: a client puts a token in the JSON-RPC `_meta` map under the
// well-known key, and a tiny server reads it back, authenticates it through a
// BearerTokenAuthenticator, and translates a refusal into the shared JSON-RPC
// error code. The principal type is a plain String, standing in for the
// framework TomPrincipal a real server would bind.
//
// The authenticator here PARSES its token, which is what lets it produce all
// three failure reasons. A lookup-only authenticator can only ever answer
// `missing` and `rejected`: with no parse step there is nothing for
// `malformed` to describe. That is the distinction this demo exists to make
// concrete, because it is the one an implementer most easily collapses.
//
// Run with:
//   dart run --enable-asserts example/mcp_auth/mcp_auth_example.dart

import 'dart:convert';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../require_asserts.dart';

void main() {
  requireAsserts();
  // A server binds one authenticator over its principal type. Here the
  // principal is a String username; a framework server would bind
  // BearerTokenAuthenticator<TomPrincipal>.
  final authenticator = _ClaimsTokenAuthenticator(const {'alice', 'bob'});
  final server = _MiniMcpServer(authenticator);

  // 1) A well-formed token for a known subject resolves to a principal.
  final ok = server.initialize(_clientMeta(_token(subject: 'alice')));
  print('valid token     -> $ok');
  assert(ok.principal == 'alice');
  assert(ok.rpcError == null);

  // 2) No token at all: reason `missing`.
  final missing = server.initialize(const <String, Object?>{});
  print('missing token   -> $missing');
  assert(missing.rpcError == bearerAuthRpcErrorCode);
  assert(missing.reason == BearerAuthFailureReason.missing);

  // 3) A token that never parses: reason `malformed`. The server learns
  //    nothing about who was claimed, because it never got that far.
  final malformed = server.initialize(_clientMeta('not-a-token'));
  print('unparseable     -> $malformed');
  assert(malformed.rpcError == bearerAuthRpcErrorCode);
  assert(malformed.reason == BearerAuthFailureReason.malformed);

  // 4) A token that parses cleanly and is refused anyway: reason `rejected`.
  final unknown = server.initialize(_clientMeta(_token(subject: 'mallory')));
  print('unknown subject -> $unknown');
  assert(unknown.reason == BearerAuthFailureReason.rejected);

  // 5) Expiry is also `rejected`, not `malformed`. The token was perfectly
  //    well-formed; it simply no longer authenticates.
  final expired = server.initialize(
    _clientMeta(_token(subject: 'alice', expires: DateTime.utc(2020, 1, 1))),
  );
  print('expired         -> $expired');
  assert(expired.reason == BearerAuthFailureReason.rejected);

  // The distinction the taxonomy turns on, stated as one comparison. Both
  // tokens below name a subject the server knows; the only difference is
  // whether the envelope parses. An authenticator that folded `malformed`
  // into `rejected` would answer the same for the two, and every telemetry
  // dashboard built on the tag would stop being able to tell a broken client
  // from a hostile one.
  final wellFormedButUnknown = server.initialize(
    _clientMeta(_token(subject: 'mallory')),
  );
  final knownButUnparseable = server.initialize(
    _clientMeta('v1.${base64Url.encode(utf8.encode('{"sub":"alice"}'))}'),
  );
  assert(wellFormedButUnknown.reason == BearerAuthFailureReason.rejected);
  assert(knownButUnparseable.reason == BearerAuthFailureReason.malformed);
  assert(wellFormedButUnknown.reason != knownButUnparseable.reason);

  print('\nmcp_auth demo completed.');
}

/// Builds the JSON-RPC `_meta` map a client sends at `initialize`, carrying the
/// bearer token under the agreed namespaced key.
Map<String, Object?> _clientMeta(String token) => <String, Object?>{
  bearerTokenMetaKey: token,
};

/// Mints a demo token: three dot-separated segments, the middle one a
/// base64url-encoded JSON claims object.
String _token({required String subject, DateTime? expires}) {
  final claims = <String, Object?>{
    'sub': subject,
    if (expires != null) 'exp': expires.millisecondsSinceEpoch ~/ 1000,
  };
  final payload = base64Url.encode(utf8.encode(jsonEncode(claims)));
  return 'v1.$payload.signature-not-verified-here';
}

/// An authenticator that parses its token before judging it, so all three
/// failure reasons have a producer.
///
/// The token shape is JWT-like on purpose — three dot-separated segments with
/// base64url JSON in the middle — because that is the shape the contract's own
/// documentation names. **It is not a JWT verifier**: the third segment is
/// never checked. A real implementation verifies the signature there, and a
/// signature that fails verification is `rejected`, not `malformed` — the
/// token parsed, it simply did not authenticate.
final class _ClaimsTokenAuthenticator
    implements BearerTokenAuthenticator<String> {
  _ClaimsTokenAuthenticator(this._knownSubjects, {DateTime? now})
    : _now = now ?? DateTime.now().toUtc();

  final Set<String> _knownSubjects;
  final DateTime _now;

  @override
  String authenticate(String token) {
    if (token.isEmpty) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.missing,
        'No bearer token presented.',
      );
    }

    // Everything from here to the closing brace is the parse. Any failure in
    // it is `malformed`: the server cannot say who was claimed, so it cannot
    // have rejected them.
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

    final subject = claims['sub'];
    if (subject is! String || subject.isEmpty) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.malformed,
        'Claims carry no `sub`.',
      );
    }

    // From here the token is understood, so a refusal is about the identity
    // rather than the envelope.
    final expiry = claims['exp'];
    if (expiry is int &&
        DateTime.fromMillisecondsSinceEpoch(
          expiry * 1000,
          isUtc: true,
        ).isBefore(_now)) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.rejected,
        'Token expired.',
      );
    }
    if (!_knownSubjects.contains(subject)) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.rejected,
        'Unknown subject.',
      );
    }
    return subject;
  }
}

/// The result a server returns from `initialize`: either an authenticated
/// principal or a JSON-RPC error code (the diagnostic stays server-side).
///
/// [reason] is kept alongside the code because a server logs and meters on the
/// tag; it is deliberately *not* part of what goes on the wire.
class _InitializeResult {
  final String? principal;
  final int? rpcError;
  final BearerAuthFailureReason? reason;

  const _InitializeResult.ok(this.principal) : rpcError = null, reason = null;
  const _InitializeResult.refused(this.rpcError, this.reason)
    : principal = null;

  @override
  String toString() => principal != null
      ? 'principal=$principal'
      : 'refused(rpcError=$rpcError, reason=${reason?.name})';
}

/// A minimal MCP server that gates `initialize` on the bearer-auth contract.
class _MiniMcpServer {
  final BearerTokenAuthenticator<String> _authenticator;
  const _MiniMcpServer(this._authenticator);

  _InitializeResult initialize(Map<String, Object?> meta) {
    final token = (meta[bearerTokenMetaKey] as String?) ?? '';
    try {
      return _InitializeResult.ok(_authenticator.authenticate(token));
    } on BearerAuthFailure catch (failure) {
      // Only the error code goes on the wire; the message is logged locally
      // and the reason tag is metered locally.
      print('  [server log] refused: $failure');
      return _InitializeResult.refused(bearerAuthRpcErrorCode, failure.reason);
    }
  }
}

// Unit tests for the MCP-specific bearer-auth wire constants.
//
// Only the two constants live here. The failure taxonomy and the
// authenticator interface they are used with are transport-neutral and
// are covered by `bearer_auth_test.dart`, which imports them without
// this file's constants ever entering scope.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('mcp_auth contract constants', () {
    test('bearerTokenMetaKey is the agreed namespaced _meta slot', () {
      expect(bearerTokenMetaKey, equals('tomBearerToken'));
    });

    test('bearerTokenMetaKey is scoped to the framework, not to a package', () {
      // The key is the only part of this module that a client and a
      // server must agree on out of band, so it is the only part whose
      // name cannot be corrected by the compiler later. It read
      // `tomBrainBearerToken` while the constant lived in `tom_brain`,
      // which would have had a planning or procedure server presenting
      // its token under a key named for a package it does not depend on.
      //
      // Asked as a closed rule rather than against a list of package names.
      // A list fails open: it has to be told a name somebody already thought
      // of, so minting `tom_forge` and writing `tomForgeBearerToken` would
      // pass it silently. What the key may contain instead is stated
      // positively — the `tom` scope and the two words naming the thing — so
      // any package name inserted anywhere fails whether or not this file has
      // heard of it.
      expect(bearerTokenMetaKey, startsWith('tom'));
      final words = RegExp(
        r'[A-Z][a-z]+',
      ).allMatches(bearerTokenMetaKey).map((m) => m.group(0)).toList();
      expect(
        words,
        equals(const ['Bearer', 'Token']),
        reason:
            'the shared wire key names what it carries and nothing else; '
            'any other capitalised word in it is a package name',
      );
    });

    test(
      'bearerAuthRpcErrorCode sits in the JSON-RPC server-defined range',
      () {
        expect(bearerAuthRpcErrorCode, equals(-32001));
        expect(bearerAuthRpcErrorCode, inInclusiveRange(-32099, -32000));
      },
    );
  });
}

// Unit tests for the transport-neutral bearer-token contract.
//
// These tests are kernel-free *and* transport-free — nothing here names
// MCP, HTTP, or any other edge, which is the point: the contract these
// cases pin is the one an HTTP edge reuses as-is. The contract is
// parameterised over the principal type, so a String stands in for the
// framework `TomPrincipal` the memory package binds. The kernel-coupled
// concrete authenticators (Jwt / Static) and their conformance tests
// stay in tom_brain_memory; the MCP wire constants are covered by
// `mcp_auth_test.dart`.
//
// The import below deliberately names the contract file rather than the
// package barrel. Going through the barrel would pull `bearerTokenMetaKey`
// and `bearerAuthRpcErrorCode` into scope too, and this file would keep
// compiling if the taxonomy were ever folded back in beside them — which
// is the state the split exists to prevent. Importing the leaf makes the
// separation a compile-time fact instead of a claim in a comment.

import 'dart:convert';

import 'package:tom_core_agentic/src/bearer_auth/bearer_auth_contract.dart';
import 'package:test/test.dart';

/// A trivial in-test authenticator binding a `String` principal, used to
/// exercise the generic [BearerTokenAuthenticator] contract without
/// pulling any auth model into the test.
final class _FakeStringAuthenticator
    implements BearerTokenAuthenticator<String> {
  final Map<String, String> _tokens;
  const _FakeStringAuthenticator(this._tokens);

  @override
  String authenticate(String token) {
    if (token.isEmpty) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.missing,
        'Empty bearer token.',
      );
    }
    final principal = _tokens[token];
    if (principal == null) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.rejected,
        'Unknown token.',
      );
    }
    return principal;
  }
}

/// An authenticator that **parses** its token before judging it.
///
/// [_FakeStringAuthenticator] above is a map lookup, and a map lookup cannot
/// produce [BearerAuthFailureReason.malformed] at all: with no parse step
/// there is nothing for that reason to describe. So the category that most
/// distinguishes this taxonomy from a boolean accept/reject needs a producer
/// of a different shape, and this is it.
///
/// The token is JWT-like — three dot-separated segments, base64url JSON in the
/// middle — because that is the shape the contract's documentation names. It
/// is **not** a JWT verifier: the third segment is never read. A real
/// implementation verifies a signature there, and a signature that fails
/// verification is `rejected` rather than `malformed`, since the token parsed
/// perfectly well.
///
/// `now` is injected so expiry is a decided fact rather than a race.
final class _ClaimsTokenAuthenticator
    implements BearerTokenAuthenticator<String> {
  const _ClaimsTokenAuthenticator(this._knownSubjects, this._now);

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

/// A well-formed demo token for [subject], optionally carrying an expiry.
String _token(String subject, {DateTime? expires}) {
  final claims = <String, Object?>{
    'sub': subject,
    if (expires != null) 'exp': expires.millisecondsSinceEpoch ~/ 1000,
  };
  return 'v1.${base64Url.encode(utf8.encode(jsonEncode(claims)))}.sig';
}

/// The matcher every case below uses: a [BearerAuthFailure] carrying [reason].
Matcher throwsReason(BearerAuthFailureReason reason) =>
    throwsA(isA<BearerAuthFailure>().having((f) => f.reason, 'reason', reason));

void main() {
  group('BearerAuthFailureReason', () {
    test('is a closed set of exactly three categories', () {
      expect(BearerAuthFailureReason.values, hasLength(3));
      expect(
        BearerAuthFailureReason.values,
        containsAll(<BearerAuthFailureReason>[
          BearerAuthFailureReason.missing,
          BearerAuthFailureReason.malformed,
          BearerAuthFailureReason.rejected,
        ]),
      );
    });
  });

  group('BearerAuthFailure', () {
    test('toString carries the reason tag and the diagnostic message', () {
      const failure = BearerAuthFailure(
        BearerAuthFailureReason.rejected,
        'sample diagnostic',
      );
      expect(failure.toString(), contains('rejected'));
      expect(failure.toString(), contains('sample diagnostic'));
    });

    test('is an Exception with stable reason + message fields', () {
      const failure = BearerAuthFailure(
        BearerAuthFailureReason.malformed,
        'bad jwt',
      );
      expect(failure, isA<Exception>());
      expect(failure.reason, equals(BearerAuthFailureReason.malformed));
      expect(failure.message, equals('bad jwt'));
    });
  });

  group('BearerTokenAuthenticator<P> generic contract', () {
    test('resolves a known token to its principal of type P', () {
      const auth = _FakeStringAuthenticator({'tok': 'alice'});
      expect(auth.authenticate('tok'), equals('alice'));
    });

    test('throws missing for an empty token', () {
      const auth = _FakeStringAuthenticator({'tok': 'alice'});
      expect(
        () => auth.authenticate(''),
        throwsA(
          isA<BearerAuthFailure>().having(
            (f) => f.reason,
            'reason',
            BearerAuthFailureReason.missing,
          ),
        ),
      );
    });

    test('throws rejected for an unknown token', () {
      const auth = _FakeStringAuthenticator({'tok': 'alice'});
      expect(
        () => auth.authenticate('nope'),
        throwsA(
          isA<BearerAuthFailure>().having(
            (f) => f.reason,
            'reason',
            BearerAuthFailureReason.rejected,
          ),
        ),
      );
    });

    test('a BearerTokenAuthenticator<P> is a subtype of the raw interface', () {
      // Covariance: a <String> authenticator is usable where a
      // dynamic-principal authenticator is expected. This is what lets a
      // server hold BearerTokenAuthenticator<TomPrincipal> while generic
      // plumbing accepts the raw interface.
      const auth = _FakeStringAuthenticator({'tok': 'alice'});
      expect(auth, isA<BearerTokenAuthenticator<String>>());
      expect(auth, isA<BearerTokenAuthenticator<Object>>());
    });
  });

  group('a parsing authenticator produces all three reasons', () {
    // `malformed` had no producer anywhere in this package: the example's
    // authenticator and the fake above are both lookups, and the two places
    // the tests mentioned the reason asserted enum membership and constructed
    // a failure by hand — neither through an authenticator. So the one
    // category that needs a real parse step, and the one an implementer most
    // easily collapses into `rejected`, was the one nothing exercised.
    final now = DateTime.utc(2026, 1, 1);
    const known = {'alice'};
    final auth = _ClaimsTokenAuthenticator(known, now);

    test('a well-formed token for a known subject resolves', () {
      expect(auth.authenticate(_token('alice')), equals('alice'));
    });

    test('an empty token is missing', () {
      expect(
        () => auth.authenticate(''),
        throwsReason(BearerAuthFailureReason.missing),
      );
    });

    test('the parse decides malformed, in each of its three ways', () {
      // Wrong envelope, undecodable payload, and payload that is not an
      // object. All three are "the server never learned who was claimed",
      // which is precisely what the reason means.
      expect(
        () => auth.authenticate('not-a-token'),
        throwsReason(BearerAuthFailureReason.malformed),
      );
      expect(
        () => auth.authenticate('v1.!!!not-base64!!!.sig'),
        throwsReason(BearerAuthFailureReason.malformed),
      );
      expect(
        () => auth.authenticate(
          'v1.${base64Url.encode(utf8.encode('["not","an","object"]'))}.sig',
        ),
        throwsReason(BearerAuthFailureReason.malformed),
      );
    });

    test('claims that parse but name no subject are malformed too', () {
      // The envelope is fine and the JSON is fine; there is still no identity
      // to reject, so there is nothing for `rejected` to be about.
      expect(
        () => auth.authenticate(
          'v1.${base64Url.encode(utf8.encode('{"iss":"someone"}'))}.sig',
        ),
        throwsReason(BearerAuthFailureReason.malformed),
      );
    });

    test('an unknown subject is rejected, not malformed', () {
      expect(
        () => auth.authenticate(_token('mallory')),
        throwsReason(BearerAuthFailureReason.rejected),
      );
    });

    test('expiry is rejected, not malformed', () {
      // The token is perfectly well-formed; it simply no longer
      // authenticates. Landing this on `malformed` is the same collapse in
      // the other direction, and it is an easy one to make because both
      // failures are "something about the token is wrong".
      expect(
        () => auth.authenticate(
          _token('alice', expires: DateTime.utc(2025, 12, 31)),
        ),
        throwsReason(BearerAuthFailureReason.rejected),
      );
      // ... and an expiry still in the future does not refuse at all, so the
      // case above is testing expiry rather than the presence of `exp`.
      expect(
        auth.authenticate(_token('alice', expires: DateTime.utc(2026, 1, 2))),
        equals('alice'),
      );
    });

    test('the distinction, as the one comparison it rests on', () {
      // Both tokens name a subject this authenticator knows. The only
      // difference is whether the envelope parses. An implementation that
      // folded `malformed` into `rejected` would answer the same for the two,
      // and every dashboard built on the tag would stop being able to tell a
      // broken client from a hostile one.
      late final BearerAuthFailure wellFormedButUnknown;
      late final BearerAuthFailure knownButUnparseable;
      try {
        auth.authenticate(_token('mallory'));
      } on BearerAuthFailure catch (f) {
        wellFormedButUnknown = f;
      }
      try {
        auth.authenticate(
          'v1.${base64Url.encode(utf8.encode('{"sub":"alice"}'))}',
        );
      } on BearerAuthFailure catch (f) {
        knownButUnparseable = f;
      }

      expect(wellFormedButUnknown.reason, BearerAuthFailureReason.rejected);
      expect(knownButUnparseable.reason, BearerAuthFailureReason.malformed);
      expect(
        wellFormedButUnknown.reason,
        isNot(knownButUnparseable.reason),
        reason: 'the two categories must stay distinguishable',
      );
    });

    test('every category the enum declares now has a producer', () {
      // The closed-set claim above counts the enum; this counts the reasons
      // an authenticator in this package can actually raise. A category
      // declared and never produced is the gap that made this group
      // necessary, so the two numbers are asserted to agree.
      final produced = <BearerAuthFailureReason>{};
      for (final token in <String>['', 'not-a-token', _token('mallory')]) {
        try {
          auth.authenticate(token);
        } on BearerAuthFailure catch (f) {
          produced.add(f.reason);
        }
      }
      expect(produced, equals(BearerAuthFailureReason.values.toSet()));
    });
  });
}

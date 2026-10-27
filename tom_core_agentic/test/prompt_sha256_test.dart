import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('promptSha256', () {
    test('formats as sha256:<lowercase-hex>', () {
      final h = promptSha256('hello');
      expect(h, startsWith('sha256:'));
      final hex = h.substring('sha256:'.length);
      expect(hex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('matches a hand-computed digest of the UTF-8 bytes', () {
      const body = 'the quick brown fox';
      final expected = 'sha256:${sha256.convert(utf8.encode(body))}';
      expect(promptSha256(body), expected);
    });

    test('is deterministic for the same input', () {
      expect(promptSha256('x'), promptSha256('x'));
    });

    test('differs for different input', () {
      expect(promptSha256('a'), isNot(promptSha256('b')));
    });

    test('hashes UTF-8 bytes, not code units (multi-byte input)', () {
      const body = 'café — 日本語';
      final expected = 'sha256:${sha256.convert(utf8.encode(body))}';
      expect(promptSha256(body), expected);
    });

    test('empty string hashes to the canonical empty-input digest', () {
      expect(
        promptSha256(''),
        'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });
}

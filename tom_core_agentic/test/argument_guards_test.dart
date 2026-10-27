import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('requireNonEmpty', () {
    test('returns the value unchanged when non-empty', () {
      expect(requireNonEmpty('abc', 'field'), 'abc');
    });

    test('throws ArgumentError naming the field when empty', () {
      expect(
        () => requireNonEmpty('', 'principalId'),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'principalId')
              .having((e) => e.message, 'message', 'must be non-empty'),
        ),
      );
    });

    test('treats a whitespace string as non-empty (length only)', () {
      expect(requireNonEmpty(' ', 'field'), ' ');
    });
  });
}

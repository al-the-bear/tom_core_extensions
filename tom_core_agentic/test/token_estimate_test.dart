import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('estimateTokens', () {
    test('empty string estimates to zero', () {
      expect(estimateTokens(''), 0);
    });

    test('rounds up partial tokens', () {
      expect(estimateTokens('a'), 1); // ceil(1/4)
      expect(estimateTokens('abcd'), 1); // ceil(4/4)
      expect(estimateTokens('abcde'), 2); // ceil(5/4)
    });

    test('scales with length using approxCharsPerToken', () {
      final text = 'x' * (approxCharsPerToken * 10);
      expect(estimateTokens(text), 10);
    });
  });
}

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('textPreview', () {
    test('returns the text unchanged when within the limit', () {
      expect(textPreview('hello', limit: 10), 'hello');
      expect(textPreview('exact', limit: 5), 'exact');
    });

    test('clips at limit and appends the default ellipsis', () {
      expect(textPreview('abcdef', limit: 3), 'abc…');
    });

    test('a clipped result has length limit + ellipsis.length', () {
      final out = textPreview('x' * 1000, limit: 512);
      expect(out.length, 512 + 1); // single-glyph default ellipsis
      expect(out.substring(0, 512), 'x' * 512);
      expect(out.endsWith('…'), isTrue);
    });

    test('honours a custom ASCII ellipsis', () {
      // Mirrors the router summary: keep 117 chars, append "...".
      final long = 'z' * 200;
      final out = textPreview(long, limit: 117, ellipsis: '...');
      expect(out, '${'z' * 117}...');
      expect(out.length, 120);
    });

    test('rejects a negative limit', () {
      expect(() => textPreview('x', limit: -1), throwsArgumentError);
    });

    test('limit zero yields only the ellipsis for non-empty input', () {
      expect(textPreview('anything', limit: 0), '…');
      expect(textPreview('', limit: 0), '');
    });
  });
}

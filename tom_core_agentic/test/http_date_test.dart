import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('HttpDate.parse', () {
    test('parses RFC 1123 format to UTC', () {
      final d = HttpDate.parse('Wed, 21 Oct 2026 07:28:00 GMT');
      expect(d, DateTime.utc(2026, 10, 21, 7, 28, 0));
      expect(d.isUtc, isTrue);
    });

    test('parses RFC 850 format (2-digit year, dash-separated)', () {
      final d = HttpDate.parse('Wednesday, 21-Oct-26 07:28:00 GMT');
      expect(d, DateTime.utc(2026, 10, 21, 7, 28, 0));
    });

    test('parses asctime format', () {
      final d = HttpDate.parse('Wed Oct 21 07:28:00 2026');
      expect(d, DateTime.utc(2026, 10, 21, 7, 28, 0));
    });

    test('tolerates surrounding whitespace', () {
      final d = HttpDate.parse('  Wed, 21 Oct 2026 07:28:00 GMT  ');
      expect(d, DateTime.utc(2026, 10, 21, 7, 28, 0));
    });

    test('throws FormatException on an unknown month', () {
      expect(
        () => HttpDate.parse('Wed, 21 Zzz 2026 07:28:00 GMT'),
        throwsFormatException,
      );
    });

    test('throws FormatException on a malformed date', () {
      expect(() => HttpDate.parse('not-a-date'), throwsFormatException);
    });

    // Rejection-path hardening. The accept path is the easy half; the two ways
    // a parser gets the *rejection* path wrong are both silent. A truncated
    // month token reaches `substring(0, 3)`, which raises a low-level
    // RangeError rather than a FormatException — so a caller catching
    // FormatException does not catch it. And `DateTime.utc` normalises
    // out-of-range day/time fields instead of rejecting them, so a malformed
    // header parses to a plausible-but-wrong instant and nothing throws at all.
    group('rejection-path hardening', () {
      test('a truncated month token throws FormatException, not RangeError', () {
        // `Oc` is < 3 chars: an unguarded `substring(0, 3)` raises RangeError.
        expect(
          () => HttpDate.parse('Wed, 21 Oc 2026 07:28:00 GMT'),
          throwsFormatException,
        );
      });

      test('an out-of-range day is rejected, not normalised', () {
        // Day 32 would silently roll into the next month via DateTime.utc.
        expect(
          () => HttpDate.parse('Wed, 32 Oct 2026 07:28:00 GMT'),
          throwsFormatException,
        );
      });

      test('an out-of-range hour is rejected', () {
        expect(
          () => HttpDate.parse('Wed, 21 Oct 2026 25:28:00 GMT'),
          throwsFormatException,
        );
      });

      test('an out-of-range minute is rejected', () {
        expect(
          () => HttpDate.parse('Wed, 21 Oct 2026 07:61:00 GMT'),
          throwsFormatException,
        );
      });

      test('an out-of-range second is rejected', () {
        expect(
          () => HttpDate.parse('Wed, 21 Oct 2026 07:28:99 GMT'),
          throwsFormatException,
        );
      });

      test('a leap second (60) is still accepted', () {
        final d = HttpDate.parse('Wed, 31 Dec 2025 23:59:60 GMT');
        expect(d.isUtc, isTrue);
      });

      test('asctime with an out-of-range field is rejected', () {
        expect(
          () => HttpDate.parse('Wed Oct 32 07:28:00 2026'),
          throwsFormatException,
        );
      });
    });
  });
}

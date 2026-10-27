import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('startOfDay', () {
    test('truncates a UTC instant to UTC midnight', () {
      final t = DateTime.utc(2026, 6, 3, 14, 30, 15, 500);
      final start = startOfDay(t);
      expect(start, DateTime.utc(2026, 6, 3));
      expect(start.isUtc, isTrue);
    });

    test('truncates a local instant to local midnight', () {
      final t = DateTime(2026, 6, 3, 14, 30);
      final start = startOfDay(t);
      expect(start, DateTime(2026, 6, 3));
      expect(start.isUtc, isFalse);
    });
  });

  group('nextDayStart', () {
    test('returns the start of the following day', () {
      expect(
        nextDayStart(DateTime.utc(2026, 6, 3, 23, 59)),
        DateTime.utc(2026, 6, 4),
      );
    });

    test('normalises month rollover', () {
      expect(
        nextDayStart(DateTime.utc(2026, 1, 31, 12)),
        DateTime.utc(2026, 2, 1),
      );
    });

    test('normalises year rollover', () {
      expect(
        nextDayStart(DateTime.utc(2026, 12, 31, 12)),
        DateTime.utc(2027, 1, 1),
      );
    });

    test('the wait until the boundary is positive within a day', () {
      final now = DateTime.utc(2026, 6, 3, 10);
      expect(nextDayStart(now).difference(now), const Duration(hours: 14));
    });
  });
}

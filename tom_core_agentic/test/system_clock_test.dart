import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('systemClock', () {
    test('returns a current DateTime', () {
      final before = DateTime.now();
      final now = systemClock();
      final after = DateTime.now();
      expect(now.isBefore(before), isFalse);
      expect(now.isAfter(after), isFalse);
    });

    test('is usable as an injectable-clock default', () {
      DateTime Function() resolve([DateTime Function()? clock]) =>
          clock ?? systemClock;
      DateTime fixed() => DateTime.utc(2026, 1, 1);
      expect(resolve(fixed)(), DateTime.utc(2026, 1, 1));
      expect(resolve()(), isA<DateTime>());
    });
  });
}

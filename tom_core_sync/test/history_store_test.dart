import 'package:test/test.dart';
import 'package:tom_core_storage/tom_core_storage.dart';
import 'package:tom_core_sync/tom_core_sync.dart';

TomMediumHistoryStore storeIn(TomMemoryBundleMedium medium, String stamp) =>
    TomMediumHistoryStore(
      medium: medium,
      stamp: stamp,
      extension: '.yaml',
      exclude: (path) => path.startsWith('.history/.assets/'),
    );

void main() {
  group('HISTORY: a file-medium history store', () {
    test('HISTORY-1: a version lands at <dir>/<id>/<stamp><ext>, a second in '
        'the same save is disambiguated, and versions read back oldest '
        'first', () async {
      final medium = TomMemoryBundleMedium();
      final store = storeIn(medium, '20260101T120000000');
      final first = await store.retain('a', 'one');
      final second = await store.retain('a', 'two');
      expect(first, '.history/a/20260101T120000000.yaml');
      expect(second, '.history/a/20260101T120000000_1.yaml');
      expect(await store.versionsOf('a'), [first, second]);
      expect(await store.read('a', second), 'two');
      expect(await store.holds('a', first), isTrue);
      expect(
        await store.holds('b', first),
        isFalse,
        reason: 'a locator names a version of one record only',
      );
      expect(await store.read('a', '.history/a/gone.yaml'), isNull);
    });

    test('HISTORY-2: pruning keeps the newest versions of every record, a '
        'deleted one included, and moves nothing', () async {
      final medium = TomMemoryBundleMedium();
      for (var i = 0; i < 5; i++) {
        await storeIn(medium, '2026010${i}T000000000').retain('a', 'v$i');
        await storeIn(medium, '2026010${i}T000000000').retain('gone', 'g$i');
      }
      final moved = await storeIn(medium, 'x').prune(depth: 2);
      expect(moved, isEmpty);
      expect(await storeIn(medium, 'x').versionsOf('a'), [
        '.history/a/20260103T000000000.yaml',
        '.history/a/20260104T000000000.yaml',
      ]);
      expect(await storeIn(medium, 'x').versionsOf('gone'), hasLength(2));
    });

    test('HISTORY-3: a protected version survives below the depth', () async {
      final medium = TomMemoryBundleMedium();
      final paths = [
        for (var i = 0; i < 4; i++)
          await storeIn(medium, '2026010${i}T000000000').retain('a', 'v$i'),
      ];
      await storeIn(medium, 'x').prune(depth: 1, protected: {'a': paths[0]});
      expect(await storeIn(medium, 'x').versionsOf('a'), [paths[0], paths[3]]);
    });

    test(
      'HISTORY-4: excluded paths and a negative depth are left alone',
      () async {
        final medium = TomMemoryBundleMedium();
        for (var i = 0; i < 3; i++) {
          await medium.writeString('.history/.assets/img$i.png', 'x');
          await storeIn(medium, '2026010${i}T000000000').retain('a', 'v$i');
        }
        await storeIn(medium, 'x').prune(depth: -1);
        expect(await storeIn(medium, 'x').versionsOf('a'), hasLength(3));
        await storeIn(medium, 'x').prune(depth: 1);
        expect(await storeIn(medium, 'x').versionsOf('a'), hasLength(1));
        expect(
          (await medium.listFiles()).where(
            (p) => p.startsWith('.history/.assets/'),
          ),
          hasLength(3),
        );
      },
    );

    test('HISTORY-5: the stamp sorts chronologically and is UTC', () {
      final early = tomHistoryStamp(DateTime.utc(2026, 1, 2, 3, 4, 5, 6));
      final late = tomHistoryStamp(DateTime.utc(2026, 11, 2, 3, 4, 5, 6));
      expect(early, '20260102T030405006');
      expect(early.compareTo(late), lessThan(0));
      expect(
        tomHistoryStamp(DateTime.utc(2026, 1, 2).toLocal()),
        tomHistoryStamp(DateTime.utc(2026, 1, 2)),
      );
      expect(tomHistoryDepth, 20);
    });
  });
}

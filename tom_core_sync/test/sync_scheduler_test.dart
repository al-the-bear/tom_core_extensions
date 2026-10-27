import 'package:test/test.dart';
import 'package:tom_core_storage/tom_core_storage.dart';
import 'package:tom_core_sync/tom_core_sync.dart';

import 'support/notes.dart';

class Policy implements TomSyncPolicy {
  @override
  final bool enabled;
  final Set<String> only;
  final Map<String, TomSyncDirection> directions;

  const Policy({
    this.enabled = true,
    this.only = const {},
    this.directions = const {},
  });

  @override
  Duration get pollInterval => const Duration(seconds: 300);

  @override
  TomBackoffPolicy get backoff => TomBackoffPolicy.defaults;

  @override
  bool syncsLocator(String locator) => only.isEmpty || only.contains(locator);

  @override
  TomSyncDirection directionFor(String locator) =>
      directions[locator] ?? TomSyncDirection.twoWay;
}

class Retry implements TomSyncRetry {
  @override
  final String key = 'folder';
  @override
  bool hasPending = true;
  @override
  DateTime? notBefore;
  int retries = 0;
  TomBackoffPolicy? adopted;

  @override
  Future<void> retry() async => retries++;

  @override
  void adoptBackoff(TomBackoffPolicy policy) => adopted = policy;
}

DateTime now = at(0);

Future<(TomSyncScheduler, List<NotesUnit>)> workspace(
  FakeStorage storage,
  int count, {
  TomSyncPolicy policy = const Policy(),
}) async {
  final scheduler = TomSyncScheduler(policy: policy, clock: () => now);
  final units = <NotesUnit>[];
  for (var i = 0; i < count; i++) {
    final unit = NotesUnit('${storage.prefix}/n$i.json', storage);
    final engine = TomSyncEngine(unit: unit, journal: TomMemoryCommitJournal());
    await engine.syncNow();
    scheduler.add(engine);
    units.add(unit);
  }
  return (scheduler, units);
}

void main() {
  setUp(() => now = at(0));

  group('SCHEDULER: one clock and one head read', () {
    test('SCHEDULER-1: a tick asks each backend once, and cycles only the '
        'units that moved', () async {
      final storage = FakeStorage();
      final (scheduler, units) = await workspace(storage, 5);
      final commits = storage.commits;
      storage.seed(
        units[2].locator,
        encodeNotes(notes([const Note('x', 'y')])),
      );
      await scheduler.tick();
      expect(storage.headsOfCalls, 1);
      expect(units[2].working['x']!.text, 'y');
      expect(storage.commits, commits, reason: 'no unit had local work');
      await scheduler.dispose();
    });

    test('SCHEDULER-2: a refused backend waits alone; the others carry on, '
        'and the line reports the latest wait', () async {
      final quiet = FakeStorage(prefix: 'a:');
      final busy = FakeStorage(prefix: 'b:');
      final (scheduler, _) = await workspace(quiet, 1);
      final (other, units) = await workspace(busy, 1);
      for (final engine in other.engines.toList()) {
        await other.remove(engine.locator);
        scheduler.add(engine);
      }
      quiet.failReads = TomRateLimitException(
        'a:',
        kind: TomRateLimitKind.quota,
        resetAt: at(20),
      );
      busy.seed(
        units.single.locator,
        encodeNotes(notes([const Note('k', 'v')])),
      );
      await scheduler.tick();
      expect(units.single.working['k']!.text, 'v');
      expect(scheduler.deferredUntil, at(20));
      expect(scheduler.deferralFor('a:/n0.json')?.kind, TomRateLimitKind.quota);
      expect(scheduler.manualSyncAsks('a:/n0.json'), isFalse);
      expect(
        scheduler.engineFor('a:/n0.json')!.status.rateLimitedUntil,
        at(20),
      );
      await scheduler.dispose();
      await other.dispose();
    });

    test('SCHEDULER-3: a disabled policy arms no timer, and a manual sync '
        'still works', () async {
      final storage = FakeStorage();
      final (scheduler, units) = await workspace(
        storage,
        1,
        policy: const Policy(enabled: false),
      );
      scheduler.start();
      expect(scheduler.isRunning, isTrue);
      expect(scheduler.isPolling, isFalse);
      units.single.put(const Note('a', 'by hand'));
      await scheduler.syncAll();
      expect(
        decodeNotes(storage.files[units.single.locator]!)['a']!.text,
        'by hand',
      );
      scheduler.applyPolicy(const Policy());
      expect(scheduler.isPolling, isTrue);
      await scheduler.dispose();
    });

    test('SCHEDULER-4: a retry member is tried on a tick when it has work, '
        'and its wait holds the timer but not a manual sync', () async {
      final storage = FakeStorage();
      final (scheduler, _) = await workspace(storage, 1);
      final member = Retry()..notBefore = at(10);
      scheduler.addRetry(member);
      expect(member.adopted, TomBackoffPolicy.defaults);
      await scheduler.tick();
      expect(member.retries, 0);
      await scheduler.syncAll();
      expect(member.retries, 1);
      now = at(11);
      await scheduler.tick();
      expect(member.retries, 2);
      scheduler.removeRetry('folder');
      expect(scheduler.retries, isEmpty);
      await scheduler.dispose();
    });

    test('SCHEDULER-5: the policy decides which units a tick touches and '
        'which half of a cycle each runs', () async {
      final storage = FakeStorage();
      final (scheduler, units) = await workspace(
        storage,
        2,
        policy: Policy(
          only: {'mem:/n0.json'},
          directions: {'mem:/n0.json': TomSyncDirection.pullOnly},
        ),
      );
      expect(
        scheduler.engineFor('mem:/n0.json')!.direction,
        TomSyncDirection.pullOnly,
      );
      expect(storage.adopted, TomBackoffPolicy.defaults);
      units[1].put(const Note('a', 'not on the timer'));
      units[0].put(const Note('a', 'pull only'));
      final commits = storage.commits;
      await scheduler.tick();
      expect(storage.commits, commits);
      await scheduler.dispose();
    });

    test('SCHEDULER-6: an unreachable batch reaches every quiet unit, and an '
        'answered one retires it', () async {
      final storage = FakeStorage();
      final (scheduler, _) = await workspace(storage, 2);
      storage.failReads = TomUnreachableException('mem:', 'dark');
      await scheduler.tick();
      expect(scheduler.engines.every((e) => e.status.offline), isTrue);
      storage.failReads = null;
      await scheduler.tick();
      expect(scheduler.engines.any((e) => e.status.offline), isFalse);
      await scheduler.dispose();
    });
  });
}

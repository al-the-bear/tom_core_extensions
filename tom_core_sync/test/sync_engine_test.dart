import 'package:test/test.dart';
import 'package:tom_basics/diagnostics.dart';
import 'package:tom_core_storage/tom_core_storage.dart';
import 'package:tom_core_sync/tom_core_sync.dart';

import 'support/notes.dart';

const loc = 'mem:/notes.json';

({
  FakeStorage storage,
  NotesUnit unit,
  TomSyncEngine engine,
  TomCommitJournal journal,
})
rig({List<String>? heads, TomDiagnostics? diagnostics}) {
  final storage = FakeStorage(headNames: heads);
  final unit = NotesUnit(loc, storage);
  final journal = TomMemoryCommitJournal();
  final engine = TomSyncEngine(
    unit: unit,
    journal: journal,
    diagnostics: diagnostics ?? const TomNullDiagnostics(),
    clock: () => at(30),
  );
  return (storage: storage, unit: unit, engine: engine, journal: journal);
}

void main() {
  group('ENGINE: one unit converged with its remote', () {
    test('ENGINE-1: a unit never committed is dirty and its first cycle '
        'publishes it', () async {
      final r = rig();
      expect(r.engine.state, TomSyncState.dirty);
      expect(r.engine.needsCycle(null), isTrue);
      final status = await r.engine.syncNow();
      expect(status.state, TomSyncState.clean);
      expect(r.storage.commits, 1);
      expect(r.unit.head, isNotNull);
      expect(status.lastSyncedAt, at(30));
    });

    test('ENGINE-2: edits move the state at once, and coalesce into one '
        'push of the final copy', () async {
      final r = rig();
      await r.engine.syncNow();
      for (var i = 0; i < 10; i++) {
        r.unit.put(Note('a', 'v$i'));
        expect(
          r.engine.state,
          TomSyncState.dirty,
          reason: 'the relay is synchronous',
        );
      }
      await r.engine.syncNow();
      expect(r.storage.commits, 2);
      expect(decodeNotes(r.storage.files[loc]!)['a']!.text, 'v9');
    });

    test('ENGINE-3: a remote change is pulled and merged; the unit stays '
        'clean', () async {
      final r = rig();
      await r.engine.syncNow();
      r.storage.seed(loc, encodeNotes(notes([const Note('b', 'theirs')])));
      expect(r.engine.needsCycle(r.storage.heads[loc]), isTrue);
      final status = await r.engine.syncNow();
      expect(status.state, TomSyncState.clean);
      expect(r.unit.working['b']!.text, 'theirs');
      expect(r.storage.commits, 1, reason: 'nothing local to push');
    });

    test('ENGINE-4: a two-sided divergence flags the unit conflicted until '
        'its conflicts are cleared', () async {
      final r = rig();
      r.unit.put(Note('a', 'base', at(0)));
      await r.engine.syncNow();
      r.unit.put(Note('a', 'mine', at(1)));
      r.storage.seed(loc, encodeNotes(notes([Note('a', 'theirs', at(2))])));
      final status = await r.engine.syncNow();
      expect(status.state, TomSyncState.conflicted);
      expect(status.conflicts.single.anchor, 'a');
      r.engine.clearConflict('a');
      expect(r.engine.state, TomSyncState.clean);
    });

    test('ENGINE-5: a commit the transport refuses is journaled and '
        'delivered by a later cycle', () async {
      final r = rig();
      await r.engine.syncNow();
      r.unit.put(const Note('a', 'offline'));
      r.storage.failCommits = TomUnreachableException(loc, 'down');
      final offline = await r.engine.syncNow();
      expect(offline.offline, isTrue);
      expect(offline.pendingCount, 1);
      expect(offline.state, TomSyncState.dirty);

      r.storage.failCommits = null;
      final back = await r.engine.syncNow();
      expect(back.offline, isFalse);
      expect(back.pendingCount, 0);
      expect(back.state, TomSyncState.clean);
      expect(decodeNotes(r.storage.files[loc]!)['a']!.text, 'offline');
    });

    test('ENGINE-6: a quota refusal is a wait, not an outage', () async {
      final r = rig();
      await r.engine.syncNow();
      r.storage.seed(loc, encodeNotes(const {}));
      r.storage.failReads = TomRateLimitException(
        loc,
        kind: TomRateLimitKind.quota,
        resetAt: at(45),
      );
      final status = await r.engine.syncNow();
      expect(status.offline, isFalse);
      expect(status.rateLimitedUntil, at(45));
      expect(status.rateLimitKind, TomRateLimitKind.quota);
    });

    test('ENGINE-7: a locked container blocks the automatic loop until a key '
        'arrives, and supplying it cycles at once', () async {
      final r = rig();
      await r.engine.syncNow();
      r.storage.seed(loc, encodeNotes(const {}));
      r.unit.keyRequired = TomKeyRequiredException(loc, 'No key opens it.');
      final locked = await r.engine.syncNow();
      expect(locked.needsKey, isTrue);
      expect(locked.keyRequiredReason, 'No key opens it.');
      expect(r.engine.needsCycle('anything'), isFalse);
      r.unit.keyRequired = null;
      final open = await r.engine.keySupplied();
      expect(open.needsKey, isFalse);
    });

    test('ENGINE-8: a head is compared for equality only — heads whose order '
        'runs backwards still pull', () async {
      final r = rig(heads: ['z9', 'm5', 'a1']);
      await r.engine.syncNow();
      r.storage.seed(loc, encodeNotes(notes([const Note('n', 'one')])));
      await r.engine.syncNow();
      r.storage.seed(loc, encodeNotes(notes([const Note('n', 'two')])));
      expect(r.engine.needsCycle(r.storage.heads[loc]), isTrue);
      await r.engine.syncNow();
      expect(r.unit.working['n']!.text, 'two');
    });

    test(
      'ENGINE-9: every cycle is one sync.cycle event with its outcome',
      () async {
        final log = TomInMemoryDiagnostics();
        final r = rig(diagnostics: log);
        await r.engine.syncNow();
        r.unit.put(const Note('a', 'x'));
        r.storage.failCommits = TomUnreachableException(loc, 'down');
        await r.engine.syncNow();
        final outcomes = [
          for (final e in log.events)
            if (e.operation == 'sync.cycle') e.fields['outcome'],
        ];
        expect(outcomes, ['synced', 'journaled']);
      },
    );

    test('ENGINE-10: conflicts found outside the loop join its queue, and one '
        'can be retired by identity', () async {
      final r = rig();
      await r.engine.syncNow();
      final first = TomConflictRecord<Note>(key: 'a');
      final second = TomConflictRecord<Note>(key: 'a');
      r.engine.recordConflicts([first, second]);
      expect(r.engine.state, TomSyncState.conflicted);
      r.engine.clearConflictRecord(first);
      expect(r.engine.conflicts, [same(second)]);
      r.engine.clearConflicts();
      expect(r.engine.state, TomSyncState.clean);
    });

    test('ENGINE-11: the poll interval has a floor, and dispose releases the '
        'unit', () async {
      final r = rig();
      final fast = TomSyncEngine(
        unit: NotesUnit('mem:/other', r.storage),
        journal: TomMemoryCommitJournal(),
        pollInterval: const Duration(seconds: 5),
      );
      expect(fast.pollInterval, TomSyncEngine.minPollInterval);
      await r.engine.dispose();
      expect(r.unit.disposed, isTrue);
      await fast.dispose();
    });

    test('ENGINE-12: the batch outcome reaches a quiet unit', () async {
      final r = rig();
      await r.engine.syncNow();
      r.engine.recordUnreachable(StateError('dark'));
      expect(r.engine.status.offline, isTrue);
      r.engine.recordHeadsAnswered();
      expect(r.engine.status.offline, isFalse);
      r.engine.recordRateLimit(
        TomRateLimitException(loc, kind: TomRateLimitKind.throttle),
      );
      expect(
        r.engine.status.rateLimitedUntil,
        at(30).add(r.engine.pollInterval),
        reason: 'a refusal stating no instant waits one poll interval',
      );
    });
  });
}

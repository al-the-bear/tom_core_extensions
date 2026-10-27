import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_tools.dart';

final class _MapStore implements AgentAuditStore {
  final Map<String, String> files = {};

  @override
  Future<List<String>> listFiles() async => files.keys.toList()..sort();

  @override
  Future<String> readString(String key) async => files[key]!;

  @override
  Future<void> writeString(String key, String value) async =>
      files[key] = value;

  @override
  Future<void> delete(String key) async => files.remove(key);
}

AgentAuditEntry _entry(DateTime at, {String op = 'read'}) => AgentAuditEntry(
  op: op,
  targetId: 'a',
  locator: 'store',
  entry: AgentAuditEntryPoint.agent,
  scopeId: 'inv',
  allowed: true,
  appliedAt: at,
  toolName: 'read_note',
  outcome: AgentAuditOutcome.applied,
);

void main() {
  final now = DateTime.utc(2026, 10, 21, 12);

  group('the entry', () {
    test('round-trips through its map, and its map has no field that could '
        'hold content', () {
      final entry = AgentAuditEntry(
        opId: 7,
        op: 'update',
        targetId: 'a',
        locator: 'store',
        entry: AgentAuditEntryPoint.mcp,
        scopeId: 'inv',
        allowed: false,
        denyReason: 'read-only',
        gate: 2,
        appliedAt: now,
        toolName: 'write_note',
        programId: 'p',
        programSha256: 'abc',
        outcome: AgentAuditOutcome.denied,
        mutationCount: 3,
        logBytes: 9,
      );
      final map = entry.toMap();
      expect(
        AgentAuditEntry.fromMap(jsonDecode(jsonEncode(map)) as Map).toMap(),
        map,
      );
      expect(map.keys.toSet(), {
        'opId',
        'op',
        'targetId',
        'locator',
        'entry',
        'scopeId',
        'allowed',
        'denyReason',
        'gate',
        'undoRef',
        'appliedAt',
        'toolName',
        'programId',
        'programSha256',
        'outcome',
        'mutationCount',
        'logBytes',
      });
    });

    test('only an applied mutation can be rolled back', () {
      final read = _entry(now);
      expect(identical(read.asRolledBack(), read), isTrue);
      final mutation = AgentAuditEntry(
        op: 'update',
        targetId: 'a',
        entry: AgentAuditEntryPoint.agent,
        scopeId: 'inv',
        allowed: true,
        undoRef: 4,
        appliedAt: now,
        toolName: 'write_note',
        outcome: AgentAuditOutcome.applied,
      );
      final reversed = mutation.asRolledBack();
      expect(reversed.outcome, AgentAuditOutcome.rolledBack);
      expect(reversed.undoRef, -1);
    });

    test('the viewer filters by invocation, resource and outcome', () {
      final entries = [
        _entry(now),
        AgentAuditEntry(
          op: 'x',
          targetId: null,
          locator: 'other',
          entry: AgentAuditEntryPoint.agent,
          scopeId: 'inv2',
          allowed: false,
          denyReason: 'r',
          appliedAt: now,
          toolName: 't',
          outcome: AgentAuditOutcome.denied,
        ),
      ];
      expect(agentFilterAudit(entries, scopeId: 'inv2'), [entries[1]]);
      expect(agentFilterAudit(entries, locator: 'store'), [entries[0]]);
      expect(agentFilterAudit(entries, outcome: AgentAuditOutcome.denied), [
        entries[1],
      ]);
    });

    test('an unknown entry point or outcome does not parse', () {
      expect(() => AgentAuditEntryPoint.parse('ws'), throwsFormatException);
      expect(() => AgentAuditOutcome.parse('done'), throwsFormatException);
    });
  });

  group('the log', () {
    test('appends in order, numbers after what it holds, and announces each '
        'batch synchronously', () {
      final log = AgentMemoryAuditLog(clock: () => now);
      final seen = <int>[];
      log.appended.listen(
        (batch) => seen.addAll([for (final e in batch) e.opId]),
      );
      log.append([_entry(now), _entry(now)]);
      log.append([_entry(now)]);
      expect([for (final e in log.entries) e.opId], [1, 2, 3]);
      expect(seen, [1, 2, 3]);
      expect(log.append(const []), isEmpty);
    });

    test(
      'drops what retention no longer covers, and adopts a new retention',
      () {
        final log = AgentMemoryAuditLog(clock: () => now);
        log.append([
          _entry(now.subtract(const Duration(days: 100))),
          _entry(now.subtract(const Duration(days: 10))),
        ]);
        expect(log.entries, hasLength(1));
        log.applyRetention(const Duration(days: 5));
        expect(log.entries, isEmpty);
      },
    );
  });

  group('the file log', () {
    test('writes one file per batch under its UTC day and reads them back, '
        'numbering on', () async {
      final store = _MapStore();
      final log = await AgentFileAuditLog.open(store, clock: () => now);
      log.append([_entry(now)]);
      log.append([_entry(now), _entry(now)]);
      await log.flush();
      expect(store.files.keys, hasLength(2));
      expect(store.files.keys, everyElement(startsWith('2026-10-21/')));
      final body = jsonDecode(store.files.values.first) as Map;
      expect(body['version'], AgentFileAuditLog.formatVersion);

      final reopened = await AgentFileAuditLog.open(store, clock: () => now);
      expect([for (final e in reopened.entries) e.opId], [1, 2, 3]);
      reopened.append([_entry(now)]);
      expect(reopened.entries.last.opId, 4);
      await reopened.dispose();
    });

    test('skips a torn file and a file of another format rather than '
        'refusing to open', () async {
      final store = _MapStore()
        ..files['2026-10-21/a.json'] = '{not json'
        ..files['2026-10-21/b.json'] = jsonEncode({
          'version': 99,
          'entries': [_entry(now).toMap()],
        })
        ..files['2026-10-21/c.json'] = jsonEncode({
          'version': AgentFileAuditLog.formatVersion,
          'entries': [(_entry(now).toMap()..['opId'] = 5)],
        });
      final log = await AgentFileAuditLog.open(store, clock: () => now);
      expect([for (final e in log.entries) e.opId], [5]);
    });

    test('deletes whole days past retention, on open and when retention '
        'narrows', () async {
      final store = _MapStore()
        ..files['2026-01-01/old.json'] = '{}'
        ..files['2026-10-20/recent.json'] = '{}';
      final log = await AgentFileAuditLog.open(store, clock: () => now);
      expect(store.files.keys, ['2026-10-20/recent.json']);
      log.applyRetention(const Duration(hours: 1));
      await log.flush();
      expect(store.files, isEmpty);
    });
  });
}

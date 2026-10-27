import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_tools.dart';

import 'support/notes.dart';

void main() {
  Future<Object?> invoke(NotesContext c, String name, Map<String, Object?> a) =>
      Future.sync(() => notesTools.invoke(c, name, a));

  group('a tool call', () {
    test(
      'validates before the body runs, and the refusal is recorded',
      () async {
        final c = notesContext();
        await expectLater(
          invoke(c, 'write_note', {'noteId': 'a', 'txt': 'x'}),
          throwsA(
            isA<AgentToolException>().having(
              (e) => e.argument,
              'argument',
              'txt',
            ),
          ),
        );
        expect(c.store.notes['a']!.text, 'alpha');
        final entry = c.audit.entries.single;
        expect(entry.outcome, AgentAuditOutcome.denied);
        expect(entry.denyReason, 'invalid-argument');
        expect(entry.toolName, 'write_note');
        expect(entry.targetId, 'a');
        expect(entry.scopeId, c.invocation.invocationId);
      },
    );

    test('a read is one applied entry; a write is one entry per mutation, '
        'numbered along the undo chain', () async {
      final c = notesContext();
      expect(await invoke(c, 'read_note', {'noteId': 'a'}), {'text': 'alpha'});
      await invoke(c, 'write_note', {'noteId': 'b', 'text': 'B'});
      await invoke(c, 'write_note', {'noteId': 'a', 'text': 'A'});
      final entries = c.audit.entries;
      expect(
        [for (final e in entries) e.op],
        ['read_note', 'update', 'update'],
      );
      expect([for (final e in entries) e.undoRef], [-1, 0, 1]);
      expect([for (final e in entries) e.opId], [1, 2, 3]);
      expect(entries[1].targetId, 'b');
    });

    test('the declared write drives the write gate: a read-only scope '
        'refuses the write tool and serves the read tool', () async {
      final c = notesContext(scope: AgentScope(allowWrite: false));
      expect(await invoke(c, 'read_note', {'noteId': 'a'}), {'text': 'alpha'});
      await expectLater(
        invoke(c, 'write_note', {'noteId': 'a', 'text': 'x'}),
        throwsA(
          isA<AgentToolException>().having(
            (e) => e.code,
            'code',
            AgentToolErrorCode.readOnly,
          ),
        ),
      );
      final denied = c.audit.entries.last;
      expect(denied.gate, 2);
      expect(denied.denyReason, 'read-only');
    });

    test('an excluded target is "not found" to the caller and its true '
        'reason to the trail', () async {
      final c = notesContext();
      Object? caught;
      try {
        await invoke(c, 'read_note', {'noteId': 's'});
      } on AgentToolException catch (e) {
        caught = e;
      }
      final e = caught! as AgentToolException;
      expect(e.toMap(), {'code': 'E_NOT_FOUND', 'message': 'No such note.'});
      expect(c.audit.entries.last.denyReason, 'secret-excluded');
      expect(c.audit.entries.last.gate, 1);
    });

    test('a defect in a body is recorded as failed, not denied', () async {
      final c = notesContext();
      await expectLater(invoke(c, 'broken_note', {}), throwsStateError);
      expect(c.audit.entries.single.outcome, AgentAuditOutcome.failed);
      expect(c.audit.entries.single.allowed, isTrue);
    });

    test('a call that declares its writes one group marks them rolled back '
        'when it fails', () async {
      final c = notesContext();
      final tool = AgentTool<NotesContext>(
        name: 'two_writes',
        summary: '',
        result: '',
        isWrite: true,
        invoke: (context, _) {
          agentAuditCallIsOneGroup();
          context.store.write('update', 'a', () {});
          throw const AgentToolException(
            AgentToolErrorCode.transactionFailed,
            'Step 2 failed.',
            step: 2,
          );
        },
      );
      await expectLater(
        Future.sync(() => tool.call(c, {})),
        throwsA(isA<AgentToolException>()),
      );
      expect(
        [for (final e in c.audit.entries) e.outcome],
        [AgentAuditOutcome.rolledBack, AgentAuditOutcome.failed],
      );
      expect(c.audit.entries.first.undoRef, -1);
    });

    test('a program run is framed: the run, its mutations, its terminal '
        'outcome with sizes — never its output', () async {
      final c = notesContext(execution: true);
      await invoke(c, 'run_note', {'noteId': 'a'});
      final entries = c.audit.entries;
      expect(
        [for (final e in entries) e.op],
        ['run_note', 'update', 'run_note'],
      );
      expect(entries.first.programId, 'a');
      expect(entries.last.programSha256, 'abc');
      expect(entries.last.mutationCount, 1);
      expect(entries.last.logBytes, 3);
    });

    test('the resource a call resolved is recorded, from its argument or '
        'from agentAuditResolved', () async {
      final c = notesContext();
      final tool = AgentTool<NotesContext>(
        name: 'resolve',
        summary: '',
        result: '',
        invoke: (context, _) {
          agentAuditResolved('store-1');
          return null;
        },
      );
      await Future.sync(() => tool.call(c, {}));
      expect(c.audit.entries.single.locator, 'store-1');
    });

    test('outside a call the reporting functions do nothing, and a guard '
        'outside a call is asked as a write', () {
      agentAuditExecutionStarted();
      agentAuditResolved('x');
      agentAuditCallIsOneGroup();
      expect(AgentAuditRecording.current, isNull);
      expect(AgentToolContext.callWrites, isTrue);
      final c = notesContext(scope: AgentScope(allowWrite: false));
      expect(
        c.guard(const AgentGuardTarget(id: 'a', kind: 'plain')),
        AgentScopeGate.write,
      );
      expect(c.shows(const AgentGuardTarget(id: 'a', kind: 'plain')), isTrue);
    });
  });

  group('the registry', () {
    test('an unknown tool is refused like a typo, and the refusal recorded '
        'under a bounded name', () async {
      final c = notesContext();
      final long = 'x' * 100;
      await expectLater(
        invoke(c, long, {}),
        throwsA(
          isA<AgentToolException>().having(
            (e) => e.argument,
            'argument',
            'name',
          ),
        ),
      );
      expect(c.audit.entries.single.toolName, '${'x' * 64}…');
      expect(c.audit.entries.single.outcome, AgentAuditOutcome.denied);
    });

    test('a derived set can only remove: the program-free set holds no tool '
        'that needs execution, and refuses one as unknown', () async {
      final noPrograms = notesTools.where((t) => !t.needsExecution);
      expect(noPrograms.names, isNot(contains('run_note')));
      expect(noPrograms.names, everyElement(isIn(notesTools.names)));
      final c = notesContext(execution: true);
      await expectLater(
        Future.sync(() => noPrograms.invoke(c, 'run_note', {'noteId': 'a'})),
        throwsA(
          isA<AgentToolException>().having(
            (e) => e.code,
            'code',
            AgentToolErrorCode.invalidArgument,
          ),
        ),
      );
      expect(c.store.notes['a']!.text, 'alpha');
    });

    test('a tool renders as an MCP tools/list entry', () {
      expect(readNote.toJsonSchema(), {
        'name': 'read_note',
        'description': 'Read a note.',
        'inputSchema': readNote.arguments.toJsonSchema(),
      });
    });
  });
}

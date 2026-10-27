import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_tools.dart';

import 'support/notes.dart';

AgentToolBinding<NotesContext> _bind(NotesContext context) =>
    AgentToolBinding(context: context, registry: notesTools);

void main() {
  group('the binding', () {
    test('declares every tool of its registry, in both shapes', () {
      final binding = _bind(notesContext());
      expect([for (final d in binding.declarations) d.name], notesTools.names);
      final native = binding.nativeDeclarations();
      expect(native.first, {
        'name': 'read_note',
        'description': 'Read a note.',
        'input_schema': readNote.arguments.toJsonSchema(),
      });
    });

    test('a refusal is an answer, and every later call is refused as part '
        'of a run that will roll back', () async {
      final c = notesContext();
      final binding = _bind(c);
      final refused = await binding.call('read_note', {'noteId': 's'});
      expect(refused.isError, isTrue);
      expect(jsonDecode(refused.text), {
        'code': 'E_NOT_FOUND',
        'message': 'No such note.',
      });
      final later = await binding.dispatch('write_note', {
        'noteId': 'a',
        'text': 'x',
      });
      expect(later.isError, isTrue);
      expect((later.value! as Map)['code'], 'E_TRANSACTION_FAILED');
      expect(c.store.notes['a']!.text, 'alpha');
      expect(binding.failure!.index, 1);
      expect([for (final s in binding.steps) s.ok], [false, false]);
      expect(c.audit.entries, hasLength(2), reason: 'both refusals recorded');
    });

    test(
      'a defect answers "the call failed" and nothing of its text',
      () async {
        final answer = await _bind(notesContext()).call('broken_note', {});
        expect(answer.isError, isTrue);
        expect(answer.text, isNot(contains('secret detail')));
        expect(jsonDecode(answer.text), {
          'code': 'E_TRANSACTION_FAILED',
          'message': 'The call failed.',
        });
      },
    );
  });

  group('the in-process MCP server', () {
    test('initialize, ping, tools/list and a notification', () async {
      final server = AgentInProcessMcpServer(
        _bind(notesContext()),
        serverName: 'notes',
      );
      final init = await server.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
      });
      expect((init!['result']! as Map)['serverInfo'], {
        'name': 'notes',
        'version': '1',
      });
      expect(
        (await server.handle({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'ping',
        }))!['result'],
        isEmpty,
      );
      final list = await server.handle({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/list',
      });
      expect([
        for (final t in (list!['result']! as Map)['tools'] as List) t['name'],
      ], notesTools.names);
      expect(
        await server.handle({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        }),
        isNull,
      );
    });

    test(
      'tools/call runs through the registry and its calls record as mcp',
      () async {
        final c = notesContext();
        final server = AgentInProcessMcpServer(_bind(c), serverName: 'notes');
        final answer = await server.handle({
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'tools/call',
          'params': {
            'name': 'read_note',
            'arguments': {'noteId': 'a'},
          },
        });
        final result = answer!['result']! as Map;
        expect(result['isError'], isFalse);
        expect(
          jsonDecode(
            ((result['content']! as List).single as Map)['text']! as String,
          ),
          {'text': 'alpha'},
        );
        expect(c.audit.entries.single.entry, AgentAuditEntryPoint.mcp);
      },
    );

    test(
      'malformed requests and unknown methods are JSON-RPC errors',
      () async {
        final server = AgentInProcessMcpServer(
          _bind(notesContext()),
          serverName: 'notes',
        );
        Future<int> code(Map<String, Object?> m) async =>
            ((await server.handle(m))!['error']! as Map)['code']! as int;
        expect(await code({'id': 1, 'method': 'ping'}), -32600);
        expect(
          await code({'jsonrpc': '2.0', 'id': 1, 'method': 'nope'}),
          -32601,
        );
        expect(
          await code({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call'}),
          -32602,
        );
        expect(
          await code({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {'name': 'read_note', 'arguments': 'x'},
          }),
          -32602,
        );
      },
    );
  });

  group('the agent run', () {
    test(
      'an accepted run keeps its writes and commits its staged entries',
      () async {
        final c = notesContext();
        final audit = AgentMemoryAuditLog();
        final outcome = await AgentRun.execute(
          binding: _bind(c),
          audit: audit,
          label: 'Run',
          drive: (b) async {
            await b.call('write_note', {'noteId': 'a', 'text': 'A'});
            return 'done';
          },
        );
        expect(outcome.status, AgentRunStatus.accepted);
        expect(outcome.answer, 'done');
        expect(c.store.notes['a']!.text, 'A');
        expect(c.atomicLabels, ['Run']);
        expect(audit.entries.single.outcome, AgentAuditOutcome.applied);
      },
    );

    test('a rejected run is rolled back and its entries committed as rolled '
        'back; the preview carries the dry run', () async {
      final c = notesContext();
      final audit = AgentMemoryAuditLog();
      AgentRunOutcome? preview;
      final outcome = await AgentRun.execute(
        binding: _bind(c),
        audit: audit,
        drive: (b) async {
          await b.call('create_note', {'kind': 'plain', 'text': 'new'});
          final created = b.steps.single.result! as Map;
          await b.call('write_note', {
            'noteId': created['noteId'],
            'text': 'edited',
          });
          return '';
        },
        confirm: (p) async {
          preview = p;
          return false;
        },
      );
      expect(outcome.status, AgentRunStatus.rejected);
      expect(c.store.notes.keys, unorderedEquals(['a', 'b', 's']));
      expect([
        for (final e in audit.entries) e.outcome,
      ], everyElement(AgentAuditOutcome.rolledBack));
      // The dry run replayed the write against the copy's own new id.
      expect([for (final s in preview!.dryRun) s.ok], [true, true]);
      expect(preview!.dryRunOf(2)!.ok, isTrue);
    });

    test('a refused call rolls the run back without asking', () async {
      final c = notesContext();
      var asked = false;
      final outcome = await AgentRun.execute(
        binding: _bind(c),
        audit: AgentMemoryAuditLog(),
        drive: (b) async {
          await b.call('write_note', {'noteId': 'a', 'text': 'A'});
          await b.call('read_note', {'noteId': 's'});
          return '';
        },
        confirm: (_) async => asked = true,
      );
      expect(outcome.status, AgentRunStatus.rolledBack);
      expect(outcome.failedStep, 2);
      expect(asked, isFalse);
      expect(c.store.notes['a']!.text, 'alpha');
    });

    test('a run that stages into the log it commits to is refused', () {
      final c = notesContext();
      expect(
        () => AgentRun.execute(
          binding: _bind(c),
          audit: c.audit,
          drive: (_) async => '',
        ),
        throwsArgumentError,
      );
    });

    test(
      'a dry run does not run programs: such a step is not simulated',
      () async {
        final binding = _bind(notesContext(execution: true));
        final report = await AgentRun.dryRun(binding, [
          (name: 'run_note', arguments: {'noteId': 'a'}),
          (name: 'read_note', arguments: {'noteId': 's'}),
        ]);
        expect(report.first.notSimulated, isTrue);
        expect(report.first.ok, isFalse);
        expect(report.last.error!.code, AgentToolErrorCode.notFound);
        expect(binding.context.store.notes['a']!.text, 'alpha');
      },
    );
  });
}

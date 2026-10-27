// The compiled form of the agent tools' `### Example` section in
// `../../README.md`: the fence
// there appears here verbatim.

// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:tom_core_agentic/agent_tools.dart';

/// What the tools reach: notes by id, one kept out of the agent's view.
final notes = {'n1': 'Buy milk', 'n2': 'Call Ada', 'vault': 'pin 1234'};

/// The context a call runs against: the guard, and an atomic scope.
class NotesContext extends AgentToolContext {
  NotesContext(AgentInvocation invocation)
    : super(invocation: invocation, audit: AgentMemoryAuditLog());

  @override
  List<String> get auditTargetKeys => const ['noteId'];

  /// The note [id], once the guard admits it; the vault is never admitted.
  String admit(String id) {
    final text = notes[id];
    final gate = guard(
      AgentGuardTarget(id: id, kind: 'note', excluded: id == 'vault'),
    );
    if (text == null || gate == AgentScopeGate.excluded) {
      throw const AgentToolException(
        AgentToolErrorCode.notFound,
        'No such note.',
      );
    }
    if (gate != null) {
      throw AgentToolException(
        AgentToolErrorCode.readOnly,
        'Refused.',
        gate: gate,
      );
    }
    return text;
  }

  @override
  Future<T> runAtomically<T>(String label, Future<T> Function() body) => body();

  @override
  NotesContext dryRunCopy() => NotesContext(invocation);
}

final tools = AgentToolRegistry<NotesContext>([
  AgentTool(
    name: 'read_note',
    summary: 'Read one note.',
    result: '{text}',
    arguments: const AgentToolSchema([
      AgentToolArgument('noteId', AgentToolValueType.string, required: true),
    ]),
    invoke: (context, arguments) => {
      'text': context.admit(arguments['noteId']! as String),
    },
  ),
]);

Future<void> main() async {
  final context = NotesContext(
    AgentInvocation.mint(scope: AgentScope(allowWrite: false)),
  );
  final binding = AgentToolBinding(context: context, registry: tools);

  // What a provider declares to the model.
  print(binding.declarations.single.name); // read_note

  // What the model's calls answer — a refusal is an answer too.
  print((await binding.call('read_note', {'noteId': 'n1'})).text);
  // {"text":"Buy milk"}
  print((await binding.call('read_note', {'noteId': 'vault'})).text);
  // {"code":"E_NOT_FOUND","message":"No such note."}

  // The same registry over MCP, in-process.
  final server = AgentInProcessMcpServer(binding, serverName: 'notes');
  final listed = await server.handle({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'tools/list',
  });
  print(jsonEncode((listed!['result']! as Map)['tools'].length)); // 1

  // Every call is in the audit trail; the vault's text is not.
  for (final entry in context.audit.entries) {
    print('${entry.toolName} ${entry.targetId} ${entry.outcome.wire}');
  }
  // read_note n1 applied
  // read_note vault denied
}

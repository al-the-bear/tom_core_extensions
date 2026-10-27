/// A small tool surface over an in-memory note store — what the package's
/// tests drive the framework through.
///
/// Notes are `{id: text}` with a kind per note. A `secret` note is excluded
/// from the surface (gate 1). Every write goes through [NotesContext.write],
/// which reports the mutation to the running call's recording, as an
/// application's one write function does.
library;

import 'dart:async';

import 'package:tom_core_agentic/agent_tools.dart';

/// One note.
final class Note {
  Note(this.kind, this.text);

  final String kind;
  String text;

  Note copy() => Note(kind, text);
}

/// The zone key the store's write function reads its observer from.
const _observerKey = #notesObserver;

/// The note store a [NotesContext] reaches.
final class NoteStore {
  NoteStore([Map<String, Note>? notes]) : notes = notes ?? {};

  final Map<String, Note> notes;

  int _nextId = 1;

  NoteStore copy() =>
      NoteStore({for (final e in notes.entries) e.key: e.value.copy()})
        .._nextId = _nextId;

  /// The one write function: applies [op] and tells the observer.
  void write(String op, String id, void Function() body) {
    body();
    (Zone.current[_observerKey] as void Function(String, String)?)?.call(
      op,
      id,
    );
  }

  String create(String kind, String text) {
    final id = 'n${_nextId++}';
    write('create', id, () => notes[id] = Note(kind, text));
    return id;
  }
}

final class NotesContext extends AgentToolContext {
  NotesContext({
    required this.store,
    required super.invocation,
    AgentAuditLog? audit,
  }) : super(audit: audit ?? AgentMemoryAuditLog());

  final NoteStore store;

  /// Runs of [runAtomically], newest last — what a test reads back.
  final List<String> atomicLabels = [];

  @override
  List<String> get auditTargetKeys => const ['noteId'];

  @override
  String get auditLocatorKey => 'store';

  @override
  List<String> get createdIdKeys => const ['noteId'];

  @override
  Map<Object?, Object?> callZoneValues(AgentAuditRecording recording) => {
    _observerKey: (String op, String id) => recording.recordMutation(op, id),
  };

  /// The note [id], once the guard admits it.
  Note admit(String id) {
    final note = store.notes[id];
    if (note == null) {
      throw const AgentToolException(
        AgentToolErrorCode.notFound,
        'No such note.',
      );
    }
    final gate = guard(
      AgentGuardTarget(
        id: id,
        kind: note.kind,
        excluded: note.kind == 'secret',
      ),
    );
    if (gate != null) {
      throw AgentToolException(
        gate == AgentScopeGate.excluded
            ? AgentToolErrorCode.notFound
            : gate == AgentScopeGate.write
            ? AgentToolErrorCode.readOnly
            : AgentToolErrorCode.outOfScope,
        gate == AgentScopeGate.excluded ? 'No such note.' : 'Refused.',
        gate: gate,
        auditReason: gate == AgentScopeGate.excluded ? 'secret-excluded' : null,
      );
    }
    return note;
  }

  @override
  Future<T> runAtomically<T>(String label, Future<T> Function() body) async {
    atomicLabels.add(label);
    final saved = store.copy();
    try {
      return await body();
    } catch (_) {
      store.notes
        ..clear()
        ..addAll(saved.notes);
      rethrow;
    }
  }

  @override
  NotesContext dryRunCopy() =>
      NotesContext(store: store.copy(), invocation: invocation);
}

final readNote = AgentTool<NotesContext>(
  name: 'read_note',
  summary: 'Read a note.',
  result: '{text}',
  arguments: const AgentToolSchema([
    AgentToolArgument('noteId', AgentToolValueType.string, required: true),
  ]),
  invoke: (context, arguments) => {
    'text': context.admit(arguments['noteId']! as String).text,
  },
);

final writeNote = AgentTool<NotesContext>(
  name: 'write_note',
  summary: 'Replace a note\'s text.',
  result: '{}',
  isWrite: true,
  arguments: const AgentToolSchema([
    AgentToolArgument('noteId', AgentToolValueType.string, required: true),
    AgentToolArgument('text', AgentToolValueType.string, required: true),
  ]),
  invoke: (context, arguments) {
    final id = arguments['noteId']! as String;
    final note = context.admit(id);
    context.store.write('update', id, () {
      note.text = arguments['text']! as String;
    });
    return const <String, Object?>{};
  },
);

final createNote = AgentTool<NotesContext>(
  name: 'create_note',
  summary: 'Create a note.',
  result: '{noteId}',
  isWrite: true,
  arguments: const AgentToolSchema([
    AgentToolArgument(
      'kind',
      AgentToolValueType.string,
      required: true,
      allowed: ['plain', 'todo'],
    ),
    AgentToolArgument('text', AgentToolValueType.string, required: true),
  ]),
  invoke: (context, arguments) {
    final kind = arguments['kind']! as String;
    final gate = context.guard(AgentGuardTarget.creating(kind));
    if (gate != null) {
      throw AgentToolException(
        AgentToolErrorCode.readOnly,
        'Refused.',
        gate: gate,
      );
    }
    return {'noteId': context.store.create(kind, arguments['text']! as String)};
  },
);

/// A tool that runs a program — needs execution consent.
final runNote = AgentTool<NotesContext>(
  name: 'run_note',
  summary: 'Run a note as a program.',
  result: '{}',
  isWrite: true,
  needsExecution: true,
  arguments: const AgentToolSchema([
    AgentToolArgument('noteId', AgentToolValueType.string, required: true),
  ]),
  invoke: (context, arguments) {
    if (!context.allowExecution) {
      throw const AgentToolException(
        AgentToolErrorCode('E_EXECUTION_DISABLED', 'execution-disabled'),
        'Execution is not enabled.',
      );
    }
    final id = arguments['noteId']! as String;
    final note = context.admit(id);
    agentAuditExecutionStarted();
    context.store.write('update', id, () => note.text = '${note.text}!');
    agentAuditExecution(
      AgentAuditExecution(
        programId: id,
        programSha256: 'abc',
        outcome: AgentAuditOutcome.applied,
        mutationCount: 1,
        logBytes: 3,
      ),
    );
    return const <String, Object?>{};
  },
);

/// A tool whose body has a defect.
final brokenNote = AgentTool<NotesContext>(
  name: 'broken_note',
  summary: 'Throws.',
  result: '{}',
  invoke: (context, arguments) => throw StateError('secret detail'),
);

final notesTools = AgentToolRegistry<NotesContext>([
  readNote,
  writeNote,
  createNote,
  runNote,
  brokenNote,
]);

NoteStore sampleStore() => NoteStore({
  'a': Note('plain', 'alpha'),
  'b': Note('todo', 'beta'),
  's': Note('secret', 'hunter2'),
});

NotesContext notesContext({
  NoteStore? store,
  AgentScope? scope,
  bool execution = false,
  AgentAuditLog? audit,
}) => NotesContext(
  store: store ?? sampleStore(),
  audit: audit,
  invocation: execution
      ? AgentInvocation.withExecution(
          grant: const AgentExecutionGrant('risk'),
          residualRiskShown: 'risk',
          scope: scope ?? AgentScope(),
        )
      : AgentInvocation.mint(scope: scope ?? AgentScope()),
);

/// The audit trail: one entry shape, the append-only log it goes into, and
/// the per-call recording that fills it.
///
/// **Complete by construction.** Every presentation reaches a tool through
/// [AgentTool.call], and that is where the recording is made — around
/// validation, the gates and the body — so a call refused by validation, by a
/// gate or by its own body is recorded exactly as an applied one is, and no
/// presentation can skip the trail.
///
/// **Where the writes are seen.** A call's mutations are reported to the
/// recording by the application ([AgentAuditRecording.recordMutation]), from
/// the one function its writes run through, wired for the length of the call
/// by [AgentToolContext.callZoneValues]. An observation cannot leak into a
/// concurrent call's recording, because the recording lives in the call's
/// zone.
///
/// **Privacy.** An entry holds operations, ids, digests, sizes and reasons. It
/// has no field that could hold content, program source, program output or a
/// credential — the rule is kept not by filtering what a writer passed, but by
/// there being nowhere to pass it.
library;

import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'tool.dart';

/// Which surface a call arrived on. [agent] is an in-process native call,
/// [mcp] the in-process MCP surface, [rest] a network surface.
enum AgentAuditEntryPoint {
  agent('agent'),
  mcp('mcp'),
  rest('rest');

  const AgentAuditEntryPoint(this.wire);

  final String wire;

  static AgentAuditEntryPoint parse(String wire) => values.firstWhere(
    (v) => v.wire == wire,
    orElse: () => throw FormatException('Unknown audit entry point "$wire"'),
  );
}

/// What became of the operation an entry records.
enum AgentAuditOutcome {
  applied('applied'),
  denied('denied'),

  /// Applied, then reversed because the call or run it belonged to failed.
  /// The record of the attempt is kept.
  rolledBack('rolled-back'),

  /// The gates passed and the operation did not complete, with nothing to
  /// reverse.
  failed('failed');

  const AgentAuditOutcome(this.wire);

  final String wire;

  static AgentAuditOutcome parse(String wire) => values.firstWhere(
    (v) => v.wire == wire,
    orElse: () => throw FormatException('Unknown audit outcome "$wire"'),
  );
}

/// One audited operation.
final class AgentAuditEntry {
  /// Monotonic across the log. Assigned by [AgentAuditLog.append].
  final int opId;

  /// The mutation kind for a mutation, the tool name otherwise.
  final String op;

  /// The target the operation named; null for a call that named none.
  final String? targetId;

  /// The resource (document, file, …) the call reached, when it named or
  /// resolved one.
  final String? locator;

  final AgentAuditEntryPoint entry;

  /// The invocation id — in-process there is no token to name.
  final String scopeId;

  final bool allowed;

  /// Present iff not [allowed]: the **true** reason.
  final String? denyReason;

  /// For a denial by the scope guard: the gate that refused it, 1–4 in the
  /// fixed order. Null for a refusal no gate made and for everything allowed.
  final int? gate;

  /// The mutation's position in the invocation's undo chain; -1 for a read, a
  /// denial, and a mutation that was rolled back.
  final int undoRef;

  final DateTime appliedAt;

  /// The tool that produced the entry.
  final String toolName;

  /// For a program run: the program executed — never its source.
  final String? programId;

  /// For a program run: the SHA-256 of the source that ran, so a later edit
  /// to it is detectable.
  final String? programSha256;

  final AgentAuditOutcome outcome;

  /// For the terminal entry of a program run.
  final int? mutationCount;

  /// For the terminal entry of a program run: the size of the output it
  /// produced, never the output.
  final int? logBytes;

  const AgentAuditEntry({
    this.opId = 0,
    required this.op,
    required this.targetId,
    this.locator,
    required this.entry,
    required this.scopeId,
    required this.allowed,
    this.denyReason,
    this.gate,
    this.undoRef = -1,
    required this.appliedAt,
    required this.toolName,
    this.programId,
    this.programSha256,
    required this.outcome,
    this.mutationCount,
    this.logBytes,
  }) : assert(allowed == (denyReason == null)),
       assert(gate == null || !allowed);

  AgentAuditEntry _with({
    int? opId,
    AgentAuditOutcome? outcome,
    int? undoRef,
  }) => AgentAuditEntry(
    opId: opId ?? this.opId,
    op: op,
    targetId: targetId,
    locator: locator,
    entry: entry,
    scopeId: scopeId,
    allowed: allowed,
    denyReason: denyReason,
    gate: gate,
    undoRef: undoRef ?? this.undoRef,
    appliedAt: appliedAt,
    toolName: toolName,
    programId: programId,
    programSha256: programSha256,
    outcome: outcome ?? this.outcome,
    mutationCount: mutationCount,
    logBytes: logBytes,
  );

  /// This entry as a mutation that its call or run then reversed. A read, a
  /// denial and anything not applied are unchanged — only an applied mutation
  /// has something to reverse.
  AgentAuditEntry asRolledBack() =>
      outcome == AgentAuditOutcome.applied && undoRef >= 0
      ? _with(outcome: AgentAuditOutcome.rolledBack, undoRef: -1)
      : this;

  Map<String, Object?> toMap() => {
    'opId': opId,
    'op': op,
    'targetId': ?targetId,
    'locator': ?locator,
    'entry': entry.wire,
    'scopeId': scopeId,
    'allowed': allowed,
    'denyReason': ?denyReason,
    'gate': ?gate,
    'undoRef': undoRef,
    'appliedAt': appliedAt.toUtc().toIso8601String(),
    'toolName': toolName,
    'programId': ?programId,
    'programSha256': ?programSha256,
    'outcome': outcome.wire,
    'mutationCount': ?mutationCount,
    'logBytes': ?logBytes,
  };

  factory AgentAuditEntry.fromMap(Map<Object?, Object?> map) => AgentAuditEntry(
    opId: map['opId']! as int,
    op: map['op']! as String,
    targetId: map['targetId'] as String?,
    locator: map['locator'] as String?,
    entry: AgentAuditEntryPoint.parse(map['entry']! as String),
    scopeId: map['scopeId']! as String,
    allowed: map['allowed']! as bool,
    denyReason: map['denyReason'] as String?,
    gate: map['gate'] as int?,
    undoRef: map['undoRef']! as int,
    appliedAt: DateTime.parse(map['appliedAt']! as String),
    toolName: map['toolName']! as String,
    programId: map['programId'] as String?,
    programSha256: map['programSha256'] as String?,
    outcome: AgentAuditOutcome.parse(map['outcome']! as String),
    mutationCount: map['mutationCount'] as int?,
    logBytes: map['logBytes'] as int?,
  );

  @override
  String toString() =>
      'AgentAuditEntry#$opId($toolName/$op '
      '${targetId ?? '-'} ${outcome.wire}'
      '${denyReason == null ? '' : ' $denyReason'}'
      '${gate == null ? '' : ' gate $gate'})';
}

/// A viewer's three filters, over an entry list.
List<AgentAuditEntry> agentFilterAudit(
  Iterable<AgentAuditEntry> entries, {
  String? scopeId,
  String? locator,
  AgentAuditOutcome? outcome,
}) => [
  for (final entry in entries)
    if ((scopeId == null || entry.scopeId == scopeId) &&
        (locator == null || entry.locator == locator) &&
        (outcome == null || entry.outcome == outcome))
      entry,
];

/// The append-only audit log.
///
/// [append] is **synchronous**: a tool call from an interpreted program may be
/// synchronous, and a trail that needed an `await` would either block that
/// call or be skipped by it. Persistence follows asynchronously, in append
/// order; [flush] waits for it.
///
/// Retention is by age: an entry older than [retention] is dropped from
/// [entries] and from storage. There is no other way out of the log.
abstract class AgentAuditLog {
  AgentAuditLog({
    Duration retention = defaultRetention,
    DateTime Function()? clock,
  }) : _retention = retention,
       clock = clock ?? (() => DateTime.now().toUtc());

  static const defaultRetention = Duration(days: 90);

  /// How long an entry is kept.
  Duration get retention => _retention;
  Duration _retention;

  final DateTime Function() clock;

  /// Adopts a new retention, dropping what it no longer covers — from
  /// [entries] at once and from storage as soon as earlier writes have
  /// landed. Settings are often read after the log is open, so this is how a
  /// configured value arrives.
  void applyRetention(Duration value) {
    if (value == _retention) return;
    _retention = value;
    _prune();
    pruneStorage();
  }

  /// Deletes from storage what [retention] no longer covers.
  void pruneStorage() {}

  final List<AgentAuditEntry> _entries = [];
  int _lastOpId = 0;
  final StreamController<List<AgentAuditEntry>> _appended =
      StreamController.broadcast(sync: true);

  /// Every retained entry, oldest first.
  List<AgentAuditEntry> get entries => List.unmodifiable(_entries);

  /// Each appended batch, as it lands — what a viewer repaints from.
  Stream<List<AgentAuditEntry>> get appended => _appended.stream;

  /// Appends [batch] in order, numbering it after everything already in the
  /// log, and answers the entries as stored.
  List<AgentAuditEntry> append(Iterable<AgentAuditEntry> batch) {
    final stored = [for (final entry in batch) entry._with(opId: ++_lastOpId)];
    if (stored.isEmpty) return stored;
    _entries.addAll(stored);
    _prune();
    persist(stored);
    if (!_appended.isClosed) _appended.add(stored);
    return stored;
  }

  /// Waits until every appended batch has been handed to storage.
  Future<void> flush() async {}

  /// Stores [batch]. Called once per [append], in order.
  void persist(List<AgentAuditEntry> batch) {}

  void _adopt(Iterable<AgentAuditEntry> loaded) {
    _entries.addAll(loaded);
    _entries.sort((a, b) => a.opId.compareTo(b.opId));
    for (final entry in _entries) {
      if (entry.opId > _lastOpId) _lastOpId = entry.opId;
    }
    _prune();
  }

  void _prune() {
    final cutoff = clock().subtract(retention);
    _entries.removeWhere((e) => e.appliedAt.isBefore(cutoff));
  }

  Future<void> dispose() async {
    await flush();
    await _appended.close();
  }
}

/// An audit log kept for the life of the process — for a build with nowhere
/// to write, and for tests.
final class AgentMemoryAuditLog extends AgentAuditLog {
  AgentMemoryAuditLog({super.retention, super.clock});
}

/// Where an [AgentFileAuditLog] keeps its files: a keyed file medium the
/// application supplies — a directory, a browser store, a container.
///
/// Four operations because those are all the log needs, so any medium the
/// application already has adapts to it in a few lines. Keys are
/// `/`-separated relative paths.
abstract interface class AgentAuditStore {
  Future<List<String>> listFiles();
  Future<String> readString(String key);
  Future<void> writeString(String key, String value);
  Future<void> delete(String key);
}

/// The audit log as a stream of files over an [AgentAuditStore]: one file per
/// appended batch, filed under the UTC day it was written
/// (`<yyyy-mm-dd>/<µs>-<instance>-<n>.json`).
///
/// **One file per batch, never a rewrite.** An append writes one new file and
/// reads nothing, so two appenders never lose each other's writes. The day
/// folders are the rotation, and [retention] deletes whole days.
///
/// The store should be dedicated to the stream: [open] lists it.
final class AgentFileAuditLog extends AgentAuditLog {
  AgentFileAuditLog._(this.store, {super.retention, super.clock});

  /// The on-disk format of one batch file.
  static const formatVersion = 2;

  final AgentAuditStore store;

  Future<void> _pending = Future.value();
  late final String _instance = (clock().microsecondsSinceEpoch % 0xfffff)
      .toRadixString(16);
  int _counter = 0;

  /// Opens the stream over [store]: reads what is retained, deletes what is
  /// not, and continues numbering after the highest `opId` found.
  ///
  /// A file that does not parse, or is of another format, is skipped rather
  /// than failing the open — the trail is written by this code alone, so an
  /// unreadable file is a torn write, and refusing to start the tool surface
  /// over it would turn one lost batch into none being recorded at all.
  static Future<AgentFileAuditLog> open(
    AgentAuditStore store, {
    Duration retention = AgentAuditLog.defaultRetention,
    DateTime Function()? clock,
  }) async {
    final log = AgentFileAuditLog._(store, retention: retention, clock: clock);
    await log._deleteExpired();
    final loaded = <AgentAuditEntry>[];
    for (final path in await store.listFiles()) {
      if (!path.endsWith('.json')) continue;
      try {
        final raw = jsonDecode(await store.readString(path)) as Map;
        if (raw['version'] != formatVersion) continue;
        for (final map in raw['entries'] as List) {
          loaded.add(AgentAuditEntry.fromMap(map as Map));
        }
      } on Object {
        continue;
      }
    }
    log._adopt(loaded);
    return log;
  }

  static String _day(DateTime at) =>
      at.toUtc().toIso8601String().substring(0, 10);

  @override
  void persist(List<AgentAuditEntry> batch) {
    final at = clock();
    final key =
        '${_day(at)}/'
        '${at.microsecondsSinceEpoch.toString().padLeft(17, '0')}-'
        '$_instance-${_counter++}.json';
    final body = jsonEncode({
      'version': formatVersion,
      'entries': [for (final entry in batch) entry.toMap()],
    });
    _pending = _pending.then((_) => store.writeString(key, body));
  }

  @override
  Future<void> flush() => _pending;

  @override
  void pruneStorage() => _pending = _pending.then((_) => _deleteExpired());

  /// Deletes every day folder older than the retention cutoff — whole days,
  /// because a day is the unit the stream is filed under.
  Future<void> _deleteExpired() async {
    final cutoff = _day(clock().subtract(retention));
    for (final path in await store.listFiles()) {
      if (path.split('/').first.compareTo(cutoff) < 0) {
        await store.delete(path);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// the per-call recording
// ---------------------------------------------------------------------------

/// What a program run reports to the tool call that started it: the program,
/// the digest of what ran, how it ended, and sizes.
final class AgentAuditExecution {
  final String programId;
  final String? programSha256;

  /// [AgentAuditOutcome.applied], [AgentAuditOutcome.rolledBack] or
  /// [AgentAuditOutcome.failed].
  final AgentAuditOutcome outcome;
  final int mutationCount;
  final int logBytes;

  const AgentAuditExecution({
    required this.programId,
    required this.programSha256,
    required this.outcome,
    required this.mutationCount,
    required this.logBytes,
  });
}

/// Marks where a program run's mutations begin in the tool call it runs under.
/// A no-op outside one.
void agentAuditExecutionStarted() => AgentAuditRecording.current?._started();

/// Tells the tool call running now which resource it reached. A no-op outside
/// one.
void agentAuditResolved(String locator) =>
    AgentAuditRecording.current?._locator ??= locator;

/// Reports a program run to the tool call it runs under. A no-op outside one.
void agentAuditExecution(AgentAuditExecution run) =>
    AgentAuditRecording.current?._execution(run);

/// Tells the tool call running now that its writes are **one** group: if the
/// call fails, every write it made was rolled back. A no-op outside one.
void agentAuditCallIsOneGroup() =>
    AgentAuditRecording.current?._oneGroup = true;

/// Runs [body] as calls arriving on [entry]: every entry a tool call made
/// inside it records carries that `entry`.
///
/// **The presentation stamps it, not the caller.** The surface a call arrives
/// on is a property of the presentation, so `AgentInProcessMcpServer` wraps its
/// own dispatch in this, and a context cannot be built that would make an MCP
/// call record as a native one. Outside any presentation calls record as
/// [AgentAuditEntryPoint.agent].
T agentAuditEntering<T>(AgentAuditEntryPoint entry, T Function() body) =>
    runZoned(body, zoneValues: {_entryPointKey: entry});

const _recordingKey = #agentAuditRecording;
const _entryPointKey = #agentAuditEntryPoint;

/// One tool call's audit entries, collected while the call runs and appended
/// as one batch when it ends — applied, denied or failed.
final class AgentAuditRecording {
  AgentAuditRecording._(this._toolName, this._context, Map<String, Object?> raw)
    : _target = _targetOf(raw, _context.auditTargetKeys),
      _locator = raw[_context.auditLocatorKey] is String
          ? raw[_context.auditLocatorKey]! as String
          : null,
      _entryPoint =
          Zone.current[_entryPointKey] as AgentAuditEntryPoint? ??
          AgentAuditEntryPoint.agent;

  /// The recording of the tool call running now, or null outside one.
  static AgentAuditRecording? get current =>
      Zone.current[_recordingKey] as AgentAuditRecording?;

  final String _toolName;
  final AgentToolContext _context;
  final String? _target;
  final AgentAuditEntryPoint _entryPoint;
  String? _locator;
  bool _oneGroup = false;
  final List<AgentAuditEntry> _mutations = [];
  int? _runStart;
  bool _reportedRun = false;

  static String? _targetOf(Map<String, Object?> raw, List<String> keys) {
    for (final key in keys) {
      final value = raw[key];
      if (value is String) return value;
    }
    return null;
  }

  /// Runs [call] as the audited call of the tool [toolName], appending the
  /// call's entries to [context]'s log when it ends however it ends.
  static FutureOr<Object?> run(
    String toolName,
    AgentToolContext context,
    Map<String, Object?> raw,
    FutureOr<Object?> Function() call,
  ) {
    final recording = AgentAuditRecording._(toolName, context, raw);
    final FutureOr<Object?> result;
    try {
      result = runZoned(
        call,
        zoneValues: {
          ...context.callZoneValues(recording),
          _recordingKey: recording,
        },
      );
    } catch (error) {
      recording._finish(error);
      rethrow;
    }
    if (result is Future<Object?>) {
      return result.then(
        (value) {
          recording._finish(null);
          return value;
        },
        onError: (Object error, StackTrace stack) {
          recording._finish(error);
          Error.throwWithStackTrace(error, stack);
        },
      );
    }
    recording._finish(null);
    return result;
  }

  /// Records one applied mutation of kind [op] on [target], at the next
  /// position of the invocation's undo chain.
  void recordMutation(String op, String? target) => _mutations.add(
    _entry(
      op: op,
      target: target,
      outcome: AgentAuditOutcome.applied,
      undoRef: _context.nextUndoRef(),
    ),
  );

  AgentAuditEntry _entry({
    required String op,
    required String? target,
    required AgentAuditOutcome outcome,
    String? denyReason,
    int? gate,
    int undoRef = -1,
    String? programId,
    String? programSha256,
    int? mutationCount,
    int? logBytes,
  }) => AgentAuditEntry(
    op: op,
    targetId: target,
    locator: _locator,
    entry: _entryPoint,
    scopeId: _context.invocation.invocationId,
    allowed: denyReason == null,
    denyReason: denyReason,
    gate: gate,
    undoRef: undoRef,
    appliedAt: _context.audit.clock(),
    toolName: _toolName,
    programId: programId,
    programSha256: programSha256,
    outcome: outcome,
    mutationCount: mutationCount,
    logBytes: logBytes,
  );

  void _started() => _runStart = _mutations.length;

  void _execution(AgentAuditExecution run) {
    // The run's mutations are the ones observed since it started — a call's
    // own writes before it are not part of the run.
    final start = _runStart ?? _mutations.length;
    _runStart = null;
    _reportedRun = true;
    var mutations = _mutations.sublist(start);
    if (run.outcome != AgentAuditOutcome.applied) {
      mutations = [for (final entry in mutations) entry.asRolledBack()];
    }
    AgentAuditEntry framing({int? mutationCount, int? logBytes}) => _entry(
      op: _toolName,
      target: run.programId,
      outcome: run.outcome,
      programId: run.programId,
      programSha256: run.programSha256,
      mutationCount: mutationCount,
      logBytes: logBytes,
    );
    // The run, then one entry per mutation, then the terminal outcome.
    _mutations
      ..removeRange(start, _mutations.length)
      ..add(framing())
      ..addAll(mutations)
      ..add(framing(mutationCount: run.mutationCount, logBytes: run.logBytes));
  }

  void _finish(Object? error) {
    var batch = List.of(_mutations);
    if (error != null && _oneGroup) {
      // The call's group rolled back, so nothing it wrote survived.
      batch = [for (final entry in batch) entry.asRolledBack()];
    }
    if (error is AgentToolException && error.code.isFailure) {
      // The gates passed and the work did not complete. A program run has
      // already said so in its terminal entry; anything else says it here.
      if (!_reportedRun) {
        batch.add(
          _entry(
            op: _toolName,
            target: _target,
            outcome: AgentAuditOutcome.failed,
          ),
        );
      }
    } else if (error is AgentToolException) {
      batch.add(
        _entry(
          op: _toolName,
          target: _target,
          outcome: AgentAuditOutcome.denied,
          denyReason: error.auditReason,
          gate: error.gate?.number,
        ),
      );
    } else if (error != null) {
      batch.add(
        _entry(
          op: _toolName,
          target: _target,
          outcome: AgentAuditOutcome.failed,
        ),
      );
    } else if (batch.isEmpty) {
      batch.add(
        _entry(
          op: _toolName,
          target: _target,
          outcome: AgentAuditOutcome.applied,
        ),
      );
    }
    _context.audit.append(batch);
  }
}

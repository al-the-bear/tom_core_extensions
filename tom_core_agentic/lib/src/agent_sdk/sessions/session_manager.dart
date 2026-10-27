/// The AI sessions of an app, run from the main isolate.
///
/// Each session runs in its own isolate ([AgentSdkSessionHosting.isolate]),
/// spawned by its first run and kept, holding the transport connection, the
/// request loop and the liveness bound. The manager stays in the main isolate:
/// it consolidates every session's events into [trails], executes each
/// tool call against the document it owns, refuses a run in a busy
/// session, cancels — stopping an isolate that does not stop in
/// [cancelGrace] — and records a session's death in its trail without letting
/// it reach any other.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:tom_basics/diagnostics.dart';
import 'package:tom_llm/tom_llm.dart';

import '../transport/transport.dart';
import 'session_worker.dart';

/// Where a session runs.
enum AgentSdkSessionHosting {
  /// In an isolate of its own — what every root runs.
  isolate,

  /// In the main isolate, through the same worker and the same messages. For
  /// a suite whose stand-in transport holds state the test reads, which a
  /// copy in another isolate would not share.
  inProcess,
}

/// The sessions of one app.
final class AgentSdkSessionManager {
  /// Where sessions run.
  final AgentSdkSessionHosting hosting;

  /// The consolidated trails.
  final LlmTrails trails;

  /// Where a run's lifecycle is logged and an unmapped
  /// far-end message type is reported, never with any of its text.
  final TomDiagnostics diagnostics;

  /// How long a cancelled run may take to stop before its isolate is.
  final Duration cancelGrace;

  final Map<String, _Session> _sessions = {};
  var _nextRun = 0;
  var _disposed = false;

  AgentSdkSessionManager({
    this.hosting = AgentSdkSessionHosting.isolate,
    LlmTrails? trails,
    this.diagnostics = const TomNullDiagnostics(),
    this.cancelGrace = const Duration(seconds: 2),
  }) : trails = trails ?? LlmTrails();

  /// Whether [sessionId] has a run in progress.
  @visibleForTesting
  bool isBusy(String sessionId) => _sessions[sessionId]?.run != null;

  /// Runs [request] in [sessionId] over [transport], under [stallGap].
  ///
  /// Throws [LlmSessionBusyException] when the session already has a
  /// run. The stream carries [prelude] and then what the session
  /// reports, ends with one [LlmRunEnded], and does not error.
  /// Cancelling it cancels the run. [onFailure] observes a transport failure
  /// (the provider closes the availability gate on `unreachable`); the
  /// request's `tools` answers the run's tool calls, here, in the main isolate.
  Stream<LlmEvent> run({
    required String sessionId,
    required AgentSdkServerTransport transport,
    required AgentSdkCompletionRequest request,
    required List<LlmEvent> prelude,
    required Duration stallGap,
    void Function(LlmTransportException failure)? onFailure,
  }) {
    if (_disposed) throw StateError('The AI sessions were closed.');
    final session = _sessions.putIfAbsent(
      sessionId,
      () => _Session(sessionId, this),
    );
    if (session.run != null) throw LlmSessionBusyException(sessionId);
    final run = _Run(
      id: 'r${++_nextRun}',
      request: request,
      prelude: prelude,
      stallGap: stallGap,
      transportId: transport.id,
      onFailure: onFailure,
    );
    session.run = run;
    run.controller.onListen = () => unawaited(session.start(run, transport));
    run.controller.onCancel = () => session.cancel(run);
    return run.controller.stream;
  }

  /// Stops [sessionId]'s isolate as a death would, for a suite that proves a
  /// death is contained.
  @visibleForTesting
  void debugKill(String sessionId) => _sessions[sessionId]?.debugKill();

  /// Stops every session and closes [trails].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final session in _sessions.values) {
      await session.close();
    }
    _sessions.clear();
    trails.dispose();
  }

  void _log(
    String operation,
    String sessionId,
    _Run run, [
    Map<String, Object?> more = const {},
  ]) => diagnostics.log(
    TomDiagnosticEvent(
      operation: operation,
      level: TomDiagnosticLevel.info,
      fields: {'session': sessionId, 'run': run.id, ...more},
    ),
  );
}

/// One run in flight.
class _Run {
  final String id;
  final AgentSdkCompletionRequest request;
  final List<LlmEvent> prelude;
  final Duration stallGap;
  final String transportId;
  final void Function(LlmTransportException failure)? onFailure;

  /// Broadcast, as every controller here is.
  final StreamController<LlmEvent> controller =
      StreamController<LlmEvent>.broadcast();

  /// The run's account, so however this side ends the run, the end carries
  /// its report or its reason.
  final LlmRunAccount account;

  int get toolCalls => account.toolCalls;
  bool ended = false;
  bool cancelled = false;
  final Stopwatch clock = Stopwatch();

  _Run({
    required this.id,
    required this.request,
    required this.prelude,
    required this.stallGap,
    required this.transportId,
    required this.onFailure,
  }) : account = LlmRunAccount(providerId: transportId) {
    prelude.forEach(account.observe);
  }
}

/// One session, as the main isolate holds it.
class _Session {
  final String id;
  final AgentSdkSessionManager manager;

  _Session(this.id, this.manager);

  /// The run in flight, or null.
  _Run? run;

  /// The transport the host was started over; a different one restarts it.
  AgentSdkServerTransport? _transport;

  /// The way to the worker, once started.
  void Function(Map<String, Object?> message)? _toWorker;

  // Isolate hosting.
  Isolate? _isolate;
  ReceivePort? _inbox;
  ReceivePort? _exits;
  ReceivePort? _errors;

  // In-process hosting.
  AiSessionWorker? _local;

  Timer? _cancelTimer;
  Future<void>? _starting;

  LlmTrails get _trails => manager.trails;

  Future<void> start(_Run run, AgentSdkServerTransport transport) async {
    run.clock.start();
    manager._log('ai.run.started', id, run, {
      'task': _task(run),
      'transport': run.transportId,
    });
    try {
      if (!identical(_transport, transport)) {
        await close(reason: LlmSessionCloseReason.closed);
      }
      await (_starting ??= _open(transport));
    } on Object catch (e) {
      _starting = null;
      _fail(run, 'The $id AI session could not start (${e.runtimeType}).');
      return;
    }
    if (run.cancelled) return;
    _toWorker!({
      'op': 'run',
      'runId': run.id,
      'request': {
        'prompt': run.request.prompt,
        'context': run.request.context,
        'systemPrompt': run.request.systemPrompt,
        'model': run.request.model,
        'toolServer': run.request.tools?.serverName,
        'tools': run.request.tools == null
            ? null
            : [
                for (final d in run.request.tools!.declarations)
                  {
                    'name': d.name,
                    'description': d.description,
                    'inputSchema': d.inputSchema,
                  },
              ],
      },
      'prelude': [for (final e in run.prelude) e.toMap()],
      'stallGapMs': run.stallGap.inMilliseconds,
    });
  }

  String _task(_Run run) {
    for (final e in run.prelude) {
      if (e is LlmRunStarted) return e.purpose;
    }
    return 'unknown';
  }

  /// Starts the host — an isolate, or a worker here — over [transport].
  Future<void> _open(AgentSdkServerTransport transport) async {
    _transport = transport;
    switch (manager.hosting) {
      case AgentSdkSessionHosting.inProcess:
        final worker = AiSessionWorker(
          transport,
          (message) => scheduleMicrotask(() => _fromWorker(message)),
        );
        _local = worker;
        _toWorker = (message) =>
            scheduleMicrotask(() => worker.receive(message));
      case AgentSdkSessionHosting.isolate:
        final copy = transport.sessionCopy;
        if (copy == null) {
          throw StateError(
            'The ${transport.id} transport cannot run in a session isolate.',
          );
        }
        final inbox = ReceivePort();
        final exits = ReceivePort();
        final errors = ReceivePort();
        _inbox = inbox;
        _exits = exits;
        _errors = errors;
        final port = Completer<SendPort>();
        inbox.listen((message) {
          if (message is SendPort) {
            port.complete(message);
          } else {
            _fromWorker((message as Map).cast<String, Object?>());
          }
        });
        exits.listen((_) => _died('The $id AI session stopped.'));
        errors.listen(
          (error) => _died(
            'The $id AI session failed '
            '(${error is List && error.isNotEmpty ? _firstLine(error.first) : 'unknown error'}).',
          ),
        );
        _isolate = await Isolate.spawn(
          aiSessionIsolateMain,
          [inbox.sendPort, copy],
          onExit: exits.sendPort,
          onError: errors.sendPort,
          errorsAreFatal: true,
          debugName: 'agent-sdk-session-$id',
        );
        final send = await port.future;
        _toWorker = send.send;
    }
    _trails.record(
      id,
      LlmSessionOpened(sessionId: id, sessionKind: LlmSessionKind.internal),
    );
  }

  /// The first line of an isolate's error description — its type and short
  /// message, never a stack, which can quote source.
  static String _firstLine(Object? error) =>
      '$error'.split('\n').first.split(':').first;

  void _fromWorker(Map<String, Object?> message) {
    final run = this.run;
    switch (message['op']) {
      case 'event':
        if (run == null || run.id != message['runId'] || run.ended) return;
        _deliver(
          run,
          LlmEvent.fromMap((message['event']! as Map).cast<String, Object?>()),
        );
      case 'toolCall':
        if (run == null || run.id != message['runId']) return;
        unawaited(_answerTool(run, message));
      case 'unmapped':
        manager.diagnostics.log(
          TomDiagnosticEvent(
            operation: 'ai.transport.unmapped',
            level: TomDiagnosticLevel.debug,
            fields: {'transport': _transport?.id, 'type': message['type']},
          ),
        );
      case 'done' || 'cancelled':
        if (run != null && run.id == message['runId']) _settle(run);
    }
  }

  Future<void> _answerTool(_Run run, Map<String, Object?> message) async {
    final tools = run.request.tools;
    LlmToolAnswer answer;
    if (tools == null) {
      answer = (isError: true, text: 'This run has no tools.');
    } else {
      answer = await tools.call(
        message['name']! as String,
        (message['arguments']! as Map).cast<String, Object?>(),
      );
    }
    _toWorker?.call({
      'op': 'toolAnswer',
      'callSerial': message['callSerial'],
      'isError': answer.isError,
      'text': answer.text,
    });
  }

  /// Hands [event] to the run's listener and records it.
  void _deliver(_Run run, LlmEvent event) {
    _trails.record(id, event, runId: run.id);
    run.account.observe(event);
    if (event case LlmRunError(
      errorKind: LlmErrorKind.unreachable,
      :final message,
    )) {
      run.onFailure?.call(
        LlmTransportException(
          LlmErrorKind.unreachable,
          message,
          transportId: run.transportId,
        ),
      );
    }
    if (!run.controller.isClosed) run.controller.add(event);
    if (event is LlmRunEnded) {
      run.ended = true;
      // Free from the moment the caller's stream ends, not from the worker's
      // `done` a message later: a run started on the next line must not find
      // the session busy with a run its caller has seen end.
      if (identical(this.run, run)) this.run = null;
      manager._log('ai.run.ended', id, run, {
        'outcome': event.outcome.name,
        'toolCalls': event.toolCalls,
        'durationMs': event.duration.inMilliseconds,
      });
      unawaited(run.controller.close());
    }
  }

  /// The run is over on the worker's side: the session is free.
  void _settle(_Run run) {
    _cancelTimer?.cancel();
    _cancelTimer = null;
    if (!run.ended) {
      _deliver(
        run,
        run.account.end(
          run.cancelled ? LlmRunOutcome.cancelled : LlmRunOutcome.completed,
          duration: run.clock.elapsed,
        ),
      );
    }
    if (identical(this.run, run)) this.run = null;
  }

  /// Ends [run] as failed with [message] and frees the session.
  void _fail(_Run run, String message) {
    if (!run.ended) {
      _deliver(run, LlmRunError(LlmErrorKind.protocol, message));
      _deliver(
        run,
        run.account.end(
          run.cancelled ? LlmRunOutcome.cancelled : LlmRunOutcome.failed,
          duration: run.clock.elapsed,
        ),
      );
    }
    if (identical(this.run, run)) this.run = null;
  }

  /// The caller stopped listening: the run is cancelled.
  void cancel(_Run run) {
    if (run.ended || run.cancelled) return;
    run.cancelled = true;
    _trails.record(
      id,
      run.account.end(LlmRunOutcome.cancelled, duration: run.clock.elapsed),
      runId: run.id,
    );
    run.ended = true;
    manager._log('ai.run.ended', id, run, {
      'outcome': LlmRunOutcome.cancelled.name,
      'toolCalls': run.toolCalls,
      'durationMs': run.clock.elapsed.inMilliseconds,
    });
    final send = _toWorker;
    if (send == null) {
      // Cancelled before the host started: nothing is running yet.
      if (identical(this.run, run)) this.run = null;
      return;
    }
    send({'op': 'cancel', 'runId': run.id});
    _cancelTimer = Timer(manager.cancelGrace, () {
      // It did not stop: stop the session, so the next run
      // starts on a fresh one.
      unawaited(
        close(reason: LlmSessionCloseReason.failed, message: 'stopped'),
      );
    });
  }

  void debugKill() => _isolate?.kill(priority: Isolate.immediate);

  /// The isolate exited or failed without being asked to.
  void _died(String message) {
    if (_toWorker == null) return;
    final run = this.run;
    _release();
    if (run != null) _fail(run, message);
    _trails.record(
      id,
      LlmSessionClosed(LlmSessionCloseReason.failed, message: message),
    );
    manager.diagnostics.log(
      TomDiagnosticEvent(
        operation: 'ai.session.failed',
        level: TomDiagnosticLevel.warn,
        fields: {'session': id, 'reason': message},
      ),
    );
  }

  /// Stops the host. A run in flight ends; the trail records why.
  Future<void> close({
    LlmSessionCloseReason reason = LlmSessionCloseReason.closed,
    String? message,
  }) async {
    _cancelTimer?.cancel();
    _cancelTimer = null;
    final send = _toWorker;
    if (send == null) return;
    final isolate = _isolate;
    final local = _local;
    final run = this.run;
    _release();
    if (isolate != null) {
      if (reason == LlmSessionCloseReason.closed) {
        // Asked to stop: the worker closes its transport — which reaps a
        // standalone Node child — and then exits.
        send({'op': 'stop'});
      } else {
        // Did not stop when asked: its child, if it has one, goes with the
        // app, whose exit closes the child's stdin.
        isolate.kill(priority: Isolate.immediate);
      }
    }
    if (local != null) await local.dispose();
    if (run != null) {
      if (run.cancelled) {
        if (identical(this.run, run)) this.run = null;
      } else {
        _fail(run, 'The $id AI session was closed.');
      }
    }
    _trails.record(id, LlmSessionClosed(reason, message: message));
  }

  void _release() {
    _toWorker = null;
    _starting = null;
    _transport = null;
    _isolate = null;
    _local = null;
    _inbox?.close();
    _exits?.close();
    _errors?.close();
    _inbox = null;
    _exits = null;
    _errors = null;
  }
}

/// What runs inside an AI session — the transport connection, the
/// request loop and the liveness bound.
///
/// The worker speaks to the main isolate only in maps of primitives, so the
/// same code serves a session in its own isolate (`aiSessionIsolateMain`) and
/// one hosted in the main isolate, and the two cannot drift apart.
///
/// **The protocol.** Main → worker:
///
/// - `{op: run, runId, request, prelude, stallGapMs}` — `request` carries the
///  prompt, context, system prompt, model and, for an agent run, the tool
///  declarations; `prelude` the run's opening events as maps.
/// - `{op: cancel, runId}`.
/// - `{op: toolAnswer, callSerial, isError, text}` — the answer to a tool call
///  the main isolate ran.
///
/// Worker → main:
///
/// - `{op: event, runId, event}` — one trail event, as a map.
/// - `{op: toolCall, runId, callSerial, name, arguments}` — a tool call,
///  which the main isolate executes against the document it owns.
/// - `{op: unmapped, type}` — a far-end message type the translator does not map.
/// - `{op: done, runId}` — the run ended; `{op: cancelled, runId}` — a
///  cancel took effect.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:tom_llm/tom_llm.dart';

import '../stall_bound.dart';
import '../transport/transport.dart';

/// The worker side of one session.
final class AiSessionWorker {
  final AgentSdkServerTransport _transport;
  final void Function(Map<String, Object?> message) _send;

  final Map<String, StreamSubscription<LlmEvent>> _runs = {};
  final Map<int, Completer<LlmToolAnswer>> _toolCalls = {};
  int _nextCall = 0;

  AiSessionWorker(this._transport, this._send);

  /// Handles one message from the main isolate.
  void receive(Map<String, Object?> message) {
    switch (message['op']) {
      case 'run':
        _run(message);
      case 'cancel':
        _cancel(message['runId']! as String);
      case 'toolAnswer':
        _toolCalls.remove(message['callSerial']! as int)?.complete((
          isError: message['isError'] == true,
          text: message['text']! as String,
        ));
    }
  }

  void _run(Map<String, Object?> message) {
    final runId = message['runId']! as String;
    final request = (message['request']! as Map).cast<String, Object?>();
    final declarations = request['tools'] as List?;
    final completion = AgentSdkCompletionRequest(
      prompt: request['prompt']! as String,
      context: request['context'] as String? ?? '',
      systemPrompt: request['systemPrompt'] as String?,
      model: request['model'] as String?,
      tools: declarations == null
          ? null
          : AgentSdkToolSet(
              serverName: request['toolServer']! as String,
              declarations: [
                for (final d in declarations)
                  (
                    name: (d as Map)['name']! as String,
                    description: d['description']! as String,
                    inputSchema: (d['inputSchema']! as Map)
                        .cast<String, Object?>(),
                  ),
              ],
              call: (name, arguments) => _askMain(runId, name, arguments),
            ),
    );
    final prelude = [
      for (final e in (message['prelude'] as List? ?? const []))
        LlmEvent.fromMap((e as Map).cast<String, Object?>()),
    ];

    _runs[runId] =
        boundedAiRun(
          _connected(completion),
          stallGap: Duration(milliseconds: message['stallGapMs']! as int),
          transportId: _transport.id,
          prelude: prelude,
          onUnmapped: (type) => _send({'op': 'unmapped', 'type': type}),
        ).listen(
          (event) =>
              _send({'op': 'event', 'runId': runId, 'event': event.toMap()}),
          onDone: () {
            _runs.remove(runId);
            _send({'op': 'done', 'runId': runId});
          },
        );
  }

  /// The transport's completion, connecting first when it is not connected —
  /// a session holds its connection across runs, and opens it on the first.
  Stream<AgentSdkCompletionEvent> _connected(
    AgentSdkCompletionRequest request,
  ) {
    if (_transport.isConnected) return _transport.complete(request);
    return Stream.fromFuture(
      _transport.connect(),
    ).asyncExpand((_) => _transport.complete(request));
  }

  void _cancel(String runId) {
    final run = _runs.remove(runId);
    if (run == null) return;
    // Not awaited: a cancel takes effect when it is called. The
    // transport aborts the remote completion on it.
    unawaited(run.cancel());
    _send({'op': 'cancelled', 'runId': runId});
  }

  Future<LlmToolAnswer> _askMain(
    String runId,
    String name,
    Map<String, Object?> arguments,
  ) {
    final serial = _nextCall++;
    final answer = Completer<LlmToolAnswer>();
    _toolCalls[serial] = answer;
    _send({
      'op': 'toolCall',
      'runId': runId,
      'callSerial': serial,
      'name': name,
      'arguments': arguments,
    });
    return answer.future;
  }

  /// Ends every run and closes the transport.
  Future<void> dispose() async {
    for (final run in _runs.values) {
      unawaited(run.cancel());
    }
    _runs.clear();
    await _transport.close();
  }
}

/// The entry point of a session isolate. [args] is the main isolate's port
/// and the function that builds the session's transport
/// ([AgentSdkServerTransport.sessionCopy]).
///
/// It answers with its own port, then serves messages until it is told to
/// stop (`{op: stop}`), when it closes its transport and exits.
void aiSessionIsolateMain(List<Object?> args) {
  final main = args[0]! as SendPort;
  final build = args[1]! as AgentSdkServerTransport Function();
  final inbox = ReceivePort();
  final worker = AiSessionWorker(build(), main.send);
  main.send(inbox.sendPort);
  inbox.listen((message) {
    final map = (message as Map).cast<String, Object?>();
    if (map['op'] == 'stop') {
      inbox.close();
      unawaited(worker.dispose().whenComplete(() => Isolate.exit()));
      return;
    }
    worker.receive(map);
  });
}

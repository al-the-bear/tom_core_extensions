/// A fixture that speaks the CLI-server wire, used two ways.
///
/// **In-process** it backs the hosted-transport tests: it binds a loopback
/// port, answers `workspace.getInfoVce` so the real discovery scan can identify
/// it, and answers `agentSdk.queryVce` with scripted chunks.
///
/// **Spawned** (`dart test/agent_sdk/support/fake_ai_server.dart`) it backs the
/// standalone-transport tests, standing in for `agent_sdk_server.js` — it
/// prints the same `AGENT_SDK_SERVER_READY` line and exits when stdin closes,
/// so the Dart side's process lifecycle is exercised for real without needing
/// Node or a credential.
///
/// It records **every raw byte it receives**. That is what makes the privacy
/// conformance test evidence rather than assertion: the test does not inspect
/// what the provider intended to send, it inspects what actually crossed the
/// socket.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The ready line the standalone transport waits for.
const readyPrefix = 'AGENT_SDK_SERVER_READY ';

/// How a scripted server should answer a query.
enum FakeAiServerBehaviour {
  /// Stream [FakeAiServer.replies] as assistant text blocks, then `done`.
  succeed,

  /// Answer with the prompt that was received, as one assistant text block.
  ///
  /// Lets a *spawned* fixture report what crossed the socket, which is the
  /// only way the standalone path's privacy test can inspect the wire: the
  /// child's own buffers are in another process.
  echoPrompt,

  /// Send a terminal `error` chunk.
  failWithError,

  /// Stream [FakeAiServer.replies] with [FakeAiServer.dripInterval] between
  /// them — a slow but *live* far end.
  ///
  /// The one behaviour that can distinguish a gap bound from a total budget:
  /// a completion whose deltas are individually prompt but whose whole run is
  /// long must not be cut off.
  slowDrip,

  /// Emit nothing but `stream_event` chunks for [FakeAiServer.thinkingBeats]
  /// beats of [FakeAiServer.dripInterval], then answer in one block.
  ///
  /// This is what a real extended-thinking model looks like: no assistant
  /// message at all for a long time, and partial-message events as the only
  /// evidence it is alive. A stall bound that did not count them would kill
  /// exactly the completions worth waiting for.
  thinkAloudThenAnswer,

  /// Accept the query and never answer, so cancellation can be observed.
  hang,

  /// What the Agent SDK does with a credential the API rejects: `system/init`,
  /// then one `system/api_retry` event per [FakeAiServer.dripInterval]
  /// carrying `error_status: 401` / `error: authentication_failed`, for as
  /// long as the query is left running.
  ///
  /// Shape copied from a real run (SDK 0.3.284, 2026-09-28): the real one
  /// gives up after ten attempts and about three minutes, which this fixture
  /// does not bother to imitate — the point is that the rejection is *stated*
  /// on the first event, not that it is eventually concluded.
  rejectCredential,

  /// A transient failure the SDK recovers from: [FakeAiServer.thinkingBeats]
  /// `system/api_retry` events carrying `error_status: 529` /
  /// `error: server_error`, then the answer.
  retryThenAnswer,

  /// What the Agent SDK does with a query that declares in-process tools:
  /// one assistant message with [FakeAiServer.replies]' first entry and a
  /// `tool_use` block, then one `agentSdk.toolCall` **request** per entry of
  /// [FakeAiServer.toolCalls], sent back over the same socket and each
  /// awaited before the next, then an assistant message with the remaining
  /// replies, then `done`. The client's answers land in
  /// [FakeAiServer.toolAnswers].
  callTools,

  /// Send [FakeAiServer.recorded] — Agent SDK messages recorded from a live
  /// run (`test/agent_sdk/fixtures/sdk_messages/`) — one chunk each, then
  /// end the stream.
  replay,
}

final class FakeAiServer {
  final ServerSocket _server;

  /// Text deltas returned for each query.
  final List<String> replies;

  /// How queries are answered.
  final FakeAiServerBehaviour behaviour;

  /// The workspace identity reported to the discovery scan.
  final String workspaceName;

  /// The pause between deltas under [FakeAiServerBehaviour.slowDrip], and
  /// between thinking beats under
  /// [FakeAiServerBehaviour.thinkAloudThenAnswer].
  final Duration dripInterval;

  /// How many `stream_event` beats precede the answer under
  /// [FakeAiServerBehaviour.thinkAloudThenAnswer].
  final int thinkingBeats;

  /// The messages [FakeAiServerBehaviour.replay] sends, in order.
  final List<Map<String, dynamic>> recorded;

  /// Every byte received, in order.
  final BytesBuilder receivedBytes = BytesBuilder();

  /// Every decoded request, in order.
  final List<Map<String, dynamic>> requests = [];

  /// Stream ids that received an `agentSdk.cancelVce`.
  final List<String> cancelled = [];

  /// The calls made under [FakeAiServerBehaviour.callTools], in order:
  /// `(server, tool, args)`.
  List<(String, String, Map<String, Object?>)> toolCalls = const [];

  /// The client's whole JSON-RPC answer to each `agentSdk.toolCall`, in order.
  final List<Map<String, dynamic>> toolAnswers = [];

  /// Reverse requests awaiting the client's answer, by id.
  final Map<Object?, Completer<Map<String, dynamic>>> _pending = {};
  int _nextRequestId = 1;

  FakeAiServer._(
    this._server, {
    required this.replies,
    required this.behaviour,
    required this.workspaceName,
    required this.dripInterval,
    required this.thinkingBeats,
    this.recorded = const [],
  });

  int get port => _server.port;

  /// Everything received, decoded as UTF-8 — the surface the privacy test
  /// searches for secrets.
  String get receivedText =>
      utf8.decode(receivedBytes.toBytes(), allowMalformed: true);

  static Future<FakeAiServer> start({
    List<String> replies = const ['Hello from the fixture.'],
    FakeAiServerBehaviour behaviour = FakeAiServerBehaviour.succeed,
    String workspaceName = 'agent-sdk-fixture',
    Duration dripInterval = const Duration(milliseconds: 200),
    int thinkingBeats = 5,
    int port = 0,
    List<Map<String, dynamic>> recorded = const [],
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    final server = FakeAiServer._(
      socket,
      replies: replies,
      behaviour: behaviour,
      workspaceName: workspaceName,
      dripInterval: dripInterval,
      thinkingBeats: thinkingBeats,
      recorded: recorded,
    );
    socket.listen(server._handle);
    return server;
  }

  /// A server that answers on a socket a [ReservedPort] already holds.
  ///
  /// The port was never released, so nothing else can have taken it between
  /// "nothing is listening" and "now the server starts".
  static FakeAiServer _serving(
    ReservedPort reserved, {
    required List<String> replies,
    required FakeAiServerBehaviour behaviour,
    required String workspaceName,
    required Duration dripInterval,
    required int thinkingBeats,
  }) {
    final server = FakeAiServer._(
      reserved._socket,
      replies: replies,
      behaviour: behaviour,
      workspaceName: workspaceName,
      dripInterval: dripInterval,
      thinkingBeats: thinkingBeats,
    );
    reserved._handler = server._handle;
    return server;
  }

  /// Set by [stop], so an open-ended behaviour stops writing.
  bool _stopped = false;

  Future<void> stop() {
    _stopped = true;
    return _server.close();
  }

  void _handle(Socket socket) {
    var buffer = <int>[];
    socket.listen(
      (chunk) {
        receivedBytes.add(chunk);
        buffer.addAll(chunk);
        while (buffer.length >= 4) {
          final length =
              (buffer[0] << 24) |
              (buffer[1] << 16) |
              (buffer[2] << 8) |
              buffer[3];
          if (buffer.length < 4 + length) return;
          final payload = buffer.sublist(4, 4 + length);
          buffer = buffer.sublist(4 + length);
          final message =
              jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
          requests.add(message);
          _dispatch(socket, message);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _dispatch(Socket socket, Map<String, dynamic> message) {
    final id = message['id'];
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, dynamic>() ?? {};

    if (method == null && id != null) {
      // The client's answer to a reverse request.
      _pending.remove(id)?.complete(message);
      return;
    }

    switch (method) {
      case 'workspace.getInfoVce':
        _reply(socket, id, {
          'name': workspaceName,
          'rootPath': '/fixture/$workspaceName',
          'folders': <dynamic>[],
        });
      case 'agentSdk.queryVce':
        final streamId = params['streamId'] as String;
        _reply(socket, id, {'success': true, 'streamId': streamId});
        switch (behaviour) {
          case FakeAiServerBehaviour.succeed:
            for (final reply in replies) {
              _notify(socket, {
                'streamId': streamId,
                'message': {
                  'type': 'assistant',
                  'message': {
                    'content': [
                      {'type': 'text', 'text': reply},
                    ],
                  },
                },
              });
            }
            _notify(socket, {'streamId': streamId, 'done': true});
          case FakeAiServerBehaviour.echoPrompt:
            _notify(socket, {
              'streamId': streamId,
              'message': {
                'type': 'assistant',
                'message': {
                  'content': [
                    {'type': 'text', 'text': params['prompt']},
                  ],
                },
              },
            });
            _notify(socket, {'streamId': streamId, 'done': true});
          case FakeAiServerBehaviour.failWithError:
            _notify(socket, {
              'streamId': streamId,
              'error': 'the fixture was told to fail',
            });
          case FakeAiServerBehaviour.slowDrip:
            unawaited(_drip(socket, streamId));
          case FakeAiServerBehaviour.thinkAloudThenAnswer:
            unawaited(_thinkAloud(socket, streamId));
          case FakeAiServerBehaviour.hang:
            break;
          case FakeAiServerBehaviour.rejectCredential:
            unawaited(
              _retry(
                socket,
                streamId,
                status: 401,
                error: 'authentication_failed',
                beats: null,
              ),
            );
          case FakeAiServerBehaviour.retryThenAnswer:
            unawaited(
              _retry(
                socket,
                streamId,
                status: 529,
                error: 'server_error',
                beats: thinkingBeats,
              ),
            );
          case FakeAiServerBehaviour.callTools:
            unawaited(_callTools(socket, streamId));
          case FakeAiServerBehaviour.replay:
            for (final message in recorded) {
              _notify(socket, {'streamId': streamId, 'message': message});
            }
            _notify(socket, {'streamId': streamId, 'done': true});
        }
      case 'agentSdk.cancelVce':
        cancelled.add(params['streamId'] as String);
        _reply(socket, id, {'success': true});
      default:
        _replyError(socket, id, 'Method not found: $method');
    }
  }

  /// Streams the replies one at a time, pausing [dripInterval] before each.
  ///
  /// The pause comes *before* the delta rather than after it, so the very first
  /// gap — the one a real model spends thinking before it says anything — is
  /// exercised too. That is the gap a naive total budget and a gap bound both
  /// have to survive, and the one a first-delta-then-pause fixture would skip.
  Future<void> _drip(Socket socket, String streamId) async {
    for (final reply in replies) {
      await Future<void>.delayed(dripInterval);
      _notify(socket, {
        'streamId': streamId,
        'message': {
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': reply},
            ],
          },
        },
      });
    }
    _notify(socket, {'streamId': streamId, 'done': true});
  }

  /// Emits [thinkingBeats] `stream_event` chunks and only then the answer.
  ///
  /// The chunks carry no text the adapter will emit — that is the point. They
  /// are the shape of `SDKPartialAssistantMessage`, which the Agent SDK sends
  /// **only** when `includePartialMessages` is set, and they are the sole
  /// evidence of life a thinking model produces before its first token.
  Future<void> _thinkAloud(Socket socket, String streamId) async {
    for (var beat = 0; beat < thinkingBeats; beat++) {
      await Future<void>.delayed(dripInterval);
      _notify(socket, {
        'streamId': streamId,
        'message': {
          'type': 'stream_event',
          'event': {'type': 'ping'},
        },
      });
    }
    _notify(socket, {
      'streamId': streamId,
      'message': {
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'text', 'text': replies.join()},
          ],
        },
      },
    });
    _notify(socket, {'streamId': streamId, 'done': true});
  }

  /// Emits `system/init` and then `system/api_retry` events, [beats] of them
  /// followed by the answer, or — with [beats] null — until the query is
  /// cancelled or the socket closes.
  Future<void> _retry(
    Socket socket,
    String streamId, {
    required int status,
    required String error,
    required int? beats,
  }) async {
    _notify(socket, {
      'streamId': streamId,
      'message': {'type': 'system', 'subtype': 'init'},
    });
    for (var attempt = 1; beats == null || attempt <= beats; attempt++) {
      await Future<void>.delayed(dripInterval);
      if (cancelled.contains(streamId) || _stopped) return;
      _notify(socket, {
        'streamId': streamId,
        'message': {
          'type': 'system',
          'subtype': 'api_retry',
          'attempt': attempt,
          'max_retries': 10,
          'retry_delay_ms': dripInterval.inMilliseconds,
          'error_status': status,
          'error': error,
        },
      });
    }
    _notify(socket, {
      'streamId': streamId,
      'message': {
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'text', 'text': replies.join()},
          ],
        },
      },
    });
    _notify(socket, {'streamId': streamId, 'done': true});
  }

  /// Runs the [toolCalls] script; see [FakeAiServerBehaviour.callTools].
  Future<void> _callTools(Socket socket, String streamId) async {
    _notify(socket, {
      'streamId': streamId,
      'message': {
        'type': 'assistant',
        'message': {
          'content': [
            if (replies.isNotEmpty) {'type': 'text', 'text': replies.first},
            for (final (_, tool, args) in toolCalls)
              {
                'type': 'tool_use',
                'id': 'toolu_$tool',
                'name': tool,
                'input': args,
              },
          ],
        },
      },
    });
    for (final (server, tool, args) in toolCalls) {
      final id = 'fake-srv-${_nextRequestId++}';
      final answer = Completer<Map<String, dynamic>>();
      _pending[id] = answer;
      _write(socket, {
        'jsonrpc': '2.0',
        'id': id,
        'method': 'agentSdk.toolCall',
        'params': {
          'streamId': streamId,
          'server': server,
          'tool': tool,
          'args': args,
        },
      });
      toolAnswers.add(await answer.future);
    }
    _notify(socket, {
      'streamId': streamId,
      'message': {
        'type': 'assistant',
        'message': {
          'content': [
            for (final reply in replies.skip(1))
              {'type': 'text', 'text': reply},
          ],
        },
      },
    });
    _notify(socket, {'streamId': streamId, 'done': true});
  }

  void _reply(Socket socket, Object? id, Object? result) =>
      _write(socket, {'jsonrpc': '2.0', 'id': id, 'result': result});

  void _replyError(Socket socket, Object? id, String message) =>
      _write(socket, {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': message},
      });

  void _notify(Socket socket, Map<String, Object?> params) => _write(socket, {
    'jsonrpc': '2.0',
    'method': 'agentSdk.chunk',
    'params': params,
  });

  void _write(Socket socket, Map<String, Object?> message) {
    final payload = utf8.encode(jsonEncode(message));
    final header = [
      (payload.length >> 24) & 0xff,
      (payload.length >> 16) & 0xff,
      (payload.length >> 8) & 0xff,
      payload.length & 0xff,
    ];
    socket.add(header);
    socket.add(payload);
  }
}

/// Spawned entry point — the stand-in for `agent_sdk_server.js`.
Future<void> main(List<String> args) async {
  // More than one reply on purpose: the contract test asserts that a
  // completion arrives as a stream of deltas rather than one buffered answer,
  // and a spawned fixture that sent a single block would let that assertion
  // pass vacuously on the standalone path.
  final server = await FakeAiServer.start(
    replies: const ['Hello from the ', 'spawned fixture.'],
  );
  stdout.writeln('$readyPrefix${jsonEncode({'port': server.port})}');
  // The same liveness contract as the real server: stdin closes, we exit.
  await stdin.drain<void>();
  await server.stop();
  exit(0);
}

/// A loopback port that is **held but not served** — "VS Code is not
/// running" on a port nobody else can take.
///
/// The obvious way to get a port with nothing on it is to bind port 0, note
/// the number and close the socket. That releases the port, and until the
/// test aims at it anything on the machine may bind it — another run of this
/// same suite, whose fake servers bind ephemeral ports, is the likely one, and
/// a stranger that answers the discovery handshake turns "unavailable" into
/// "available" for reasons the test cannot see. So the socket stays bound, and
/// every connection is closed at once: to a client that is indistinguishable
/// from no server, and [serve] later turns the same socket into one.
final class ReservedPort {
  final ServerSocket _socket;
  void Function(Socket socket)? _handler;

  ReservedPort._(this._socket) {
    _socket.listen((socket) {
      final handler = _handler;
      if (handler == null) {
        socket.destroy();
      } else {
        handler(socket);
      }
    });
  }

  static Future<ReservedPort> bind() async =>
      ReservedPort._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  int get port => _socket.port;

  /// Starts answering on this port as a [FakeAiServer].
  FakeAiServer serve({
    List<String> replies = const ['Hello from the fixture.'],
    FakeAiServerBehaviour behaviour = FakeAiServerBehaviour.succeed,
    String workspaceName = 'agent-sdk-fixture',
  }) => FakeAiServer._serving(
    this,
    replies: replies,
    behaviour: behaviour,
    workspaceName: workspaceName,
    dripInterval: const Duration(milliseconds: 200),
    thinkingBeats: 5,
  );

  Future<void> release() => _socket.close();
}

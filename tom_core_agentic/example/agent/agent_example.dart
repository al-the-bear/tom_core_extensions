// Runnable demo of the agent unit, end to end and without a network.
//
// Four acts, in the order an editor session actually goes through them:
//
//   1. a sidecar store round-trips a model, and degrades when the file is
//      damaged — one bad entry costs one entry, not the file;
//   2. the bridge scan discovers servers and a persisted choice is matched
//      back against them by *endpoint*, not by host string;
//   3. `ReconnectCoordinator` runs the back-off against an injected scan
//      service and an injected delay, resolving all three ways;
//   4. `AgentSendEngine` streams a prompt, and refreshes the per-spec session
//      id when a resumed session turns out to be stale.
//
// Every seam that would otherwise need a socket, a clock or an API key is
// injected: the port scanner, the reconnect delay, and the Agent SDK transport.
// So the demo is deterministic, runs in well under a second, and touches
// nothing outside a temporary directory it deletes on the way out.
//
// Run with:
//   dart run --enable-asserts example/agent/agent_example.dart

import 'dart:async';
import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';
// Only the four transport names the injected double needs. The two packages
// both declare a `QueuedPrompt`, and this example is about the one in
// `tom_core_agentic`.
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart'
    show AgentSdkClient, AgentSdkToolRegistry, AgentSdkTransport, CanUseTool;

import '../require_asserts.dart';

Future<void> main() async {
  requireAsserts();

  final workspace = Directory.systemTemp.createTempSync('tom_agent_example');
  try {
    _demoStoreRoundTrip(workspace);
    _demoStoreDegradation(workspace);
    await _demoBridgeDiscovery();
    await _demoReconnect();
    await _demoSend(workspace);
  } finally {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  }

  print('\nagent demo completed.');
}

// ---------------------------------------------------------------------------
// 1a. A sidecar store round-trips its model.
// ---------------------------------------------------------------------------
void _demoStoreRoundTrip(Directory workspace) {
  print('== store round-trip ==');

  // Each store is constructed with the file it owns. In an editor the store is
  // built by `resolveDefault()`, which honours an environment override
  // (`TOM_SPECS_QUEUE_FILE` for this one) and otherwise falls back to
  // `<cwd>/.tom/prompt_queue.yaml`. Naming the file directly is what a test —
  // or a demo — does instead, and is the whole of the difference.
  final store = PromptQueueStore(
    File('${workspace.path}/.tom/prompt_queue.yaml'),
  );

  // Nothing persisted yet: an absent file is an empty queue, not an error.
  assert(store.load().isEmpty);
  print('  no file yet -> ${store.load().length} items');

  final queued = QueuedPrompt(
    id: 'p-1',
    originalText: 'Summarise the spec',
    expandedText: 'Summarise the spec',
    createdAt: '2026-01-02T03:04:05.000Z',
    status: QueuedPromptStatus.staged,
    transport: QueuedTransport.anthropic,
  );
  store.save([queued]);

  final loaded = store.load();
  assert(loaded.length == 1);
  assert(loaded.single.id == 'p-1');
  assert(loaded.single.originalText == 'Summarise the spec');
  assert(loaded.single.status == QueuedPromptStatus.staged);
  assert(loaded.single.transport == QueuedTransport.anthropic);
  // Timestamps are persisted as the ISO-8601 text they arrived as, so a
  // round-trip cannot shift one into another zone or lose its precision.
  assert(loaded.single.createdAt == queued.createdAt);
  print(
    '  saved and reloaded: ${loaded.single.id} '
    '(${loaded.single.status.name}, ${loaded.single.transport?.name})',
  );

  // The file is YAML a person can open and edit, which is why the degradation
  // rules below exist at all.
  final text = store.file.readAsStringSync();
  assert(text.contains('version: 1'));
  assert(text.contains('items:'));
  print('  on disk: ${text.split('\n').first}');
}

// ---------------------------------------------------------------------------
// 1b. Damage costs a file or an entry, never a crash.
// ---------------------------------------------------------------------------
void _demoStoreDegradation(Directory workspace) {
  print('\n== store degradation ==');

  // Parse damage costs the file. A sidecar that does not parse reads as a
  // sidecar that is not there, because to a caller about to fall back on its
  // defaults those are the same file.
  final broken = PromptQueueStore(File('${workspace.path}/broken.yaml'))
    ..file.writeAsStringSync('items: [this is not: valid: yaml');
  assert(broken.load().isEmpty);
  print('  unparseable file -> ${broken.load().length} items, no throw');

  // Shape damage costs one entry. Three rows here: one good, one with an
  // unusable id, one whose field has the wrong type. Only the good row
  // survives — and, the point of the rule, it survives *beside* the bad ones
  // rather than being discarded with them.
  final mixed = PromptQueueStore(File('${workspace.path}/mixed.yaml'))
    ..file.writeAsStringSync('''
version: 1
items:
  - id: good
    originalText: kept
    expandedText: kept
    createdAt: 2026-01-02T03:04:05.000Z
  - id: 7
    originalText: numeric id
    expandedText: numeric id
    createdAt: 2026-01-02T03:04:05.000Z
  - originalText: no id at all
    expandedText: no id at all
    createdAt: 2026-01-02T03:04:05.000Z
''');
  final survivors = mixed.load();
  assert(survivors.length == 1);
  assert(survivors.single.id == 'good');
  print(
    '  3 rows, 2 unusable -> kept ${survivors.map((p) => p.id).join(', ')}',
  );

  // An entry with no usable id is skipped rather than given a synthetic one:
  // it could never afterwards be selected, edited or deleted, so materialising
  // it would turn a recoverable data error into a permanent orphan.
}

// ---------------------------------------------------------------------------
// 2. Discovering bridges, and matching a saved binding back against them.
// ---------------------------------------------------------------------------
Future<void> _demoBridgeDiscovery() async {
  print('\n== bridge discovery ==');

  // The scanner is the seam: in production it opens sockets across
  // 19900-19909 and runs the window-identity handshake. Here it answers from a
  // table, so the demo needs no VS Code.
  final service = BridgeConnectionService(
    scanner:
        ({
          required String host,
          required int minPort,
          required int maxPort,
        }) async => {19901: 'tom_specs', 19903: 'other_workspace'},
  );

  final servers = await service.scan();
  assert(servers.length == 2);
  // Ascending port order, and every result is `available` — deciding which one
  // is bound is the caller's business, not the scan's.
  assert(servers.first.port == 19901);
  assert(servers.every((s) => s.status == BridgeServerStatus.available));
  for (final server in servers) {
    print('  found $server');
  }

  // A binding restored from the sidecar carries only host and port. It is
  // matched back against the scan by *endpoint*: the port must be equal and
  // the host must name the same interface, which is weaker than being the same
  // string. `localhost` and `127.0.0.1` are one endpoint, so a binding written
  // with one spelling still finds a server reported with the other.
  const bound = BridgeChoice(host: 'localhost', port: 19901);
  assert(bound.matches(servers.first));
  assert(!bound.matches(servers.last));
  print(
    '  binding ${bound.host}:${bound.port} matches '
    '${servers.first.host}:${servers.first.port}',
  );

  // Value equality is a different question and stays textual, because it has
  // to keep agreeing with what was persisted.
  assert(bound != BridgeChoice(host: defaultBridgeHost, port: 19901));
}

// ---------------------------------------------------------------------------
// 3. The reconnect back-off, resolving all three ways.
// ---------------------------------------------------------------------------
Future<void> _demoReconnect() async {
  print('\n== reconnect ==');

  const bound = BridgeChoice(host: defaultBridgeHost, port: 19901);
  final slept = <Duration>[];
  // The delay is injected, so the real 10/30/60-second schedule runs
  // instantly. Recording what was asked for is how the demo can show the
  // schedule without waiting for it.
  Future<void> instantly(Duration d) async => slept.add(d);

  // (a) The window comes back on the second attempt, serving the workspace it
  //     served before: rebind silently and auto-resend.
  var attempts = 0;
  final flaky = BridgeConnectionService(
    scanner: ({required host, required minPort, required maxPort}) async =>
        ++attempts >= 2 ? {19901: 'tom_specs'} : <int, String>{},
  );
  final same = await ReconnectCoordinator(
    service: flaky,
    delay: instantly,
  ).reconnect(bound: bound, boundWorkspace: 'tom_specs');
  assert(same.resolution == ReconnectResolution.sameWorkspace);
  assert(same.attempts == 2);
  assert(same.server?.workspace == 'tom_specs');
  assert(slept.length == 2 && slept.first == const Duration(seconds: 10));
  print(
    '  same workspace after ${same.attempts} attempts '
    '(waited ${slept.map((d) => d.inSeconds).join('/')}s)',
  );

  // (b) The port answers, but the window now has a different folder open.
  //     Binding to it would silently move the session to another workspace, so
  //     the caller must confirm first.
  final moved = BridgeConnectionService(
    scanner: ({required host, required minPort, required maxPort}) async => {
      19901: 'something_else',
    },
  );
  final different = await ReconnectCoordinator(
    service: moved,
    delay: instantly,
  ).reconnect(bound: bound, boundWorkspace: 'tom_specs');
  assert(different.resolution == ReconnectResolution.differentWorkspace);
  assert(different.attempts == 1);
  print('  different workspace: ${different.server?.workspace}');

  // (c) Nothing ever answers. Every back-off runs, and a scan that *throws* is
  //     swallowed as "no servers" — a transient scan error becomes another
  //     silent attempt rather than aborting the recovery.
  final gone = BridgeConnectionService(
    scanner: ({required host, required minPort, required maxPort}) async =>
        throw const SocketException('nothing listening'),
  );
  final still = await ReconnectCoordinator(
    service: gone,
    delay: instantly,
  ).reconnect(bound: bound, boundWorkspace: 'tom_specs');
  assert(still.resolution == ReconnectResolution.stillGone);
  assert(still.attempts == defaultReconnectBackoff.length);
  assert(still.server == null);
  print('  still gone after ${still.attempts} attempts');

  // What the caller re-sends is the *original* prompt behind the profile's
  // prefix. Composition never stacks, so two drops in a row do not nest two
  // prefixes.
  const prefix = AgentProfile.defaultInterruptRetryPrefix;
  final once = composeInterruptRetry(prefix, 'explain this spec');
  final twice = composeInterruptRetry(prefix, 'explain this spec');
  assert(once == twice);
  assert(once.startsWith(prefix) && once.endsWith('explain this spec'));
  print('  resend body: ${once.split('\n').first}');
}

// ---------------------------------------------------------------------------
// 4. Sending a prompt, and recovering from a stale session id.
// ---------------------------------------------------------------------------
Future<void> _demoSend(Directory workspace) async {
  print('\n== send ==');

  final sessions = SpecSessionStore(
    File('${workspace.path}/.tom/agent_session.yaml'),
  );

  // A first send with nothing stored: the engine resumes nothing, streams the
  // answer, and persists the session id the turn came back with.
  final fresh = _ScriptedTransport(
    (_) => [_assistantText('Hello from the agent.'), _successResult('s-1')],
  );
  final first = await AgentSendEngine(
    client: AgentSdkClient(fresh),
    sessionStore: sessions,
    config: const AgentSendConfig(),
  ).send('say hello').toList();
  await fresh.dispose();

  assert(first.first is AgentSendStarted);
  final text = first.whereType<AgentSendChunk>().map((c) => c.text).join();
  assert(text == 'Hello from the agent.');
  assert(first.whereType<AgentSendCompleted>().single.sessionId == 's-1');
  assert(sessions.load() == 's-1');
  print('  first send: "$text" (session ${sessions.load()})');

  // The next send resumes that id. Here the other side has forgotten it, so
  // the turn fails with a session-shaped error. Because nothing had streamed
  // yet, the engine drops the stored id and retries once — and says so with an
  // `AgentSendSessionRefreshed` before the retry's chunks, so a UI can show
  // that the conversation restarted rather than that the answer stuttered.
  final stale = _ScriptedTransport((params) {
    final resume = (params['options'] as Map?)?['resume'] as String?;
    return resume == 's-1'
        ? [_errorResult('Session not found: invalid session id')]
        : [_assistantText('Recovered.'), _successResult('s-2')];
  });
  final second = await AgentSendEngine(
    client: AgentSdkClient(stale),
    sessionStore: sessions,
    config: const AgentSendConfig(),
  ).send('say hello again').toList();
  await stale.dispose();

  assert(second.whereType<AgentSendSessionRefreshed>().length == 1);
  assert(
    second.whereType<AgentSendChunk>().map((c) => c.text).join() ==
        'Recovered.',
  );
  assert(second.whereType<AgentSendCompleted>().single.sessionId == 's-2');
  assert(sessions.load() == 's-2');
  print('  stale session refreshed, retried once, now ${sessions.load()}');

  // The retry is allowed exactly once, and only before anything has streamed —
  // a second failure, or a failure after output, ends the send as a failure
  // rather than repeating an answer the user has already seen.
  final failing = _ScriptedTransport(
    (_) => [_errorResult('Session expired again')],
  );
  final third = await AgentSendEngine(
    client: AgentSdkClient(failing),
    sessionStore: sessions,
    config: const AgentSendConfig(),
  ).send('and again').toList();
  await failing.dispose();

  assert(third.whereType<AgentSendSessionRefreshed>().length == 1);
  assert(third.whereType<AgentSendFailed>().length == 1);
  assert(third.whereType<AgentSendCompleted>().isEmpty);
  print(
    '  second failure ends as: '
    '${third.whereType<AgentSendFailed>().single.message}',
  );
}

// ---------------------------------------------------------------------------
// The injected transport. It stands where a socket to VS Code would be, and
// answers each started query from a script keyed on the query's own options —
// which is what lets the stale-session case above branch on `resume`.
// ---------------------------------------------------------------------------
class _ScriptedTransport implements AgentSdkTransport {
  _ScriptedTransport(this.script);

  final List<Map<String, dynamic>> Function(Map<String, dynamic> params) script;

  final _chunks = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get chunks => _chunks.stream;

  @override
  Future<void> startQuery(Map<String, dynamic> params) async {
    final streamId = params['streamId'];
    final messages = script(params);
    // Emitted after `startQuery` returns: the query subscribes to `chunks`
    // before calling it, so anything emitted synchronously here would be sent
    // to nobody.
    unawaited(
      Future<void>(() async {
        for (final message in messages) {
          _chunks.add({'streamId': streamId, 'message': message});
        }
        _chunks.add({'streamId': streamId, 'done': true});
      }),
    );
  }

  @override
  Future<void> cancelQuery(String streamId) async {}

  @override
  void registerTools(String streamId, AgentSdkToolRegistry registry) {}

  @override
  void unregisterTools(String streamId) {}

  @override
  void registerCanUseTool(String streamId, CanUseTool callback) {}

  @override
  void unregisterCanUseTool(String streamId) {}

  Future<void> dispose() => _chunks.close();
}

Map<String, dynamic> _assistantText(String text) => {
  'type': 'assistant',
  'message': {
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

Map<String, dynamic> _successResult(String sessionId) => {
  'type': 'result',
  'subtype': 'success',
  'is_error': false,
  'session_id': sessionId,
  'result': 'ok',
};

Map<String, dynamic> _errorResult(String text) => {
  'type': 'result',
  'subtype': 'error_during_execution',
  'is_error': true,
  'result': text,
};

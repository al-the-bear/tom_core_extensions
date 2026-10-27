// Tests for the editor agent send pipeline: streaming a prompt through the
// Agent SDK and refreshing the per-spec session id on a session error.
//
// The SDK transport is faked so the loop is unit-testable without a socket: the
// fake emits scripted `agentSdk.chunk` payloads for each started query, keyed by
// the engine-issued streamId, and can branch on whether the query is resuming a
// stored session (so a "stale session" error and its fresh retry are scripted).

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_basics/utilities.dart' show TomCancellationSource;
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';

/// A transport double that emits a scripted message sequence for every started
/// query. [script] maps the `startQuery` params (which carry the serialized
/// `options`, including `resume`) to the raw `SDKMessage` JSON maps to stream
/// back, in order, before a terminal `done`.
class _ScriptedTransport implements AgentSdkTransport {
  _ScriptedTransport(this.script);

  final List<Map<String, dynamic>> Function(Map<String, dynamic> params) script;

  final _chunks = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> started = [];

  @override
  Stream<Map<String, dynamic>> get chunks => _chunks.stream;

  @override
  Future<void> startQuery(Map<String, dynamic> params) async {
    started.add(params);
    final streamId = params['streamId'];
    final messages = script(params);
    // Emit after startQuery returns; the query's chunk subscription is already
    // attached (AgentSdkClient subscribes in onListen before calling start).
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

/// A transport double that streams one assistant chunk and then *stalls* — it
/// never emits the terminal `done`, so the send stays in flight until a
/// [TomCancellationToken] interrupts it. Records the stream ids passed to
/// [cancelQuery] so a test can assert the remote query was aborted.
class _StallingTransport implements AgentSdkTransport {
  final _chunks = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> started = [];
  final List<String> cancelled = [];

  @override
  Stream<Map<String, dynamic>> get chunks => _chunks.stream;

  @override
  Future<void> startQuery(Map<String, dynamic> params) async {
    started.add(params);
    final streamId = params['streamId'];
    // One chunk, then silence — no `done`, so the send never completes on its
    // own; only a cancel ends it.
    unawaited(
      Future<void>(() async {
        _chunks.add({'streamId': streamId, 'message': _assistant('partial')});
      }),
    );
  }

  @override
  Future<void> cancelQuery(String streamId) async {
    cancelled.add(streamId);
  }

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

Map<String, dynamic> _assistant(String text) => {
  'type': 'assistant',
  'message': {
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

Map<String, dynamic> _success(String sessionId) => {
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

String? _resumeOf(Map<String, dynamic> params) =>
    (params['options'] as Map?)?['resume'] as String?;

SpecSessionStore _tempStore() {
  final dir = Directory.systemTemp.createTempSync('tom_specs_session_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return SpecSessionStore(File('${dir.path}/agent_session.yaml'));
}

void main() {
  group('specSessionLooksLikeError', () {
    test('matches session / message / msg, case-insensitively', () {
      expect(specSessionLooksLikeError('Invalid SESSION id'), isTrue);
      expect(specSessionLooksLikeError('bad message format'), isTrue);
      expect(specSessionLooksLikeError('missing msg field'), isTrue);
    });

    test('does not match unrelated errors', () {
      expect(specSessionLooksLikeError('rate limit exceeded'), isFalse);
      expect(specSessionLooksLikeError('connection refused'), isFalse);
    });
  });

  group('SpecSessionStore', () {
    test('round-trips a session id and clears it', () {
      final store = _tempStore();
      expect(store.load(), isNull);

      store.save('sess-123');
      expect(store.load(), 'sess-123');

      store.clear();
      expect(store.load(), isNull);
    });
  });

  group('AgentSendConfig.buildOptions', () {
    test('maps profile system prompt and threads the resume id', () {
      final config = AgentSendConfig.fromProfile(
        const AgentProfile(id: 'p', name: 'P', systemPrompt: 'Be precise.'),
        model: 'claude-x',
      );
      final options = config.buildOptions(resumeSessionId: 'sess-1');

      expect(options.model, 'claude-x');
      expect(options.resume, 'sess-1');
      expect(options.systemPrompt, isA<SystemPromptText>());
      expect((options.systemPrompt as SystemPromptText).text, 'Be precise.');
    });

    test('the tool-approval mode reaches the SDK as a permission mode', () {
      expect(
        permissionModeForApproval(ToolApprovalMode.always),
        PermissionMode.default_,
      );
      expect(
        permissionModeForApproval(ToolApprovalMode.never),
        PermissionMode.acceptEdits,
        reason: 'no approval for writes is acceptEdits, not bypassPermissions',
      );
      final options = AgentSendConfig.fromProfile(
        const AgentProfile(
          id: 'p',
          name: 'P',
          toolApprovalMode: ToolApprovalMode.never,
        ),
      ).buildOptions();
      expect(options.toJson()['permissionMode'], 'acceptEdits');
    });

    test('settings fill what the profile leaves unset; the profile wins', () {
      const settings = AgentSettings(
        maxRounds: 7,
        toolApprovalMode: ToolApprovalMode.never,
      );
      final fromSettings = AgentSendConfig.fromProfile(
        const AgentProfile(id: 'p', name: 'P'),
        settings: settings,
      );
      expect(fromSettings.maxTurns, 7);
      expect(fromSettings.permissionMode, PermissionMode.acceptEdits);

      final fromProfile = AgentSendConfig.fromProfile(
        const AgentProfile(
          id: 'p',
          name: 'P',
          maxRounds: 3,
          toolApprovalMode: ToolApprovalMode.always,
        ),
        settings: settings,
      );
      expect(fromProfile.maxTurns, 3);
      expect(fromProfile.permissionMode, PermissionMode.default_);
    });

    test('an explicit argument wins over profile and settings', () {
      final config = AgentSendConfig.fromProfile(
        const AgentProfile(
          id: 'p',
          name: 'P',
          maxRounds: 3,
          toolApprovalMode: ToolApprovalMode.always,
        ),
        settings: const AgentSettings(maxRounds: 7),
        maxTurns: 11,
        permissionMode: PermissionMode.plan,
      );
      expect(config.maxTurns, 11);
      expect(config.permissionMode, PermissionMode.plan);
    });

    test('with no approval mode anywhere, the SDK default applies', () {
      final options = AgentSendConfig.fromProfile(
        const AgentProfile(id: 'p', name: 'P'),
        settings: const AgentSettings(),
      ).buildOptions();
      expect(options.toJson().containsKey('permissionMode'), isFalse);
    });

    test('the two fields the SDK has no destination for are not sent', () {
      // Kept for the providers that will take them. What is asserted is that
      // nothing pretends to send them: the wire carries no key for either.
      final wire = AgentSendConfig.fromProfile(
        const AgentProfile(
          id: 'p',
          name: 'P',
          maxTokens: 1000,
          promptCachingEnabled: true,
        ),
      ).buildOptions().toJson();
      for (final key in wire.keys) {
        expect(key.toLowerCase(), isNot(contains('token')));
        expect(key.toLowerCase(), isNot(contains('cach')));
      }
    });

    group('thinking', () {
      Object? wireThinking(AgentProfile profile, [AgentSettings? settings]) =>
          AgentSendConfig.fromProfile(
            profile,
            settings: settings,
          ).buildOptions().toJson()['thinking'];

      test('unset leaves the SDK default: nothing is sent', () {
        expect(
          AgentSendConfig.fromProfile(
            const AgentProfile(id: 'p', name: 'P'),
            settings: const AgentSettings(),
          ).buildOptions().toJson().containsKey('thinking'),
          isFalse,
        );
      });

      test('enabled without a budget is adaptive', () {
        expect(
          wireThinking(
            const AgentProfile(id: 'p', name: 'P', thinkingEnabled: true),
          ),
          {'type': 'adaptive'},
        );
      });

      test('enabled with a budget is a fixed budget', () {
        expect(
          wireThinking(
            const AgentProfile(
              id: 'p',
              name: 'P',
              thinkingEnabled: true,
              thinkingBudgetTokens: 4096,
            ),
          ),
          {'type': 'enabled', 'budgetTokens': 4096},
        );
      });

      test('disabled is sent as disabled', () {
        expect(
          wireThinking(
            const AgentProfile(id: 'p', name: 'P', thinkingEnabled: false),
          ),
          {'type': 'disabled'},
        );
      });

      test('the profile overrides the settings, which fill in for it', () {
        expect(
          wireThinking(
            const AgentProfile(id: 'p', name: 'P', thinkingEnabled: false),
            const AgentSettings(thinkingEnabled: true),
          ),
          {'type': 'disabled'},
        );
        expect(
          wireThinking(
            const AgentProfile(id: 'p', name: 'P'),
            const AgentSettings(thinkingEnabled: true),
          ),
          {'type': 'adaptive'},
        );
      });

      test('an explicit argument wins over both', () {
        expect(
          AgentSendConfig.fromProfile(
            const AgentProfile(id: 'p', name: 'P', thinkingEnabled: true),
            thinking: const ThinkingDisabled(),
          ).buildOptions().toJson()['thinking'],
          {'type': 'disabled'},
        );
      });
    });

    test('omits resume from the wire when no session id is supplied', () {
      final options = const AgentSendConfig().buildOptions();
      expect(options.toJson().containsKey('resume'), isFalse);
    });
  });

  group('AgentSendEngine.send', () {
    test('streams assistant text and persists the session id', () async {
      final transport = _ScriptedTransport(
        (_) => [_assistant('hello'), _success('s-new')],
      );
      addTearDown(transport.dispose);
      final store = _tempStore();
      final engine = AgentSendEngine(
        client: AgentSdkClient(transport),
        sessionStore: store,
        config: const AgentSendConfig(),
      );

      final events = await engine.send('hi').toList();

      expect(events.first, isA<AgentSendStarted>());
      expect(
        events.whereType<AgentSendChunk>().map((c) => c.text).join(),
        'hello',
      );
      final completed = events.whereType<AgentSendCompleted>().single;
      expect(completed.sessionId, 's-new');
      // The id is persisted so the next send resumes it.
      expect(store.load(), 's-new');
    });

    test(
      'refreshes the session id on a session error and retries fresh',
      () async {
        // First attempt resumes the stale id and fails with a session error; the
        // retry (no resume) succeeds with a fresh id.
        final transport = _ScriptedTransport((params) {
          if (_resumeOf(params) == 'stale-id') {
            return [_errorResult('Session not found: invalid session id')];
          }
          return [_assistant('recovered'), _success('s-fresh')];
        });
        addTearDown(transport.dispose);

        final store = _tempStore()..save('stale-id');
        final engine = AgentSendEngine(
          client: AgentSdkClient(transport),
          sessionStore: store,
          config: const AgentSendConfig(),
        );

        final events = await engine.send('hi').toList();

        // A refresh happened, then the fresh attempt streamed and completed.
        expect(events.whereType<AgentSendSessionRefreshed>(), hasLength(1));
        expect(
          events.whereType<AgentSendChunk>().map((c) => c.text).join(),
          'recovered',
        );
        expect(
          events.whereType<AgentSendCompleted>().single.sessionId,
          's-fresh',
        );
        // The sidecar now holds the fresh id, not the stale one.
        expect(store.load(), 's-fresh');

        // Two queries: the first resumed the stale id, the second was fresh.
        expect(transport.started, hasLength(2));
        expect(_resumeOf(transport.started[0]), 'stale-id');
        expect(_resumeOf(transport.started[1]), isNull);
      },
    );

    test(
      'a cancel token interrupts the query and ends the stream silently',
      () async {
        final transport = _StallingTransport();
        addTearDown(transport.dispose);
        final engine = AgentSendEngine(
          client: AgentSdkClient(transport),
          sessionStore: _tempStore(),
          config: const AgentSendConfig(),
        );

        final source = TomCancellationSource();
        final events = <AgentSendEvent>[];
        // Drive the cold stream; cancel once the first chunk has streamed (the
        // transport then stalls forever, so without the cancel this never ends).
        final done = engine.send('hi', cancelToken: source.token).forEach((e) {
          events.add(e);
          if (e is AgentSendChunk) source.cancel();
        });
        await done.timeout(const Duration(seconds: 5));

        // The partial text streamed, but a user-driven stop is neither a
        // completion nor a failure — no terminal event is emitted.
        expect(
          events.whereType<AgentSendChunk>().map((c) => c.text).join(),
          'partial',
        );
        expect(events.whereType<AgentSendCompleted>(), isEmpty);
        expect(events.whereType<AgentSendFailed>(), isEmpty);
        // The remote query was aborted through the transport cancel path.
        final streamId = transport.started.single['streamId'] as String;
        expect(transport.cancelled, contains(streamId));
      },
    );

    test('a non-session error fails without refreshing or retrying', () async {
      final transport = _ScriptedTransport(
        (_) => [_errorResult('rate limit exceeded')],
      );
      addTearDown(transport.dispose);

      final store = _tempStore()..save('keep-id');
      final engine = AgentSendEngine(
        client: AgentSdkClient(transport),
        sessionStore: store,
        config: const AgentSendConfig(),
      );

      final events = await engine.send('hi').toList();

      expect(events.whereType<AgentSendSessionRefreshed>(), isEmpty);
      expect(
        events.whereType<AgentSendFailed>().single.message,
        contains('rate limit'),
      );
      // The stored id is untouched on a non-session failure.
      expect(store.load(), 'keep-id');
      expect(transport.started, hasLength(1));
    });
  });
}

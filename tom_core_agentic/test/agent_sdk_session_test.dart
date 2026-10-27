// Agent-SDK session modes `brain` + `quest`. Covers the JSON store round-trip,
// the three `AgentSdkSessionStrategy` implementations, the session-error
// predicate, and the provider's resume / evict-and-retry-once / record
// behaviour driven over a scripted `AgentSdkTransport` — without a live VS Code
// bridge.
//
// Migrated from `tom_brain_run/test/r43_agent_sdk_session_test.dart` when the
// provider layer moved into `tom_core_agentic`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:test/test.dart';

/// One scripted SDK query response: the messages to replay then either an
/// `error` chunk or a `done` chunk.
class _Attempt {
  _Attempt({
    this.messages = const <Map<String, dynamic>>[],
    this.error,
    this.delay = Duration.zero,
  });

  final List<Map<String, dynamic>> messages;
  final String? error;

  /// How long this attempt takes before it replays. Puts real elapsed time
  /// inside each attempt, so a retry's report can be checked for a
  /// `wallClockMs` that spans *both* attempts rather than just the last one.
  final Duration delay;
}

/// A fake transport that replays a *list* of [attempts], one per `query` call,
/// so the evict-and-retry path (which issues a second query) can be scripted.
/// Records the `resume` option seen on each query in [resumesSeen].
class _ScriptedAgentSdkTransport extends AgentSdkTransport {
  _ScriptedAgentSdkTransport(this.attempts);

  final List<_Attempt> attempts;
  int _index = 0;
  final List<Object?> resumesSeen = <Object?>[];

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get chunks => _controller.stream;

  @override
  Future<void> startQuery(Map<String, dynamic> params) async {
    final streamId = params['streamId'] as String;
    final options = (params['options'] as Map?)?.cast<String, dynamic>();
    resumesSeen.add(options == null ? null : options['resume']);
    final attempt =
        attempts[_index < attempts.length ? _index : attempts.length - 1];
    _index++;
    void replay() {
      for (final message in attempt.messages) {
        if (_controller.isClosed) return;
        _controller.add({'streamId': streamId, 'message': message});
      }
      if (_controller.isClosed) return;
      if (attempt.error != null) {
        _controller.add({'streamId': streamId, 'error': attempt.error});
      } else {
        _controller.add({'streamId': streamId, 'done': true});
      }
    }

    if (attempt.delay == Duration.zero) {
      scheduleMicrotask(replay);
    } else {
      Timer(attempt.delay, replay);
    }
  }

  @override
  Future<void> cancelQuery(String streamId) async {}
}

const _wire = WirePrompt(
  system: 'ANCHOR\n\nWhat is the capital of France?',
  anchorHash: 'anchor-hash-A1',
  roleId: 'assistant_to_user',
  templateSha: 'template-sha-T1',
);

Map<String, dynamic> _successResult(String sessionId, {String text = 'ok'}) => {
  'type': 'result',
  'subtype': 'success',
  'is_error': false,
  'result': text,
  'duration_ms': 12,
  'usage': {'input_tokens': 5, 'output_tokens': 9},
  'session_id': sessionId,
};

/// A store path whose parent directory can never be created, because an
/// ancestor component is an ordinary file. Both `create(recursive: true)` and
/// the write itself then fail with a [FileSystemException] — the same shape a
/// read-only volume or a revoked permission produces, but reproducible on every
/// platform and without depending on the uid the suite runs as.
File _unwritableFile(Directory tmp) {
  File('${tmp.path}/blocker').writeAsStringSync('I am a file, not a folder.');
  return File('${tmp.path}/blocker/sessions/agent_sdk_sessions.json');
}

AgentSdkLlmProvider _provider(
  _ScriptedAgentSdkTransport transport,
  AgentSdkSessionStrategy strategy,
) => AgentSdkLlmProvider(
  id: 'claude:sonnet:test',
  defaultModel: 'claude-sonnet-4-6',
  bridgePort: 19900,
  clientFactory: (port) async => AgentSdkClient(transport),
  sessionStrategy: strategy,
);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('r43_agent_sdk_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('AgentSdkSessionStore — JSON round-trip', () {
    test('put → lookup → remove, persisting across instances', () async {
      final file = File('${tmp.path}/sessions/agent_sdk_sessions.json');
      final store = AgentSdkSessionStore(file);

      expect(await store.lookup('tb-1'), isNull);
      await store.put('tb-1', 'claude-aaa');
      expect(await store.lookup('tb-1'), 'claude-aaa');
      expect(file.existsSync(), isTrue);

      // A fresh instance reads what the first wrote.
      final reopened = AgentSdkSessionStore(file);
      expect(await reopened.lookup('tb-1'), 'claude-aaa');

      await store.remove('tb-1');
      expect(await store.lookup('tb-1'), isNull);
    });

    test('a missing file reads as empty', () async {
      final store = AgentSdkSessionStore(
        File('${tmp.path}/never_written.json'),
      );
      expect(await store.lookup('x'), isNull);
    });

    test('a corrupt file degrades to empty rather than throwing', () async {
      final file = File('${tmp.path}/corrupt.json')
        ..writeAsStringSync('not json {{{');
      final store = AgentSdkSessionStore(file);
      expect(await store.lookup('x'), isNull);
    });

    test('put on an unwritable store degrades instead of throwing', () async {
      final store = AgentSdkSessionStore(_unwritableFile(tmp));

      await expectLater(store.put('tb-1', 'claude-aaa'), completes);
      // The write is lost, but the id is not: `put` updates the in-memory
      // cache before flushing, so this process still resumes the session and
      // only a restart pays the fresh call the contract allows for.
      expect(await store.lookup('tb-1'), 'claude-aaa');
    });

    test(
      'remove on an unwritable store degrades instead of throwing',
      () async {
        final store = AgentSdkSessionStore(_unwritableFile(tmp));
        await store.put('tb-1', 'claude-aaa');

        await expectLater(store.remove('tb-1'), completes);
        expect(await store.lookup('tb-1'), isNull);
      },
    );
  });

  group('strategies', () {
    test('NoSessionStrategy resolves null and never records', () async {
      const strategy = NoSessionStrategy();
      expect(
        await strategy.resumeIdFor(const LlmOptions(sessionId: 'tb-1')),
        isNull,
      );
      // record / evict are no-ops (must not throw).
      await strategy.record(LlmOptions.empty, 'claude-aaa');
      await strategy.evict(LlmOptions.empty);
    });

    test(
      'BrainSessionStrategy keys by brainSessionId; null key → fresh',
      () async {
        final store = AgentSdkSessionStore(
          File('${tmp.path}/agent_sdk_sessions.json'),
        );
        final strategy = BrainSessionStrategy(store);

        // Null session (background / boot) always starts fresh, never stored.
        expect(await strategy.resumeIdFor(LlmOptions.empty), isNull);
        await strategy.record(LlmOptions.empty, 'claude-zzz');
        expect(await store.lookup(''), isNull);

        const opts = LlmOptions(sessionId: 'tb-7');
        expect(await strategy.resumeIdFor(opts), isNull);
        await strategy.record(opts, 'claude-bbb');
        expect(await strategy.resumeIdFor(opts), 'claude-bbb');
        await strategy.evict(opts);
        expect(await strategy.resumeIdFor(opts), isNull);
      },
    );

    test(
      'QuestSessionStrategy reads sessionId; missing → null; read-only',
      () async {
        final root = Directory('${tmp.path}/quests')..createSync();
        final histDir = Directory('${root.path}/tom_brain/history')
          ..createSync(recursive: true);
        final file = File('${histDir.path}/default.session.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'sessionId': 'claude-quest-1',
              'updatedAt': '2026-06-13T00:00:00Z',
              'model': 'claude-sonnet-4-6',
            }),
          );

        final strategy = QuestSessionStrategy(
          questHistoryRoot: root.path,
          questId: 'tom_brain',
          sessionKey: 'default',
        );
        expect(await strategy.resumeIdFor(LlmOptions.empty), 'claude-quest-1');

        // record / evict never mutate the file.
        final before = file.readAsStringSync();
        await strategy.record(LlmOptions.empty, 'claude-new');
        await strategy.evict(LlmOptions.empty);
        expect(file.readAsStringSync(), before);

        // But an evicted id is remembered: the same file no longer resumes,
        // so a stale quest session costs one failed resume, not one per call.
        expect(await strategy.resumeIdFor(LlmOptions.empty), isNull);

        // A file rewritten with a new id (the editor started a new session)
        // is resumed again.
        file.writeAsStringSync(
          jsonEncode(<String, Object?>{'sessionId': 'claude-quest-2'}),
        );
        expect(await strategy.resumeIdFor(LlmOptions.empty), 'claude-quest-2');

        // A missing session file degrades to a fresh session.
        final missing = QuestSessionStrategy(
          questHistoryRoot: root.path,
          questId: 'tom_brain',
          sessionKey: 'chat',
        );
        expect(await missing.resumeIdFor(LlmOptions.empty), isNull);
      },
    );
  });

  group('agentSdkLooksLikeSessionError', () {
    test('fires on session + failure cue, not on either alone', () {
      expect(agentSdkLooksLikeSessionError('Session abc not found'), isTrue);
      expect(agentSdkLooksLikeSessionError('invalid session id'), isTrue);
      expect(agentSdkLooksLikeSessionError('session has expired'), isTrue);
      // No failure cue.
      expect(agentSdkLooksLikeSessionError('session resumed cleanly'), isFalse);
      // No session word.
      expect(agentSdkLooksLikeSessionError('model not found'), isFalse);
    });
  });

  group('provider — brain mode', () {
    test(
      'resumes the stored Claude session id, then records the new one',
      () async {
        final store = AgentSdkSessionStore(
          File('${tmp.path}/agent_sdk_sessions.json'),
        );
        await store.put('tb-1', 'claude-old');
        final transport = _ScriptedAgentSdkTransport(<_Attempt>[
          _Attempt(
            messages: <Map<String, dynamic>>[
              _successResult('claude-new', text: 'Paris.'),
            ],
          ),
        ]);
        final provider = _provider(transport, BrainSessionStrategy(store));

        final events = await provider
            .run(
              LlmRequest(
                prompt: _wire,
                options: const LlmOptions(sessionId: 'tb-1'),
              ),
            )
            .toList();

        expect(events.last, isA<LlmRunCompleted>());
        // The first (only) query resumed the stored id.
        expect(transport.resumesSeen, <Object?>['claude-old']);
        // The returned Claude session id is written back for the next call.
        expect(await store.lookup('tb-1'), 'claude-new');
        // A first-shot success reports no retries — the other half of the count
        // the retry test pins at 1.
        expect((events.last as LlmRunCompleted).report.retries, 0);
      },
    );

    test(
      'a session-error on the resumed call evicts + retries once fresh',
      () async {
        final store = AgentSdkSessionStore(
          File('${tmp.path}/agent_sdk_sessions.json'),
        );
        await store.put('tb-1', 'claude-stale');
        // Both attempts take real time, so the report's elapsed figure can be
        // told apart from the second attempt's own `duration_ms` of 12.
        final transport = _ScriptedAgentSdkTransport(<_Attempt>[
          // Attempt 1 (resume = claude-stale): a session-shaped failure.
          _Attempt(
            error: 'Session claude-stale not found',
            delay: const Duration(milliseconds: 25),
          ),
          // Attempt 2 (fresh): succeeds and yields a new session id.
          _Attempt(
            messages: <Map<String, dynamic>>[
              _successResult('claude-fresh', text: 'Paris.'),
            ],
            delay: const Duration(milliseconds: 25),
          ),
        ]);
        final provider = _provider(transport, BrainSessionStrategy(store));

        final events = await provider
            .run(
              LlmRequest(
                prompt: _wire,
                options: const LlmOptions(sessionId: 'tb-1'),
              ),
            )
            .toList();

        // Exactly one Started (no duplicate on retry), terminal Completed.
        expect(events.whereType<LlmRunStarted>(), hasLength(1));
        expect(events.last, isA<LlmRunCompleted>());
        // First query resumed the stale id, the retry went fresh (resume null).
        expect(transport.resumesSeen, <Object?>['claude-stale', null]);
        // The fresh session id was written back over the evicted stale one.
        expect(await store.lookup('tb-1'), 'claude-fresh');

        // The report tells the truth about the retry. `retries` counts it, and
        // `wallClockMs` is the caller's total — it spans the failed first attempt
        // and the wait as well as the successful second one, so it is well above
        // the 50 ms the two scripted delays alone cost and nowhere near the
        // second attempt's own `duration_ms` of 12.
        final report = (events.last as LlmRunCompleted).report;
        expect(report.retries, 1);
        expect(report.wallClockMs, greaterThanOrEqualTo(40));
      },
    );

    test('a non-session error does NOT retry', () async {
      final store = AgentSdkSessionStore(
        File('${tmp.path}/agent_sdk_sessions.json'),
      );
      await store.put('tb-1', 'claude-old');
      final transport = _ScriptedAgentSdkTransport(<_Attempt>[
        _Attempt(error: 'bridge exploded'),
      ]);
      final provider = _provider(transport, BrainSessionStrategy(store));

      final events = await provider
          .run(
            LlmRequest(
              prompt: _wire,
              options: const LlmOptions(sessionId: 'tb-1'),
            ),
          )
          .toList();

      expect(events.last, isA<LlmRunFailed>());
      expect(transport.resumesSeen, <Object?>['claude-old']);
      // No eviction on a non-session failure: the stored id is left intact.
      expect(await store.lookup('tb-1'), 'claude-old');
    });

    // The provider awaits `record` on the success path, immediately before the
    // terminal event, so a throwing store would discard a call that has already
    // been made and billed: no Completed, no report, no usage or cost. That is
    // strictly worse than the crash the store's contract rules out, because it
    // lands after the money is spent.
    test('an unwritable store still completes a successful call', () async {
      final store = AgentSdkSessionStore(_unwritableFile(tmp));
      final transport = _ScriptedAgentSdkTransport(<_Attempt>[
        _Attempt(
          messages: <Map<String, dynamic>>[
            _successResult('claude-new', text: 'Paris.'),
          ],
        ),
      ]);
      final provider = _provider(transport, BrainSessionStrategy(store));

      final events = await provider
          .run(
            LlmRequest(
              prompt: _wire,
              options: const LlmOptions(sessionId: 'tb-1'),
            ),
          )
          .toList();

      final completed = events.last;
      expect(completed, isA<LlmRunCompleted>());
      // The report survives intact — the usage and cost of a call that really
      // happened are what a failed write must not be allowed to throw away.
      final report = (completed as LlmRunCompleted).report;
      expect(report.tokensIn, 5);
      expect(report.tokensOut, 9);
      expect(report.modelId, 'claude-sonnet-4-6');
      expect(report.anchorHash, 'anchor-hash-A1');
      // And nothing was misreported as a failure along the way.
      expect(events.whereType<LlmRunFailed>(), isEmpty);
    });

    // `evict` reaches the same unguarded write, from `_shouldRetryFresh` —
    // which the provider awaits *outside* the try/catch around the query. An
    // unwritable store there would turn a classified failure into an unhandled
    // stream error, so the guard has to cover the failure path too.
    test('an unwritable store still evicts, retries and completes', () async {
      final store = AgentSdkSessionStore(_unwritableFile(tmp));
      // A process that recorded an id while the store was still healthy: the
      // value is in the cache, so it is resumed, but it can no longer be
      // written back.
      await store.put('tb-1', 'claude-stale');
      final transport = _ScriptedAgentSdkTransport(<_Attempt>[
        _Attempt(error: 'Session claude-stale not found'),
        _Attempt(
          messages: <Map<String, dynamic>>[
            _successResult('claude-fresh', text: 'Paris.'),
          ],
        ),
      ]);
      final provider = _provider(transport, BrainSessionStrategy(store));

      final events = await provider
          .run(
            LlmRequest(
              prompt: _wire,
              options: const LlmOptions(sessionId: 'tb-1'),
            ),
          )
          .toList();

      expect(events.last, isA<LlmRunCompleted>());
      expect(transport.resumesSeen, <Object?>['claude-stale', null]);
    });
  });

  group('provider — quest mode', () {
    test('resumes the quest session id read-only (file unchanged)', () async {
      final root = Directory('${tmp.path}/quests')..createSync();
      final histDir = Directory('${root.path}/tom_brain/history')
        ..createSync(recursive: true);
      final file = File('${histDir.path}/default.session.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'sessionId': 'claude-quest-1',
            'updatedAt': '2026-06-13T00:00:00Z',
            'model': 'claude-sonnet-4-6',
          }),
        );
      final before = file.readAsStringSync();

      final transport = _ScriptedAgentSdkTransport(<_Attempt>[
        _Attempt(
          messages: <Map<String, dynamic>>[
            _successResult('claude-quest-1', text: 'Paris.'),
          ],
        ),
      ]);
      final provider = _provider(
        transport,
        QuestSessionStrategy(
          questHistoryRoot: root.path,
          questId: 'tom_brain',
          sessionKey: 'default',
        ),
      );

      final events = await provider
          .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
          .toList();

      expect(events.last, isA<LlmRunCompleted>());
      expect(transport.resumesSeen, <Object?>['claude-quest-1']);
      // Quest history is read-only: a successful call never rewrites the file.
      expect(file.readAsStringSync(), before);
    });

    test('a stale quest session is paid for once, not on every call', () async {
      final root = Directory('${tmp.path}/quests')..createSync();
      final histDir = Directory('${root.path}/tom_brain/history')
        ..createSync(recursive: true);
      final file = File('${histDir.path}/default.session.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{'sessionId': 'claude-stale'}),
        );
      final before = file.readAsStringSync();

      final transport = _ScriptedAgentSdkTransport(<_Attempt>[
        _Attempt(error: 'Session claude-stale not found'),
        _Attempt(
          messages: <Map<String, dynamic>>[
            _successResult('claude-fresh-1', text: 'one'),
          ],
        ),
        _Attempt(
          messages: <Map<String, dynamic>>[
            _successResult('claude-fresh-2', text: 'two'),
          ],
        ),
      ]);
      final provider = _provider(
        transport,
        QuestSessionStrategy(
          questHistoryRoot: root.path,
          questId: 'tom_brain',
          sessionKey: 'default',
        ),
      );

      final first = await provider
          .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
          .toList();
      final second = await provider
          .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
          .toList();

      expect(first.last, isA<LlmRunCompleted>());
      expect(second.last, isA<LlmRunCompleted>());
      // One failed resume, its fresh retry, then the second call starts fresh
      // without trying the rejected id again.
      expect(transport.resumesSeen, <Object?>['claude-stale', null, null]);
      expect(file.readAsStringSync(), before);
    });
  });
}

/// Continuing the far end's conversation across requests, and the rest of
/// what a backend that is itself an agent asks of the provider: the prompt
/// sent as the request's combined body, the report attributed to it, Claude
/// Code's own loop, a busy session queued, a transport reached on demand.
///
/// Covers the JSON store, the two resume strategies, the resume-error
/// predicate, and the provider's resume / evict-and-retry-once / record
/// behaviour over a scripted transport in in-process sessions.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show promptSha256;
import 'package:tom_llm/tom_llm.dart';

import 'support/sessions.dart';

/// One scripted completion: text, the conversation the far end names, then a
/// clean end or an error.
class _Attempt {
  _Attempt({this.text = 'ok', this.conversation, this.error, this.delay});

  final String text;
  final String? conversation;
  final String? error;
  final Duration? delay;
}

/// A transport with no wire: each [complete] replays the next [_Attempt] and
/// records the request it was given.
class _ScriptedTransport implements AgentSdkServerTransport {
  _ScriptedTransport(this.attempts);

  final List<_Attempt> attempts;
  final List<AgentSdkCompletionRequest> seen = [];

  /// Releases the attempt in flight when set; for the busy-session test.
  Completer<void>? gate;

  @override
  AgentSdkServerTransport Function()? get sessionCopy => null;

  @override
  String get id => 'scripted';

  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    maxContextTokens: 1000,
  );

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  String? get unavailableReason => null;

  @override
  String? get selectionNotice => null;

  bool reachable = true;

  @override
  Future<bool> probe() async => reachable;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Stream<AgentSdkCompletionEvent> complete(
    AgentSdkCompletionRequest request,
  ) async* {
    final attempt = attempts[seen.length.clamp(0, attempts.length - 1)];
    seen.add(request);
    if (attempt.delay != null) await Future<void>.delayed(attempt.delay!);
    final gate = this.gate;
    if (gate != null) await gate.future;
    if (attempt.conversation != null) {
      yield AgentSdkConversation(attempt.conversation!);
    }
    if (attempt.error != null) {
      throw LlmTransportException(
        LlmErrorKind.remote,
        attempt.error!,
        transportId: id,
      );
    }
    yield const AgentSdkTrailed(
      LlmToolCall(callId: 't1', name: 'Read', arguments: {}),
    );
    yield AgentSdkTrailed(LlmTextDelta(attempt.text));
    yield const AgentSdkTrailed(
      LlmUsage(inputTokens: 5, outputTokens: 9, costUsd: 0.01),
    );
  }

  @override
  Future<void> close() async => _connected = false;
}

const _wire = WirePrompt(
  system: 'ANCHOR',
  user: 'What is the capital of France?',
  anchorHash: 'anchor-hash-A1',
  roleId: 'assistant_to_user',
  templateSha: 'template-sha-T1',
);

/// A store path whose parent directory can never be created, because an
/// ancestor component is an ordinary file — the shape a read-only volume or a
/// revoked permission produces, reproducible on every platform.
File _unwritableFile(Directory tmp) {
  File('${tmp.path}/blocker').writeAsStringSync('I am a file, not a folder.');
  return File('${tmp.path}/blocker/sessions/agent_sdk_sessions.json');
}

Future<AgentSdkSessionProvider> _provider(
  _ScriptedTransport transport, {
  AgentSdkResumeStrategy? resume,
  AgentSdkAgentLoop? agentLoop,
  AgentSdkWhenBusy whenBusy = AgentSdkWhenBusy.refuse,
  bool connectOnDemand = false,
  String? model,
  bool initialize = true,
  AgentSdkRunAttribution attribution = AgentSdkRunAttribution.transport,
}) async {
  final selector = AgentSdkTransportSelector([transport]);
  if (initialize) await selector.initialize();
  return AgentSdkSessionProvider(
    id: 'claude:sonnet:test',
    selector: selector,
    sessions: testSessions(inProcess: true),
    toolServerName: 'test',
    model: model,
    resume: resume,
    agentLoop: agentLoop,
    whenBusy: whenBusy,
    connectOnDemand: connectOnDemand,
    attribution: attribution,
  );
}

LlmRequest _request({String? sessionId, String? model}) => LlmRequest(
  prompt: _wire,
  options: LlmOptions(sessionId: sessionId, model: model),
);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('agent_sdk_resume_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('AgentSdkResumeStore', () {
    test('RESUME-1: put, lookup and remove persist across instances', () async {
      final file = File('${tmp.path}/agent_sdk_sessions.json');
      final store = AgentSdkResumeStore(file);
      await store.put('tb-1', 'c-1');
      expect(await AgentSdkResumeStore(file).lookup('tb-1'), 'c-1');
      await store.remove('tb-1');
      expect(await AgentSdkResumeStore(file).lookup('tb-1'), isNull);
    });

    test('RESUME-2: a missing or corrupt file reads as empty', () async {
      final missing = AgentSdkResumeStore(File('${tmp.path}/none.json'));
      expect(await missing.lookup('x'), isNull);
      final corrupt = File('${tmp.path}/bad.json')..writeAsStringSync('{nope');
      expect(await AgentSdkResumeStore(corrupt).lookup('x'), isNull);
    });

    test(
      'RESUME-3: an unwritable store degrades instead of throwing',
      () async {
        final store = AgentSdkResumeStore(_unwritableFile(tmp));
        await store.put('tb-1', 'c-1');
        // Kept in memory for this process, which is all the contract asks.
        expect(await store.lookup('tb-1'), 'c-1');
        await store.remove('tb-1');
      },
    );
  });

  group('agentSdkLooksLikeResumeError', () {
    test(
      'RESUME-4: fires on session plus a failure cue, not on either alone',
      () {
        expect(agentSdkLooksLikeResumeError('Session abc not found'), isTrue);
        expect(agentSdkLooksLikeResumeError('session id is invalid'), isTrue);
        // What Claude Code says, measured live (qim_none-7).
        expect(
          agentSdkLooksLikeResumeError(
            'No conversation found with session ID: 00000000-dead',
          ),
          isTrue,
        );
        expect(agentSdkLooksLikeResumeError('session started'), isFalse);
        expect(agentSdkLooksLikeResumeError('file not found'), isFalse);
      },
    );
  });

  group('stored resume', () {
    test(
      'RESUME-5: resumes the stored conversation, then records the new one',
      () async {
        final store = AgentSdkResumeStore(File('${tmp.path}/s.json'));
        await store.put('tb-1', 'c-old');
        final transport = _ScriptedTransport([
          _Attempt(text: 'Paris.', conversation: 'c-new'),
        ]);
        final provider = await _provider(
          transport,
          resume: AgentSdkStoredResume(store),
        );

        final events = await provider.run(_request(sessionId: 'tb-1')).toList();

        expect(events.last, isA<LlmRunCompleted>());
        expect(transport.seen.single.resume, 'c-old');
        expect(await store.lookup('tb-1'), 'c-new');
        expect((events.last as LlmRunCompleted).report.retries, 0);
      },
    );

    test(
      'RESUME-6: a request with no session neither resumes nor records',
      () async {
        final store = AgentSdkResumeStore(File('${tmp.path}/s.json'));
        final transport = _ScriptedTransport([_Attempt(conversation: 'c-1')]);
        final provider = await _provider(
          transport,
          resume: AgentSdkStoredResume(store),
        );

        await provider.run(_request()).toList();

        expect(transport.seen.single.resume, isNull);
        expect(jsonEncode(await store.lookup('default')), 'null');
      },
    );

    test('RESUME-7: an unknown conversation is evicted and retried once, '
        'fresh, as one run', () async {
      final store = AgentSdkResumeStore(File('${tmp.path}/s.json'));
      await store.put('tb-1', 'c-stale');
      final transport = _ScriptedTransport([
        _Attempt(
          error: 'Session c-stale not found',
          delay: const Duration(milliseconds: 20),
        ),
        _Attempt(text: 'Paris.', conversation: 'c-fresh'),
      ]);
      final provider = await _provider(
        transport,
        resume: AgentSdkStoredResume(store),
      );

      final events = await provider.run(_request(sessionId: 'tb-1')).toList();

      expect(events.whereType<LlmRunStarted>(), hasLength(1));
      expect(events.whereType<LlmRunError>(), isEmpty);
      expect(events.whereType<LlmRetry>(), hasLength(1));
      expect(events.last, isA<LlmRunCompleted>());
      expect(transport.seen.map((r) => r.resume), ['c-stale', null]);
      expect(await store.lookup('tb-1'), 'c-fresh');
      expect((events.last as LlmRunCompleted).report.retries, 1);
      expect(await llmAnswerText(Stream.fromIterable(events)).join(), 'Paris.');
    });

    test(
      'RESUME-8: any other failure is reported and evicts nothing',
      () async {
        final store = AgentSdkResumeStore(File('${tmp.path}/s.json'));
        await store.put('tb-1', 'c-old');
        final transport = _ScriptedTransport([
          _Attempt(error: 'bridge exploded'),
        ]);
        final provider = await _provider(
          transport,
          resume: AgentSdkStoredResume(store),
        );

        final events = await provider.run(_request(sessionId: 'tb-1')).toList();

        expect(events.last, isA<LlmRunFailed>());
        expect(
          events.whereType<LlmRunError>().single.message,
          'bridge exploded',
        );
        expect(transport.seen, hasLength(1));
        expect(await store.lookup('tb-1'), 'c-old');
      },
    );

    test('RESUME-9: an unwritable store still completes the run, its report '
        'intact', () async {
      final store = AgentSdkResumeStore(_unwritableFile(tmp));
      final transport = _ScriptedTransport([
        _Attempt(text: 'Paris.', conversation: 'c-new'),
      ]);
      final provider = await _provider(
        transport,
        resume: AgentSdkStoredResume(store),
      );

      final events = await provider.run(_request(sessionId: 'tb-1')).toList();

      final report = (events.last as LlmRunCompleted).report;
      expect(report.tokensIn, 5);
      expect(report.tokensOut, 9);
      expect(report.anchorHash, 'anchor-hash-A1');
    });
  });

  group('quest resume', () {
    File questFile(String id) {
      final dir = Directory('${tmp.path}/quests/tom_brain/history')
        ..createSync(recursive: true);
      return File('${dir.path}/default.session.json')
        ..writeAsStringSync(jsonEncode({'sessionId': id}));
    }

    AgentSdkQuestResume quest() => AgentSdkQuestResume(
      questHistoryRoot: '${tmp.path}/quests',
      questId: 'tom_brain',
      sessionKey: 'default',
    );

    test(
      'RESUME-10: resumes the quest conversation and never writes the file',
      () async {
        final file = questFile('c-quest');
        final before = file.readAsStringSync();
        final transport = _ScriptedTransport([
          _Attempt(conversation: 'c-other'),
        ]);
        final provider = await _provider(transport, resume: quest());

        await provider.run(_request()).toList();

        expect(transport.seen.single.resume, 'c-quest');
        expect(file.readAsStringSync(), before);
      },
    );

    test('RESUME-11: a stale quest conversation costs one retry, not one per '
        'request', () async {
      questFile('c-stale');
      final transport = _ScriptedTransport([
        _Attempt(error: 'Session c-stale not found'),
        _Attempt(text: 'one'),
        _Attempt(text: 'two'),
      ]);
      final provider = await _provider(transport, resume: quest());

      await provider.run(_request()).toList();
      await provider.run(_request()).toList();

      expect(transport.seen.map((r) => r.resume), ['c-stale', null, null]);
    });
  });

  group('the request on the wire and its report', () {
    test('RESUME-12: the far end gets the combined body; the report carries '
        "the prompt's attribution", () async {
      final transport = _ScriptedTransport([_Attempt()]);
      final provider = await _provider(transport);

      final events = await provider.run(_request()).toList();

      expect(transport.seen.single.prompt, _wire.combined);
      // Without Claude Code's loop the run's tool calls are the caller's.
      expect(events.whereType<LlmToolCall>(), hasLength(1));
      final report = (events.last as LlmRunCompleted).report;
      expect(report.anchorHash, 'anchor-hash-A1');
      expect(report.templateSha, 'template-sha-T1');
      expect(report.promptHash, promptSha256(_wire.combined));
      expect(report.cost, 0.01);
    });

    test(
      "RESUME-13: the request's model wins over the provider's default",
      () async {
        final transport = _ScriptedTransport([_Attempt()]);
        final provider = await _provider(transport, model: 'default-model');

        await provider.run(_request(model: 'route-model')).toList();
        await provider.run(_request()).toList();

        expect(transport.seen.map((r) => r.model), [
          'route-model',
          'default-model',
        ]);
      },
    );

    test("RESUME-14: Claude Code's own loop reaches the transport, and its "
        'tool calls stay in the trail', () async {
      final transport = _ScriptedTransport([_Attempt()]);
      final provider = await _provider(
        transport,
        agentLoop: const AgentSdkAgentLoop(
          maxTurns: 7,
          permissionMode: 'acceptEdits',
        ),
      );

      final events = await provider.run(_request()).toList();

      // Claude Code's tool call is in the trail and not in the caller's run.
      expect(events.whereType<LlmToolCall>(), isEmpty);
      expect(
        provider.trails
            .recordsOf(llmDefaultSession)
            .map((r) => r.event)
            .whereType<LlmToolCall>(),
        hasLength(1),
      );
      final loop = transport.seen.single.agentLoop!;
      expect(loop.maxTurns, 7);
      expect(loop.permissionMode, 'acceptEdits');
      expect(AgentSdkAgentLoop.fromMap(loop.toMap()).maxTurns, 7);
    });
  });

  group('attribution', () {
    test('RESUME-18: a run names the transport, or this provider when it is '
        'attributed to it', () async {
      final byTransport = await _provider(_ScriptedTransport([_Attempt()]));
      final byProvider = await _provider(
        _ScriptedTransport([_Attempt()]),
        attribution: AgentSdkRunAttribution.provider,
      );

      final a = await byTransport.run(_request()).toList();
      final b = await byProvider.run(_request()).toList();

      expect(a.whereType<LlmRunStarted>().single.providerId, 'scripted');
      expect((a.last as LlmRunCompleted).report.providerId, 'scripted');
      expect(
        b.whereType<LlmRunStarted>().single.providerId,
        'claude:sonnet:test',
      );
      expect(
        (b.last as LlmRunCompleted).report.providerId,
        'claude:sonnet:test',
      );
    });
  });

  group('busy sessions and the transport on demand', () {
    test(
      'RESUME-15: a queued run waits for the session and then runs',
      () async {
        final transport = _ScriptedTransport([_Attempt(text: 'a')])
          ..gate = Completer<void>();
        final provider = await _provider(
          transport,
          whenBusy: AgentSdkWhenBusy.queue,
        );

        final first = provider.run(_request(sessionId: 's')).toList();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final second = provider.run(_request(sessionId: 's')).toList();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(transport.seen, hasLength(1));
        transport.gate!.complete();
        transport.gate = null;

        expect((await first).last, isA<LlmRunCompleted>());
        expect((await second).last, isA<LlmRunCompleted>());
        expect(transport.seen, hasLength(2));
      },
    );

    test('RESUME-19: an idle session is stopped, and starts again on its next '
        'run', () async {
      final transport = _ScriptedTransport([_Attempt()]);
      final selector = AgentSdkTransportSelector([transport]);
      await selector.initialize();
      final sessions = AgentSdkSessionManager(
        hosting: AgentSdkSessionHosting.inProcess,
        idleClose: const Duration(milliseconds: 50),
      );
      addTearDown(sessions.dispose);
      final provider = AgentSdkSessionProvider(
        selector: selector,
        sessions: sessions,
        toolServerName: 'test',
      );
      List<LlmSessionClosed> closed() => sessions.trails
          .recordsOf(llmDefaultSession)
          .map((r) => r.event)
          .whereType<LlmSessionClosed>()
          .toList();

      await provider.run(_request()).toList();
      expect(closed(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(closed().single.message, 'idle');

      final again = await provider.run(_request()).toList();
      expect(again.last, isA<LlmRunCompleted>());
      expect(transport.seen, hasLength(2));
    });

    test(
      'RESUME-16: a refusing provider still refuses a busy session',
      () async {
        final transport = _ScriptedTransport([_Attempt()])
          ..gate = Completer<void>();
        final provider = await _provider(transport);

        final first = provider.run(_request(sessionId: 's')).toList();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          () => provider.run(_request(sessionId: 's')),
          throwsA(isA<LlmSessionBusyException>()),
        );
        transport.gate!.complete();
        await first;
      },
    );

    test('RESUME-17: on demand, a run reaches for the transport, and fails as '
        'a run when nothing answers', () async {
      final transport = _ScriptedTransport([_Attempt(text: 'hi')]);
      final provider = await _provider(
        transport,
        connectOnDemand: true,
        initialize: false,
      );

      final reached = await provider.run(_request()).toList();
      expect(reached.last, isA<LlmRunCompleted>());

      await provider.selector.replaceCandidates([
        _ScriptedTransport([_Attempt()])..reachable = false,
      ]);
      final unreached = await provider.run(_request()).toList();
      expect(
        unreached.whereType<LlmRunError>().single.errorKind,
        LlmErrorKind.unreachable,
      );
      expect(unreached.last, isA<LlmRunFailed>());
    });
  });
}

/// And: every AI run is served from a session
/// in an isolate of its own, consolidated by the main isolate.
///
/// The sessions here run in real isolates over real wires: the hosted
/// transport to fake CLI servers this isolate runs. Each case proves one
/// clause — two sessions at once, a busy session refusing, a cancel, a session
/// that does not stop being stopped, a session dying without taking another
/// with it, the availability gate closing on an unreachable far end, and tool calls
/// from two sessions running against two documents in the main isolate.
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_basics/diagnostics.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/requests.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/tool_binding.dart';
import 'support/sessions.dart';

/// A hosted transport aimed at [server], connected once so it knows the port
/// a session copy connects to — as the selector leaves every transport.
Future<AgentSdkServerTransport> _hostedOn(FakeAiServer server) async {
  final transport = HostedCliServerAiTransport(
    minPort: server.port,
    maxPort: server.port,
  );
  await transport.connect();
  await transport.close();
  return transport;
}

const _request = AgentSdkCompletionRequest(prompt: 'Say something.');

List<LlmEvent> _prelude(String transportId, [String purpose = 'generate']) => [
  LlmRunStarted(purpose: purpose, providerId: transportId),
];

Stream<LlmEvent> _run(
  AgentSdkSessionManager sessions,
  String sessionId,
  AgentSdkServerTransport transport, {
  AgentSdkCompletionRequest request = _request,
  Duration stallGap = const Duration(seconds: 20),
}) => sessions.run(
  sessionId: sessionId,
  transport: transport,
  request: request,
  prelude: _prelude(transport.id),
  stallGap: stallGap,
);

String _text(List<LlmEvent> events) =>
    [for (final e in events.whereType<LlmTextDelta>()) e.text].join();

/// A transport whose completion blocks its isolate — a session that cannot
/// hear a cancel, so only stopping it ends the run.
class _BlockingTransport implements AgentSdkServerTransport {
  @override
  String get id => 'blocking';
  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    maxContextTokens: 1000,
  );
  @override
  bool get isConnected => true;
  @override
  Future<bool> probe() async => true;
  @override
  String? get unavailableReason => null;
  @override
  String? get selectionNotice => null;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  AgentSdkServerTransport Function()? get sessionCopy => _blockingCopy;
  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest r) {
    final controller = StreamController<AgentSdkCompletionEvent>();
    controller.onListen = () {
      controller.add(const AgentSdkTrailed(LlmTextDelta('Starting.')));
      // Then holds the isolate, as a stuck run would.
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        final until = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(until)) {}
      });
    };
    return controller.stream;
  }
}

AgentSdkServerTransport _blockingCopy() => _BlockingTransport();

void main() {
  test('two sessions run at once, each in its own isolate, '
      'and the trails hold both', () async {
    final server = await FakeAiServer.start(
      behaviour: FakeAiServerBehaviour.slowDrip,
      replies: const ['one ', 'two ', 'three'],
      dripInterval: const Duration(milliseconds: 150),
    );
    addTearDown(server.stop);
    final transport = await _hostedOn(server);
    final sessions = testSessions();

    final clock = Stopwatch()..start();
    final results = await Future.wait([
      _run(sessions, llmDefaultSession, transport).toList(),
      _run(sessions, llmChatSession, transport).toList(),
    ]);
    // Three drips of 150 ms each, twice: in sequence that is ~900 ms.
    expect(
      clock.elapsed,
      lessThan(const Duration(milliseconds: 850)),
      reason: 'the two runs overlapped',
    );
    for (final events in results) {
      expect(_text(events), 'one two three');
      expect((events.last as LlmRunEnded).outcome, LlmRunOutcome.completed);
    }
    final trails = sessions.trails;
    expect(trails.sessions, unorderedEquals(['default', 'chat']));
    for (final id in trails.sessions) {
      final kinds = [for (final r in trails.recordsOf(id)) r.event.kind];
      expect(kinds.first, 'sessionOpened');
      expect(kinds.last, 'runEnded');
      final seqs = [for (final r in trails.recordsOf(id)) r.seq];
      expect(seqs, List.generate(seqs.length, (i) => i + 1));
    }
    expect(trails.isRunning('default'), isFalse);
  });

  test('a second run in a busy session is refused, never '
      'queued; the session takes runs again once free', () async {
    final server = await FakeAiServer.start(
      behaviour: FakeAiServerBehaviour.slowDrip,
      replies: const ['a', 'b'],
      dripInterval: const Duration(milliseconds: 200),
    );
    addTearDown(server.stop);
    final transport = await _hostedOn(server);
    final sessions = testSessions();

    final first = _run(sessions, 'default', transport).toList();
    expect(sessions.isBusy('default'), isTrue);
    expect(
      () => _run(sessions, 'default', transport),
      throwsA(
        isA<LlmSessionBusyException>().having(
          (e) => e.message,
          'message',
          'The default AI session is busy.',
        ),
      ),
    );
    expect(_text(await first), 'ab');
    expect(sessions.isBusy('default'), isFalse);
    expect(_text(await _run(sessions, 'default', transport).toList()), 'ab');
  });

  test('cancelling one session stops its remote run and '
      'leaves the other running', () async {
    final server = await FakeAiServer.start(
      behaviour: FakeAiServerBehaviour.slowDrip,
      replies: const ['1', '2', '3', '4'],
      dripInterval: const Duration(milliseconds: 200),
    );
    addTearDown(server.stop);
    final transport = await _hostedOn(server);
    final sessions = testSessions();

    final other = _run(sessions, 'chat', transport).toList();
    final firstText = Completer<void>();
    final sub = _run(sessions, 'default', transport).listen((event) {
      if (event is LlmTextDelta && !firstText.isCompleted) {
        firstText.complete();
      }
    });
    await firstText.future;
    unawaited(sub.cancel());

    expect(_text(await other), '1234', reason: 'the other session ran on');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      server.cancelled,
      isNotEmpty,
      reason: 'the cancel reached the far end from the session isolate',
    );
    final kinds = [
      for (final r in sessions.trails.recordsOf('default')) r.event,
    ];
    final ended = kinds.whereType<LlmRunEnded>().single;
    expect(ended.outcome, LlmRunOutcome.cancelled);
    expect(sessions.isBusy('default'), isFalse);
    expect(_text(await _run(sessions, 'default', transport).toList()), '1234');
  });

  test('a session that does not stop when cancelled is '
      'stopped after the grace, and the next run starts a new one', () async {
    final sessions = AgentSdkSessionManager(
      cancelGrace: const Duration(milliseconds: 400),
    );
    addTearDown(sessions.dispose);
    final transport = _BlockingTransport();
    final started = Completer<void>();
    final sub = _run(sessions, 'default', transport).listen((event) {
      if (event is LlmTextDelta && !started.isCompleted) {
        started.complete();
      }
    });
    await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    unawaited(sub.cancel());
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final events = [
      for (final r in sessions.trails.recordsOf('default')) r.event,
    ];
    expect(
      events.whereType<LlmRunEnded>().single.outcome,
      LlmRunOutcome.cancelled,
    );
    final closed = events.whereType<LlmSessionClosed>().single;
    expect(closed.reason, LlmSessionCloseReason.failed);
    expect(closed.message, 'stopped');
    expect(sessions.isBusy('default'), isFalse);
  });

  test('a session that dies ends its run as failed, says so '
      'in its trail, and touches no other session', () async {
    final server = await FakeAiServer.start(
      behaviour: FakeAiServerBehaviour.slowDrip,
      replies: const ['x', 'y', 'z'],
      dripInterval: const Duration(milliseconds: 200),
    );
    addTearDown(server.stop);
    final transport = await _hostedOn(server);
    final sessions = testSessions();

    final other = _run(sessions, 'chat', transport).toList();
    final events = <LlmEvent>[];
    final done = Completer<void>();
    _run(sessions, 'default', transport).listen((event) {
      events.add(event);
      if (event is LlmTextDelta &&
          events.whereType<LlmTextDelta>().length == 1) {
        sessions.debugKill('default');
      }
    }, onDone: done.complete);
    await done.future;

    expect(events.whereType<LlmRunError>(), isNotEmpty);
    expect((events.last as LlmRunEnded).outcome, LlmRunOutcome.failed);
    expect(
      [
        for (final r in sessions.trails.recordsOf('default')) r.event,
      ].whereType<LlmSessionClosed>().single.reason,
      LlmSessionCloseReason.failed,
    );
    expect(_text(await other), 'xyz', reason: 'the other session ran on');
    expect(
      _text(await _run(sessions, 'default', transport).toList()),
      'xyz',
      reason: 'the next run starts a new session',
    );
  });

  test('an unreachable far end, found in the session, closes '
      'the availability gate in the main isolate', () async {
    final server = await FakeAiServer.start();
    final selector = AgentSdkTransportSelector([
      HostedCliServerAiTransport(minPort: server.port, maxPort: server.port),
    ]);
    await selector.initialize();
    addTearDown(selector.dispose);
    final provider = AgentSdkSessionProvider(
      selector: selector,
      sessions: testSessions(),
      toolServerName: 'tools',
    );
    expect(provider.isAvailable, isTrue);
    await server.stop();

    final events = await provider
        .run(testRequest(purpose: 'generate', instruction: 'x'))
        .toList();
    expect(
      events.whereType<LlmRunError>().single.errorKind,
      LlmErrorKind.unreachable,
    );
    expect(provider.isAvailable, isFalse);
  });

  test('tool calls from two sessions run against two '
      'bindings in the main isolate, each in its own run', () async {
    const textA = '00000000-0000-4000-8000-0000000a1701';
    const textB = '00000000-0000-4000-8000-0000000a1711';
    final bindingA = HeadlineToolBinding();
    final bindingB = HeadlineToolBinding();

    Future<FakeAiServer> serverFor(String text, String headline) async {
      final server = await FakeAiServer.start(
        behaviour: FakeAiServerBehaviour.callTools,
        replies: const ['Renaming.', 'Done.'],
      );
      server.toolCalls = [
        (
          testToolServer,
          'set_headline',
          {'sectionId': text, 'headline': headline},
        ),
      ];
      addTearDown(server.stop);
      return server;
    }

    final serverA = await serverFor(textA, 'From default');
    final serverB = await serverFor(textB, 'From chat');
    final sessions = testSessions();

    AgentSdkCompletionRequest agent(HeadlineToolBinding binding) =>
        AgentSdkCompletionRequest(
          prompt: 'Rename it.',
          tools: AgentSdkToolSet.fromBinding(
            binding,
            serverName: testToolServer,
          ),
        );

    final runs = await Future.wait([
      _run(
        sessions,
        'default',
        await _hostedOn(serverA),
        request: agent(bindingA),
      ).toList(),
      _run(
        sessions,
        'chat',
        await _hostedOn(serverB),
        request: agent(bindingB),
      ).toList(),
    ]);
    expect(bindingA.headlines, {textA: 'From default'});
    expect(bindingB.headlines, {textB: 'From chat'});
    expect(bindingA.calls, ['set_headline']);
    expect(bindingB.calls, ['set_headline']);
    for (final events in runs) {
      expect(events.whereType<LlmToolCall>().single.name, 'set_headline');
      expect((events.last as LlmRunEnded).outcome, LlmRunOutcome.completed);
    }
  });

  test('the provider runs the agent in chat and the actions '
      'in default, logs each run, and its trails are the sessions\'', () async {
    final server = await FakeAiServer.start(replies: const ['ok']);
    addTearDown(server.stop);
    final selector = AgentSdkTransportSelector([
      HostedCliServerAiTransport(minPort: server.port, maxPort: server.port),
    ]);
    await selector.initialize();
    addTearDown(selector.dispose);
    final log = TomInMemoryDiagnostics();
    final sessions = AgentSdkSessionManager(diagnostics: log);
    addTearDown(sessions.dispose);
    final provider = AgentSdkSessionProvider(
      selector: selector,
      sessions: sessions,
      toolServerName: 'tools',
    );

    expect(
      await llmAnswerText(
        provider.run(testRequest(purpose: 'summarize', instruction: 'Sum up.')),
      ).join(),
      'ok',
    );
    expect(provider.trails, same(sessions.trails));
    expect(sessions.trails.sessions, ['default']);
    final operations = [for (final e in log.events) e.operation];
    expect(operations, containsAllInOrder(['ai.run.started', 'ai.run.ended']));
    final started = log.events.firstWhere(
      (e) => e.operation == 'ai.run.started',
    );
    expect(started.fields['session'], 'default');
    expect(started.fields['task'], 'summarize');
    final ended = log.events.firstWhere((e) => e.operation == 'ai.run.ended');
    expect(ended.fields['outcome'], 'completed');
    expect(
      log.events
          .expand((e) => e.fields.values)
          .whereType<String>()
          .any((v) => v.contains('Sum up')),
      isFalse,
      reason: 'the log holds a run\'s lifecycle, never its text',
    );
  });
}

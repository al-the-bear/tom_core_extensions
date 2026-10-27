/// A session manager outlives the caller that first ran in it.
///
/// A widget test runs each body in a zone of its own whose microtasks run only
/// while that test pumps. A manager shared by two such bodies spawned its
/// session isolate — and listened on the isolate's port — inside the first,
/// so every later message from that isolate was handed on through the first
/// body's zone, which nothing ran any more: the second run never heard an
/// answer. These cases stand in a zone that stops running microtasks for that
/// body, with no Flutter in the way.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/sessions.dart';

/// A zone whose microtasks run until [retire] — what a finished test body's
/// zone is.
final class _CallerZone {
  var _alive = true;
  late final Zone zone = Zone.current.fork(
    specification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, task) {
        if (_alive) parent.scheduleMicrotask(zone, task);
      },
    ),
  );

  void retire() => _alive = false;

  Future<String> run(Stream<LlmEvent> Function() start) {
    final text = StringBuffer();
    final done = Completer<String>();
    zone.run(() {
      start().listen((event) {
        if (event is LlmTextDelta) text.write(event.text);
      }, onDone: () => done.complete(text.toString()));
    });
    return done.future;
  }
}

Future<void> _twoCallers(AgentSdkSessionHosting hosting) async {
  final server = await FakeAiServer.start(replies: const ['answer']);
  addTearDown(server.stop);
  final transport = HostedCliServerAiTransport(
    minPort: server.port,
    maxPort: server.port,
  );
  await transport.connect();
  await transport.close();
  final sessions = testSessions(
    inProcess: hosting == AgentSdkSessionHosting.inProcess,
  );

  Stream<LlmEvent> run() => sessions.run(
    sessionId: llmDefaultSession,
    transport: transport,
    request: const AgentSdkCompletionRequest(prompt: 'Say something.'),
    prelude: [LlmRunStarted(purpose: 'generate', providerId: transport.id)],
    stallGap: const Duration(seconds: 20),
  );

  final first = _CallerZone();
  expect(await first.run(run), 'answer');
  first.retire();

  final second = _CallerZone();
  expect(
    await second
        .run(run)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => fail(
            'the second run never ended: the session still delivers through the '
            'first caller\'s zone',
          ),
        ),
    'answer',
  );
}

void main() {
  test('CZ-1: a second caller hears its run after the first caller\'s zone '
      'stopped running (isolate hosting)', () async {
    await _twoCallers(AgentSdkSessionHosting.isolate);
  });

  test('CZ-2: the same holds in-process', () async {
    await _twoCallers(AgentSdkSessionHosting.inProcess);
  });
}

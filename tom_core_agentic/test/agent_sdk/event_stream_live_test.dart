/// A **real** run reaches the app as its whole trail:
/// the far end's start, thinking, text, a tool call, its result, the usage and
/// the end — through each transport.
///
/// The offline suite (`event_stream_test.dart`) replays
/// recorded SDK messages; this run is where they are recorded. With
/// `AGENT_SDK_RECORD=1` each transport's messages are written, sanitized, to
/// `test/agent_sdk/fixtures/sdk_messages/<transport>_agent_run.json` — re-record when
/// the Agent SDK, the model or a transport changes.
///
/// Gated as `live_completion_test.dart` is: `AGENT_SDK_LIVE=1` for
/// the standalone half (Node ≥ 20, `npm ci` in `node/`, and
/// `ANTHROPIC_API_KEY` or the ambient Claude Code login),
/// `AGENT_SDK_LIVE_HOSTED=1` for the hosted half (a VS Code window running
/// the Tom extension's CLI server). Each half probes first: a transport with
/// no model behind it SKIPS naming the credential, an unreachable one FAILS.
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk_live_probe.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/requests.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/sessions.dart';
import 'support/tool_binding.dart';

const _liveVar = 'AGENT_SDK_LIVE';
const _liveHostedVar = 'AGENT_SDK_LIVE_HOSTED';
const _recordVar = 'AGENT_SDK_RECORD';
const _keyVar = 'ANTHROPIC_API_KEY';
const _workspaceVar = 'AGENT_SDK_LIVE_WORKSPACE';

const _idText = '00000000-0000-4000-8000-0000000a1601';

/// An instruction that asks for a little reasoning and exactly one tool call,
/// so a run has something to think about and something to do.
const _instruction =
    'The open document has a section with id $_idText. Think it through '
    'before acting: find the smallest prime number greater than 380 whose '
    'digits sum to 13, and check your answer. Then call '
    'set_headline once with that sectionId and that prime as the '
    'headline. Call no other tool. Then reply with the single word DONE.';

bool _enabled(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty;
}

bool _skipWithoutModel(AgentSdkProbe probe) {
  switch (probe.outcome) {
    case AgentSdkProbeOutcome.answered:
      return false;
    case AgentSdkProbeOutcome.noModel:
      markTestSkipped(probe.detail);
      return true;
    case AgentSdkProbeOutcome.unreachable:
      fail('the live transport could not be reached: ${probe.detail}');
  }
}

/// The `system/init` fields reads, and the ones that identify the
/// message; the rest describe the recording machine's own setup (its
/// plugins, skills, memory paths, slash commands) and stay out of a committed
/// fixture.
const _initKeys = {
  'type',
  'subtype',
  'model',
  'tools',
  'mcp_servers',
  'permissionMode',
  'session_id',
  'uuid',
};

/// [value] with everything that names this machine, this account or this
/// session replaced:
/// a fixture is committed, and the tracked-artifact check refuses a path under
/// a user's home — written plainly or in the SDK's dashed project form.
Object? _sanitize(Object? value, String home) => switch (value) {
  Map() => {
    for (final e in value.entries)
      if (value['subtype'] != 'init' || _initKeys.contains('${e.key}'))
        '${e.key}': switch ('${e.key}') {
          'session_id' => 'session-fixture',
          'uuid' => 'uuid-fixture',
          'cwd' => '/work',
          // The account's usage against its plan: not the run's, and
          // not for a committed file.
          'rate_limit_info' => {'status': 'allowed'},
          _ => _sanitize(e.value, home),
        },
  },
  List() => [for (final v in value) _sanitize(v, home)],
  String() when home.isNotEmpty =>
    value
        .replaceAll(home, '/home/user')
        .replaceAll(home.replaceAll('/', '-'), '-home-user'),
  _ => value,
};

/// Runs one agent request through [transport] and checks that every
/// event kind a tool-calling run produces arrived; records the SDK messages
/// when asked.
Future<void> _expectFullTrail(
  AgentSdkServerTransport transport,
  String name,
) async {
  final selector = AgentSdkTransportSelector([transport]);
  await selector.initialize();
  addTearDown(selector.dispose);
  expect(selector.isAvailable, isTrue);
  final provider = AgentSdkSessionProvider(
    // The SDK-message tap is a static of the channel, so a recording run
    // keeps its session in this isolate where the tap can see it.
    sessions: testSessions(inProcess: _enabled(_recordVar)),
    selector: selector,
    toolServerName: testToolServer,
  );

  final recorded = <Map<String, dynamic>>[];
  CliServerAiChannel.debugMessageTap = (_, raw) => recorded.add(raw);
  addTearDown(() => CliServerAiChannel.debugMessageTap = null);

  final binding = HeadlineToolBinding();

  final events = await provider
      .run(
        testRequest(
          purpose: 'agent',
          instruction: _instruction,
          toolBinding: binding,
        ),
      )
      .toList();

  final kinds = [for (final e in events) e.kind];
  // ignore: avoid_print
  print(
    'event stream $name: ${kinds.toSet()} '
    '(${recorded.length} SDK messages, headline '
    '"${binding.headlines[_idText]}")',
  );

  if (_enabled(_recordVar)) {
    final home = Platform.environment['HOME'] ?? '';
    final file = File(
      'test/agent_sdk/fixtures/sdk_messages/${name}_agent_run.json',
    )..createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(_sanitize(recorded, home))}\n',
    );
  }

  expect(kinds.first, 'runStarted');
  expect(kinds[1], 'userPrompt');
  expect(kinds.last, 'runEnded');
  expect((events.last as LlmRunEnded).outcome, LlmRunOutcome.completed);
  for (final kind in [
    'systemInit',
    'thinkingDelta',
    'textDelta',
    'toolCall',
    'toolResult',
    'usage',
  ]) {
    expect(kinds, contains(kind), reason: 'no $kind in a real tool run');
  }
  final call = events.whereType<LlmToolCall>().first;
  expect(call.name, 'set_headline');
  expect(
    events.whereType<LlmToolResult>().map((r) => r.callId),
    contains(call.callId),
  );
  expect(events.whereType<LlmRunError>(), isEmpty);
  // The smallest prime above 380 whose digits sum to 13.
  expect(binding.headlines[_idText], contains('409'));
}

void main() {
  group('standalone (own Node process)', () {
    if (!_enabled(_liveVar)) {
      test('skipped — set $_liveVar', () {}, skip: 'set $_liveVar=1 to enable');
      return;
    }
    final node = findNodeForTests();
    if (node == null) {
      test('skipped — needs Node >= 20', () {}, skip: 'no Node >= 20 found');
      return;
    }
    final script = resolveDefaultServerScript();
    StandaloneNodeAiTransport build() => StandaloneNodeAiTransport(
      node: llmNodeAt(node),
      serverScript: script,
      apiKey: Platform.environment[_keyVar],
      startupTimeout: const Duration(seconds: 60),
      onStderr: (line) => printOnFailure('[server] $line'),
    );

    late final AgentSdkProbe probe;
    setUpAll(() async => probe = await probeAgentSdkModel(build()));

    test('a real tool run arrives as its whole '
        'trail', () async {
      if (_skipWithoutModel(probe)) return;
      await _expectFullTrail(build(), 'standalone');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('hosted (VS Code CLI server)', () {
    if (!_enabled(_liveHostedVar)) {
      test(
        'skipped — set $_liveHostedVar',
        () {},
        skip: 'set $_liveHostedVar=1 with VS Code running to enable',
      );
      return;
    }
    HostedCliServerAiTransport build() => HostedCliServerAiTransport(
      workspaceName: Platform.environment[_workspaceVar],
    );

    late final AgentSdkProbe probe;
    setUpAll(() async => probe = await probeAgentSdkModel(build()));

    test('a real tool run arrives as its whole trail '
        '', () async {
      if (_skipWithoutModel(probe)) return;
      await _expectFullTrail(build(), 'hosted');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

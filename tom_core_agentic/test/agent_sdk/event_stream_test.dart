/// Every Agent SDK message a run receives reaches
/// the app as its trail event, offline.
///
/// The SDK messages are **recorded**, not invented: a live run through each
/// transport wrote `test/agent_sdk/fixtures/sdk_messages/<transport>_agent_run.json`
/// (`event_stream_live_test.dart`, `AGENT_SDK_RECORD=1`).
/// Each recording is replayed three ways: straight into the translator, over
/// the hosted transport's socket to a fake CLI server, and through the
/// standalone transport's spawned server — the last two through the provider,
/// so the bound and the prelude are part of what is checked.
@Timeout(Duration(seconds: 180))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_basics/diagnostics.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_core_agentic/src/agent_sdk/transport/sdk_trail_translator.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/tool_binding.dart';
import 'support/requests.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/stand_in.dart';

List<Map<String, dynamic>> _recording(String transport) => [
  for (final message
      in jsonDecode(
            File(
              'test/agent_sdk/fixtures/sdk_messages/${transport}_agent_run.json',
            ).readAsStringSync(),
          )
          as List)
    (message as Map).cast<String, dynamic>(),
];

/// The trail events the translator makes of [messages], liveness dropped.
List<LlmEvent> _translated(List<Map<String, dynamic>> messages) {
  final translator = SdkTrailTranslator(toolServerName: testToolServer);
  return [
    for (final raw in messages)
      for (final event in translator.translate(SdkMessage.fromJson(raw)))
        if (event case AgentSdkTrailed(:final event)) event,
  ];
}

/// The text of a recording's assembled assistant messages — what the answer
/// must equal, however it streamed.
String _assembledText(List<Map<String, dynamic>> messages) {
  final pieces = <String>[];
  for (final raw in messages) {
    final message = SdkMessage.fromJson(raw);
    if (message is SdkAssistantMessage && message.error == null) {
      for (final block in message.content) {
        if (block is TextBlock) pieces.add(block.text);
      }
    }
  }
  return pieces.join();
}

Future<AgentSdkSessionProvider> _provider(
  AgentSdkServerTransport transport, {
  Duration stallGap = const Duration(seconds: 30),
  TomDiagnostics diagnostics = const TomNullDiagnostics(),
}) async {
  final selector = AgentSdkTransportSelector([transport]);
  await selector.initialize();
  addTearDown(selector.dispose);
  expect(selector.isAvailable, isTrue);
  final sessions = AgentSdkSessionManager(diagnostics: diagnostics);
  addTearDown(sessions.dispose);
  return AgentSdkSessionProvider(
    selector: selector,
    stallGap: stallGap,
    sessions: sessions,
    toolServerName: 'tools',
  );
}

final _request = testRequest(
  purpose: 'agent',
  instruction: 'Find the prime and write it as the headline.',
);

/// Checks the trail a provider produced from a recording.
void _expectRecordedTrail(
  List<LlmEvent> events,
  List<Map<String, dynamic>> recording,
  String transportId,
) {
  final kinds = [for (final e in events) e.kind];
  expect(kinds.take(2), ['runStarted', 'userPrompt']);
  expect((events.first as LlmRunStarted).providerId, transportId);
  expect(kinds.where((k) => k == 'runEnded'), hasLength(1));
  expect(kinds.last, 'runEnded');
  final end = events.last as LlmRunEnded;
  expect(end.outcome, LlmRunOutcome.completed);
  expect(end.rounds, isNotNull, reason: 'the far end reported its turns');
  expect(end.toolCalls, 1);
  for (final kind in [
    'systemInit',
    'thinkingDelta',
    'textDelta',
    'toolCall',
    'toolResult',
    'usage',
  ]) {
    expect(kinds, contains(kind));
  }
  final answer = [
    for (final e in events.whereType<LlmTextDelta>()) e.text,
  ].join();
  expect(
    answer.replaceAll('\n\n', ''),
    _assembledText(recording),
    reason: 'the deltas are the answer, once — not the assembled copy too',
  );
}

void main() {
  for (final transport in ['standalone', 'hosted']) {
    group('the $transport recording, translated', () {
      final recording = _recording(transport);
      final events = _translated(recording);

      test('($transport): every event kind present, in run '
          'order', () {
        final kinds = [for (final e in events) e.kind];
        expect(kinds.first, 'systemInit');
        expect(kinds.last, 'runEnded');
        expect(
          kinds.indexOf('toolCall'),
          lessThan(kinds.indexOf('toolResult')),
        );
        expect(
          kinds.indexOf('thinkingDelta'),
          lessThan(kinds.indexOf('toolCall')),
        );
        expect(
          kinds.lastIndexOf('textDelta'),
          greaterThan(kinds.indexOf('toolResult')),
        );
        expect(kinds.where((k) => k == 'usage'), hasLength(1));
      });

      test('($transport): thinking and text arrive once, as '
          'they streamed', () {
        final thinking = events.whereType<LlmThinkingDelta>().toList();
        expect(
          thinking.length,
          greaterThan(1),
          reason: 'thinking streams as deltas, not as one assembled block',
        );
        final text = [
          for (final e in events.whereType<LlmTextDelta>()) e.text,
        ].join();
        expect(text.replaceAll('\n\n', ''), _assembledText(recording));
      });

      test('($transport): the tool call names the tool, '
          'carries its arguments, and its result follows', () {
        final call = events.whereType<LlmToolCall>().single;
        expect(call.name, 'set_headline');
        expect(call.arguments['headline'], '409');
        final result = events.whereType<LlmToolResult>().single;
        expect(result.callId, call.callId);
        expect(result.isError, isFalse);
        expect(result.fullLength, result.text.length);
      });

      test('($transport): system/init names the model and the '
          'tools without their server prefix', () {
        final init = events.whereType<LlmSystemInit>().single;
        expect(init.model, isNotEmpty);
        expect(init.tools, contains('set_headline'));
        expect(
          init.tools.where((t) => t.startsWith('mcp__${testToolServer}__')),
          isEmpty,
        );
      });

      test('($transport): usage carries tokens, cost and the '
          'per-model share; the end carries the turns', () {
        final usage = events.whereType<LlmUsage>().single;
        expect(usage.outputTokens, greaterThan(0));
        expect(usage.costUsd, greaterThan(0));
        expect(usage.models, isNotEmpty);
        expect(usage.apiDuration, isNotNull);
        final end = events.whereType<LlmRunEnded>().single;
        expect(end.rounds, greaterThanOrEqualTo(2));
        expect(end.toolCalls, 1);
      });
    });
  }

  group('the translator, case by case', () {
    Map<String, dynamic> partial(Map<String, dynamic> event) => {
      'type': 'stream_event',
      'event': event,
    };
    Map<String, dynamic> assistant(
      String id,
      List<Map<String, dynamic>> content, {
      String? error,
    }) => {
      'type': 'assistant',
      'error': ?error,
      'message': {'id': id, 'content': content},
    };
    List<AgentSdkCompletionEvent> run(List<Map<String, dynamic>> raws) {
      final translator = SdkTrailTranslator();
      return [
        for (final raw in raws)
          ...translator.translate(SdkMessage.fromJson(raw)),
      ];
    }

    String textOf(List<AgentSdkCompletionEvent> events) => [
      for (final e in events)
        if (e case AgentSdkTrailed(event: LlmTextDelta(:final text))) text,
    ].join();

    test('a turn that never streamed is emitted from its '
        'assembled message', () {
      final events = run([
        assistant('m1', [
          {'type': 'thinking', 'thinking': 'Hmm.'},
          {'type': 'text', 'text': 'Hello.'},
        ]),
      ]);
      expect(textOf(events), 'Hello.');
      expect(events.whereType<AgentSdkTrailed>().map((e) => e.event.kind), [
        'thinkingDelta',
        'textDelta',
      ]);
    });

    test('text after a tool call starts a new paragraph '
        '', () {
      final events = run([
        partial({
          'type': 'message_start',
          'message': {'id': 'm1'},
        }),
        partial({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'Reading.'},
        }),
        assistant('m1', [
          {'type': 'text', 'text': 'Reading.'},
          {'type': 'tool_use', 'id': 't1', 'name': 'x', 'input': {}},
        ]),
        partial({
          'type': 'message_start',
          'message': {'id': 'm2'},
        }),
        partial({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'Done'},
        }),
        partial({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': '.'},
        }),
        assistant('m2', [
          {'type': 'text', 'text': 'Done.'},
        ]),
      ]);
      expect(textOf(events), 'Reading.\n\nDone.');
    });

    test('a message the SDK writes to report a failure is not '
        'text', () {
      final events = run([
        assistant('m1', [
          {'type': 'text', 'text': 'Invalid API key · Fix external API key'},
        ], error: 'authentication_failed'),
      ]);
      expect(textOf(events), isEmpty);
      expect(events.single, isA<AgentSdkLiveness>());
    });

    test('a retry carries its attempt, delay and cause; a '
        'failed result its usage and no end', () {
      final events = run([
        {
          'type': 'system',
          'subtype': 'api_retry',
          'attempt': 2,
          'max_retries': 10,
          'retry_delay_ms': 4000,
          'error_status': 529,
          'error': 'server_error',
        },
        {
          'type': 'result',
          'subtype': 'error_during_execution',
          'is_error': true,
          'usage': {'input_tokens': 3, 'output_tokens': 0},
        },
      ]).whereType<AgentSdkTrailed>().map((e) => e.event).toList();
      final retry = events.first as LlmRetry;
      expect(retry.attempt, 2);
      expect(retry.delay, const Duration(seconds: 4));
      expect(retry.cause, 'HTTP 529: server_error');
      expect([for (final e in events) e.kind], ['retry', 'usage']);
    });

    test('a message the translator has no event for is liveness that '
        'names its type', () {
      final events = run([
        {'type': 'rate_limit_event'},
        {'type': 'system', 'subtype': 'thinking_tokens'},
        partial({'type': 'content_block_stop'}),
      ]);
      expect(
        [for (final e in events) (e as AgentSdkLiveness).unmappedType],
        ['rate_limit_event', 'system/thinking_tokens', null],
      );
    });

    test('a tool result given as content parts is joined; '
        'a replayed user message is not a result', () {
      final events = run([
        {
          'type': 'user',
          'message': {
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 't1',
                'is_error': true,
                'content': [
                  {'type': 'text', 'text': 'E_NOT_FOUND'},
                  {'type': 'image'},
                ],
              },
            ],
          },
        },
        {
          'type': 'user',
          'isReplay': true,
          'message': {
            'content': [
              {'type': 'tool_result', 'tool_use_id': 't0', 'content': 'old'},
            ],
          },
        },
      ]);
      final result = (events.first as AgentSdkTrailed).event as LlmToolResult;
      expect(result.callId, 't1');
      expect(result.isError, isTrue);
      expect(result.text, 'E_NOT_FOUND\n[image]');
      expect(events.last, isA<AgentSdkLiveness>());
    });
  });

  group('the bounded run', () {
    Stream<AgentSdkCompletionEvent> events(
      List<AgentSdkCompletionEvent> sent, {
      Object? error,
      bool hang = false,
    }) {
      final controller = StreamController<AgentSdkCompletionEvent>();
      controller.onListen = () {
        sent.forEach(controller.add);
        if (error != null) controller.addError(error);
        if (!hang) unawaited(controller.close());
      };
      return controller.stream;
    }

    const prelude = [LlmRunStarted(purpose: 'generate', providerId: 'fake')];

    test('a stream that ends without the far end\'s end gets '
        'one, counting the tool calls', () async {
      final trail = await boundedAiRun(
        events([
          const AgentSdkTrailed(LlmToolCall(callId: 'a', name: 'x')),
          const AgentSdkTrailed(LlmTextDelta('ok')),
        ]),
        stallGap: const Duration(seconds: 5),
        transportId: 'fake',
        prelude: prelude,
      ).toList();
      expect(
        [for (final e in trail) e.kind],
        ['runStarted', 'toolCall', 'textDelta', 'runEnded'],
      );
      final end = trail.last as LlmRunEnded;
      expect(end.outcome, LlmRunOutcome.completed);
      expect(end.toolCalls, 1);
    });

    test('the far end\'s own end passes through, once', () async {
      final trail = await boundedAiRun(
        events([
          const AgentSdkTrailed(LlmRunCompleted(report: _report, rounds: 3)),
        ]),
        stallGap: const Duration(seconds: 5),
        transportId: 'fake',
      ).toList();
      expect(trail.single, isA<LlmRunEnded>());
      expect((trail.single as LlmRunEnded).rounds, 3);
    });

    test('a failure is in the trail and the stream does not '
        'error; the observer sees it', () async {
      LlmTransportException? seen;
      final trail = await boundedAiRun(
        events(
          const [],
          error: const LlmTransportException(
            LlmErrorKind.unreachable,
            'gone',
            transportId: 'fake',
          ),
        ),
        stallGap: const Duration(seconds: 5),
        transportId: 'fake',
        onFailure: (failure) => seen = failure,
      ).toList();
      expect([for (final e in trail) e.kind], ['error', 'runEnded']);
      expect((trail.first as LlmRunError).errorKind, LlmErrorKind.unreachable);
      expect((trail.last as LlmRunEnded).outcome, LlmRunOutcome.failed);
      expect(seen?.message, 'gone');
    });

    test('silence ends the run as a stall, an error and a '
        'timeout', () async {
      final trail = await boundedAiRun(
        events(const [], hang: true),
        stallGap: const Duration(milliseconds: 100),
        transportId: 'fake',
      ).toList();
      expect([for (final e in trail) e.kind], ['stall', 'error', 'runEnded']);
      expect((trail.last as LlmRunEnded).outcome, LlmRunOutcome.timeout);
    });

    test('an unmapped message type is reported once per run '
        '', () async {
      final reported = <String>[];
      await boundedAiRun(
        events(const [
          AgentSdkLiveness('x', unmappedType: 'system/thinking_tokens'),
          AgentSdkLiveness('x', unmappedType: 'system/thinking_tokens'),
          AgentSdkLiveness('x', unmappedType: 'rate_limit_event'),
          AgentSdkLiveness('stream_event'),
        ]),
        stallGap: const Duration(seconds: 5),
        transportId: 'fake',
        onUnmapped: reported.add,
      ).toList();
      expect(reported, ['system/thinking_tokens', 'rate_limit_event']);
    });
  });

  group('the provider over each wire', () {
    test('the hosted transport delivers the recorded run as '
        'its whole trail; unmapped types reach the log', () async {
      final recording = _recording('hosted');
      final server = await FakeAiServer.start(
        behaviour: FakeAiServerBehaviour.replay,
        recorded: recording,
      );
      addTearDown(server.stop);
      final transport = HostedCliServerAiTransport(
        minPort: server.port,
        maxPort: server.port,
      );
      addTearDown(transport.close);
      final log = TomInMemoryDiagnostics();
      final provider = await _provider(transport, diagnostics: log);
      final events = await provider.run(_request).toList();
      _expectRecordedTrail(events, recording, transport.id);
      final unmapped = [
        for (final e in log.events)
          if (e.operation == 'ai.transport.unmapped') e.fields['type'],
      ];
      expect(unmapped, contains('system/thinking_tokens'));
      expect(
        unmapped.toSet().length,
        unmapped.length,
        reason: 'once per type per run',
      );
      for (final e in log.events) {
        expect(
          e.fields.values.whereType<String>().join(' '),
          isNot(contains('409')),
          reason: 'a log line carries a type, never content',
        );
      }
    });

    test('the standalone transport, through its spawned '
        'server, delivers the recorded run', () async {
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        serverScript: 'test/agent_sdk/support/replay_ai_server.dart',
        startupTimeout: spawnStartupTimeout,
      );
      addTearDown(transport.close);
      final provider = await _provider(transport);
      final events = await provider.run(_request).toList();
      _expectRecordedTrail(events, _recording('standalone'), transport.id);
    });

    test('complete is the run reduced to its text', () async {
      final recording = _recording('hosted');
      final server = await FakeAiServer.start(
        behaviour: FakeAiServerBehaviour.replay,
        recorded: recording,
      );
      addTearDown(server.stop);
      final transport = HostedCliServerAiTransport(
        minPort: server.port,
        maxPort: server.port,
      );
      addTearDown(transport.close);
      final provider = await _provider(transport);
      final answer = await llmAnswerText(provider.run(_request)).join();
      expect(answer.replaceAll('\n\n', ''), _assembledText(recording));
    });
  });
}

const _report = LlmCallReport(
  providerId: 'fake',
  modelId: '',
  anchorHash: '',
  promptHash: '',
  tokensIn: 0,
  tokensOut: 0,
  retries: 0,
  wallClockMs: 0,
);

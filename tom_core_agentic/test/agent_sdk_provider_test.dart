// AgentSdkLlmProvider (session mode `none`). Drives the provider over a fake
// `AgentSdkTransport` that replays a scripted `SDKMessage` sequence, proving the
// SdkMessage → LlmEvent translation, the anchor / provenance stamp, the
// usage/cost read-off, and the failure paths — without a live VS Code bridge.
//
// Migrated from `tom_brain_run/test/r42_agent_sdk_provider_test.dart` when the
// provider layer moved into `tom_core_agentic`.

import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:test/test.dart';

/// A fake transport that replays [messages] (raw `SDKMessage` JSON maps) for the
/// query, then emits either an `error` chunk (when [error] is set) or a `done`
/// chunk. It records the [lastPrompt] / [lastOptions] the client started the
/// query with so a test can assert the wire contract (body unmodified, no
/// session id in mode `none`).
class _FakeAgentSdkTransport extends AgentSdkTransport {
  _FakeAgentSdkTransport({required this.messages, this.error});

  final List<Map<String, dynamic>> messages;
  final String? error;

  String? lastPrompt;
  Map<String, dynamic>? lastOptions;

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get chunks => _controller.stream;

  @override
  Future<void> startQuery(Map<String, dynamic> params) async {
    final streamId = params['streamId'] as String;
    lastPrompt = params['prompt'] as String?;
    lastOptions = (params['options'] as Map?)?.cast<String, dynamic>();
    // Emit after `onListen` has wired its subscription (the client subscribes
    // before calling startQuery; the microtask runs after both complete).
    scheduleMicrotask(() {
      for (final message in messages) {
        if (_controller.isClosed) return;
        _controller.add({'streamId': streamId, 'message': message});
      }
      if (_controller.isClosed) return;
      if (error != null) {
        _controller.add({'streamId': streamId, 'error': error});
      } else {
        _controller.add({'streamId': streamId, 'done': true});
      }
    });
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

AgentSdkLlmProvider _provider(_FakeAgentSdkTransport transport) =>
    AgentSdkLlmProvider(
      id: 'claude:sonnet:none',
      defaultModel: 'claude-sonnet-4-6',
      bridgePort: 19900,
      clientFactory: (port) async => AgentSdkClient(transport),
    );

void main() {
  group('AgentSdkLlmProvider — mode none, happy path', () {
    final transport = _FakeAgentSdkTransport(
      messages: <Map<String, dynamic>>[
        {
          'type': 'system',
          'subtype': 'init',
          'model': 'claude-sonnet-4-6',
          'session_id': 'sess-1',
        },
        {
          'type': 'assistant',
          'session_id': 'sess-1',
          'message': {
            'content': [
              {'type': 'thinking', 'thinking': 'The user wants a capital.'},
              {'type': 'text', 'text': 'The capital of France '},
            ],
          },
        },
        {
          'type': 'assistant',
          'session_id': 'sess-1',
          'message': {
            'content': [
              {'type': 'text', 'text': 'is Paris.'},
            ],
          },
        },
        {
          'type': 'result',
          'subtype': 'success',
          'is_error': false,
          'result': 'The capital of France is Paris.',
          'duration_ms': 1234,
          'total_cost_usd': 0.0021,
          'usage': {'input_tokens': 88, 'output_tokens': 40},
          'session_id': 'sess-1',
        },
      ],
    );
    final provider = _provider(transport);

    test('emits Started → Chunk(s) → Completed in order', () async {
      final events = await provider
          .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
          .toList();

      expect(events.first, isA<LlmRunStarted>());
      expect(events.last, isA<LlmRunCompleted>());
      expect(events.whereType<LlmRunFailed>(), isEmpty);
    });

    test('Started carries provider id + resolved model', () async {
      final events = await provider
          .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
          .toList();
      final started = events.whereType<LlmRunStarted>().single;
      expect(started.providerId, 'claude:sonnet:none');
      expect(started.modelId, 'claude-sonnet-4-6');
      // Pinned as a *relationship*, not as two literals that happen to match
      // the report's: consumers log the route from Started long before the
      // report exists, so a stream that announced one route and completed on
      // another would leave the two disagreeing with nothing to catch it.
      final report = events.whereType<LlmRunCompleted>().single.report;
      expect(started.providerId, report.providerId);
      expect(started.modelId, report.modelId);
    });

    test('text blocks stream as chunks; thinking blocks are dropped', () async {
      final chunks =
          (await provider
                  .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
                  .toList())
              .whereType<LlmTextDelta>()
              .map((c) => c.text)
              .toList();
      expect(chunks, <String>['The capital of France ', 'is Paris.']);
    });

    test(
      'terminal report stamps anchor, provenance, tokens, cost, wall-clock',
      () async {
        final completed =
            (await provider
                    .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
                    .toList())
                .whereType<LlmRunCompleted>()
                .single;
        final report = completed.report;
        expect(report.anchorHash, 'anchor-hash-A1');
        expect(report.providerId, 'claude:sonnet:none');
        expect(report.modelId, 'claude-sonnet-4-6');
        expect(report.promptHash, promptSha256(_wire.combined));
        expect(report.templateSha, 'template-sha-T1');
        expect(report.tokensIn, 88);
        expect(report.tokensOut, 40);
        expect(report.cost, 0.0021);
        // `wallClockMs` is the caller's own elapsed time, deliberately *not* the
        // SDK's `duration_ms` (scripted here as 1234). The two differ whenever
        // there is a retry, where the SDK figure covers only the last attempt;
        // taking the backend number was the defect, so a non-1234 measurement is
        // the assertion that holds it shut.
        expect(report.wallClockMs, isNot(1234));
        expect(report.wallClockMs, greaterThanOrEqualTo(0));
        expect(report.retries, 0);
      },
    );

    test(
      'options.model overrides the route default on report + Started',
      () async {
        final events = await provider
            .run(
              LlmRequest(
                prompt: _wire,
                options: const LlmOptions(model: 'claude-opus-4-8'),
              ),
            )
            .toList();
        final started = events.whereType<LlmRunStarted>().single;
        final completed = events.whereType<LlmRunCompleted>().single;
        expect(started.modelId, 'claude-opus-4-8');
        expect(completed.report.modelId, 'claude-opus-4-8');
        // Provenance travels as a pair: an override moves `modelId` on both
        // events, and `providerId` stays this provider's own id on both.
        expect(started.providerId, completed.report.providerId);
      },
    );

    test(
      'wire prompt is handed to the SDK unmodified, no session id set',
      () async {
        await provider
            .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
            .toList();
        expect(transport.lastPrompt, _wire.combined);
        // Mode none: never a `resume` / `sessionId` on the SDK options.
        expect(transport.lastOptions, isNotNull);
        expect(transport.lastOptions!.containsKey('resume'), isFalse);
        expect(transport.lastOptions!.containsKey('sessionId'), isFalse);
      },
    );
  });

  group('AgentSdkLlmProvider — complete() drains the stream', () {
    test('returns the terminal report', () async {
      final transport = _FakeAgentSdkTransport(
        messages: <Map<String, dynamic>>[
          {
            'type': 'result',
            'subtype': 'success',
            'is_error': false,
            'result': 'ok',
            'duration_ms': 50,
            'usage': {'input_tokens': 3, 'output_tokens': 7},
          },
        ],
      );
      final report = await _provider(
        transport,
      ).complete(LlmRequest(prompt: _wire, options: LlmOptions.empty));
      expect(report.tokensOut, 7);
      expect(report.anchorHash, 'anchor-hash-A1');
    });
  });

  // Every assertion above rides `_wire`, whose `user` channel is empty — and a
  // `WirePrompt` with no user text has `combined == system`, so a provider that
  // put the system channel alone on the wire, or fingerprinted it, would
  // satisfy all of them. A prompt with both channels filled is the only shape
  // in which the contract has a discriminator. It is the same contract on both
  // entry points, which is why the buffered one is driven here rather than
  // trusted to the streamed one it shares code with.
  group('AgentSdkLlmProvider — a prompt with both channels', () {
    const wire = WirePrompt(
      system: 'ANCHOR\n\nYou answer geography questions.',
      user: 'What is the capital of France?',
      anchorHash: 'anchor-hash-A1',
      roleId: 'assistant_to_user',
      templateSha: 'template-sha-T1',
    );

    _FakeAgentSdkTransport newTransport() => _FakeAgentSdkTransport(
      messages: const <Map<String, dynamic>>[
        {
          'type': 'result',
          'subtype': 'success',
          'is_error': false,
          'result': 'Paris.',
          'duration_ms': 50,
          'usage': {'input_tokens': 3, 'output_tokens': 7},
        },
      ],
    );

    test('the two channels really do differ from the join', () {
      // The control. Without it the two tests below could pass by accident on
      // a fixture that drifted back to a single channel.
      expect(wire.combined, isNot(wire.system));
      expect(wire.combined, isNot(wire.user));
      expect(wire.combined, '${wire.system}\n\n${wire.user}');
    });

    test('run sends combined and hashes combined', () async {
      final transport = newTransport();
      final events = await _provider(
        transport,
      ).run(LlmRequest(prompt: wire, options: LlmOptions.empty)).toList();
      final report = events.whereType<LlmRunCompleted>().single.report;

      expect(transport.lastPrompt, wire.combined);
      expect(transport.lastPrompt, isNot(wire.system));
      expect(report.promptHash, promptSha256(wire.combined));
      expect(report.promptHash, isNot(promptSha256(wire.system)));
    });

    test(
      'complete stamps the whole provenance triple, not just the anchor',
      () async {
        final transport = newTransport();
        final report = await _provider(
          transport,
        ).complete(LlmRequest(prompt: wire, options: LlmOptions.empty));

        expect(transport.lastPrompt, wire.combined);
        expect(report.anchorHash, wire.anchorHash);
        expect(report.providerId, 'claude:sonnet:none');
        expect(report.modelId, 'claude-sonnet-4-6');
        expect(report.promptHash, promptSha256(wire.combined));
        expect(report.promptHash, isNot(promptSha256(wire.system)));
        expect(report.templateSha, 'template-sha-T1');
      },
    );
  });

  group('AgentSdkLlmProvider — failure paths', () {
    test('an SDK error chunk → LlmRunFailed (report still anchored)', () async {
      final transport = _FakeAgentSdkTransport(
        messages: const <Map<String, dynamic>>[],
        error: 'bridge exploded',
      );
      final events = await _provider(
        transport,
      ).run(LlmRequest(prompt: _wire, options: LlmOptions.empty)).toList();
      expect(events.first, isA<LlmRunStarted>());
      final failed = events.last as LlmRunFailed;
      expect(failed.failure.message, contains('bridge exploded'));
      // A transport error carries no backend-specific meaning the provider
      // could recover, so it stays `unknown` for the caller to classify.
      expect(failed.failure.classCode, 'unknown');
      expect(failed.report!.anchorHash, 'anchor-hash-A1');
      expect(failed.report!.providerId, 'claude:sonnet:none');
    });

    test(
      'a result with is_error → LlmRunFailed carrying the costed report',
      () async {
        final transport = _FakeAgentSdkTransport(
          messages: <Map<String, dynamic>>[
            {
              'type': 'result',
              'subtype': 'error',
              'is_error': true,
              'result': 'turn limit exceeded',
              'duration_ms': 90,
              'total_cost_usd': 0.0005,
              'usage': {'input_tokens': 10, 'output_tokens': 0},
            },
          ],
        );
        final events = await _provider(
          transport,
        ).run(LlmRequest(prompt: _wire, options: LlmOptions.empty)).toList();
        final failed = events.last as LlmRunFailed;
        expect(failed.failure.message, contains('turn limit exceeded'));
        // A costed error result is well-formed but its *meaning* is the
        // backend's; the provider does not guess a class for it.
        expect(failed.failure.classCode, 'unknown');
        expect(failed.report!.cost, 0.0005);
        expect(failed.report!.tokensIn, 10);
      },
    );

    test(
      'a stream that closes with no result message → format failure',
      () async {
        final transport = _FakeAgentSdkTransport(
          messages: <Map<String, dynamic>>[
            {
              'type': 'assistant',
              'message': {
                'content': [
                  {'type': 'text', 'text': 'partial...'},
                ],
              },
            },
          ],
        );
        final events = await _provider(
          transport,
        ).run(LlmRequest(prompt: _wire, options: LlmOptions.empty)).toList();
        final failed = events.last as LlmRunFailed;
        // `format`, not `unknown`: a stream that ended without a terminal result
        // is malformed in a way the provider observed for itself. It is the only
        // class the provider settles, and the second of the two a consumer of
        // this layer has to handle.
        expect(failed.failure.classCode, 'format');
      },
    );

    test(
      'complete() throws the contract failure, carrying the SDK error',
      () async {
        final transport = _FakeAgentSdkTransport(
          messages: const <Map<String, dynamic>>[],
          error: 'nope',
        );
        expect(
          () => _provider(
            transport,
          ).complete(LlmRequest(prompt: _wire, options: LlmOptions.empty)),
          throwsA(
            isA<LlmTransportException>()
                .having((e) => e.kind, 'kind', LlmErrorKind.remote)
                .having((e) => e.cause, 'cause', isA<AgentSdkQueryException>()),
          ),
        );
      },
    );
  });

  group('AgentSdkLlmProvider — rebindBridgePort (/cli_server_port)', () {
    // A success result so a run resolves the memoised client.
    List<Map<String, dynamic>> successMessages() => <Map<String, dynamic>>[
      {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'ok',
        'duration_ms': 5,
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      },
    ];

    test(
      'rebuilds the client against the new port and disposes the old one',
      () async {
        final factoryPorts = <int>[];
        final disposed = <AgentSdkClient>[];
        final transport = _FakeAgentSdkTransport(messages: successMessages());
        final provider = AgentSdkLlmProvider(
          id: 'claude:sonnet:none',
          defaultModel: 'claude-sonnet-4-6',
          bridgePort: 19900,
          clientFactory: (port) async {
            factoryPorts.add(port);
            return AgentSdkClient(transport);
          },
          clientDisposer: (client) async => disposed.add(client),
        );

        // First call memoises a client on the original port.
        await provider
            .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
            .toList();
        expect(factoryPorts, <int>[19900]);

        // Rebind to a new port: returns true, evicts + disposes the old client.
        final changed = await provider.rebindBridgePort(20000);
        expect(changed, isTrue);
        expect(provider.bridgePort, 20000);
        expect(disposed, hasLength(1));

        // The next call reconnects on the new port.
        await provider
            .run(LlmRequest(prompt: _wire, options: LlmOptions.empty))
            .toList();
        expect(factoryPorts, <int>[19900, 20000]);
      },
    );

    test('rebinding to the same port is a no-op (returns false)', () async {
      final transport = _FakeAgentSdkTransport(messages: successMessages());
      final provider = AgentSdkLlmProvider(
        id: 'claude:sonnet:none',
        defaultModel: 'claude-sonnet-4-6',
        bridgePort: 19900,
        clientFactory: (port) async => AgentSdkClient(transport),
      );
      expect(await provider.rebindBridgePort(19900), isFalse);
      expect(provider.bridgePort, 19900);
    });

    test(
      'rebinding before any call records the port without disposing',
      () async {
        var disposeCalls = 0;
        final transport = _FakeAgentSdkTransport(messages: successMessages());
        final provider = AgentSdkLlmProvider(
          id: 'claude:sonnet:none',
          defaultModel: 'claude-sonnet-4-6',
          bridgePort: 19900,
          clientFactory: (port) async => AgentSdkClient(transport),
          clientDisposer: (client) async => disposeCalls++,
        );
        expect(await provider.rebindBridgePort(20100), isTrue);
        expect(provider.bridgePort, 20100);
        // No client was memoised yet, so nothing to dispose.
        expect(disposeCalls, 0);
      },
    );
  });
}

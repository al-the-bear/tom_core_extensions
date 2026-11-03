/// What the CLI-server channel puts in a query's options, and the
/// conversation id it reports back — over the real wire to a fake server.
///
/// The provider-level resume tests (`resume_test.dart`) drive a scripted
/// transport; these hold the one place the options are actually composed.
@Timeout(Duration(seconds: 60))
library;

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';

Future<(FakeAiServer, HostedCliServerAiTransport)> _connected({
  List<Map<String, dynamic>> recorded = const [],
}) async {
  final server = await FakeAiServer.start(
    behaviour: recorded.isEmpty
        ? FakeAiServerBehaviour.succeed
        : FakeAiServerBehaviour.replay,
    recorded: recorded,
  );
  addTearDown(server.stop);
  final transport = HostedCliServerAiTransport(
    minPort: server.port,
    maxPort: server.port,
  );
  addTearDown(transport.close);
  await transport.connect();
  return (server, transport);
}

Map<String, dynamic> _queryOptions(FakeAiServer server) {
  final query = server.requests.firstWhere(
    (r) => r['method'] == 'agentSdk.queryVce',
  );
  final params = (query['params'] as Map).cast<String, dynamic>();
  return (params['options'] as Map).cast<String, dynamic>();
}

void main() {
  test('CHANNEL-1: a plain completion turns the SDK tools off, allows one '
      'turn, and resumes the conversation it names', () async {
    final (server, transport) = await _connected();

    await transport
        .complete(const AgentSdkCompletionRequest(prompt: 'Hi.', resume: 'c-1'))
        .drain<void>();

    final options = _queryOptions(server);
    expect(options['resume'], 'c-1');
    expect(options['maxTurns'], 1);
    expect(options['tools'], isEmpty);
    expect(options.containsKey('permissionMode'), isFalse);
  });

  test("CHANNEL-2: Claude Code's own loop keeps its tools and takes the "
      'turns and permission mode it was given', () async {
    final (server, transport) = await _connected();

    await transport
        .complete(
          const AgentSdkCompletionRequest(
            prompt: 'Hi.',
            agentLoop: AgentSdkAgentLoop(
              maxTurns: 9,
              permissionMode: 'acceptEdits',
            ),
          ),
        )
        .drain<void>();

    final options = _queryOptions(server);
    expect(options['maxTurns'], 9);
    expect(options['permissionMode'], 'acceptEdits');
    expect(options.containsKey('tools'), isFalse);
    expect(options.containsKey('allowedTools'), isFalse);
    expect(options.containsKey('resume'), isFalse);
  });

  test(
    'CHANNEL-3: the conversation the far end names is reported once',
    () async {
      final (_, transport) = await _connected(
        recorded: [
          {
            'type': 'system',
            'subtype': 'init',
            'session_id': 'c-42',
            'model': 'claude-test',
            'tools': <String>[],
          },
          {
            'type': 'result',
            'subtype': 'success',
            'is_error': false,
            'result': 'ok',
            'session_id': 'c-42',
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          },
        ],
      );

      final events = await transport
          .complete(const AgentSdkCompletionRequest(prompt: 'Hi.'))
          .toList();

      expect(events.whereType<AgentSdkConversation>().map((e) => e.id), [
        'c-42',
      ]);
    },
  );
}

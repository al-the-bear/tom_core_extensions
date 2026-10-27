/// A stand-in for `agent_sdk_server.js` that answers every query with the
/// Agent SDK messages a live standalone run recorded
/// (`test/agent_sdk/fixtures/sdk_messages/standalone_agent_run.json`, written by
/// `event_stream_live_test.dart`).
///
/// Spawned by the standalone transport exactly as the real server is, so the
/// replay crosses the same process boundary, socket and framing a live run
/// does. Run from the package root, as the suite is.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/agent_sdk_testing.dart';

/// Where the standalone recording is, relative to the package root.
const standaloneRecording =
    'test/agent_sdk/fixtures/sdk_messages/standalone_agent_run.json';

Future<void> main(List<String> args) async {
  final recorded = [
    for (final message
        in jsonDecode(File(standaloneRecording).readAsStringSync()) as List)
      (message as Map).cast<String, dynamic>(),
  ];
  final server = await FakeAiServer.start(
    behaviour: FakeAiServerBehaviour.replay,
    recorded: recorded,
  );
  stdout.writeln('$readyPrefix${jsonEncode({'port': server.port})}');
  // The same liveness contract as the real server: stdin closes, we exit.
  await stdin.drain<void>();
  await server.stop();
  exit(0);
}

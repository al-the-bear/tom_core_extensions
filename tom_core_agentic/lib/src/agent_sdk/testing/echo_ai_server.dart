/// A spawnable fixture that answers every query with **the prompt it was
/// given**.
///
/// This exists so the standalone transport's privacy test has evidence from
/// the far side of a real child process. The hosted test can read
/// [FakeAiServer.receivedBytes] because the fixture lives in the test's own
/// isolate; a spawned child's buffers are unreachable, so instead the child
/// echoes what it received and the test inspects the echo. A secret would have
/// to have crossed the socket to come back.
library;

import 'dart:convert';
import 'dart:io';

import 'fake_ai_server.dart';

Future<void> main(List<String> args) async {
  final server = await FakeAiServer.start(
    behaviour: FakeAiServerBehaviour.echoPrompt,
  );
  stdout.writeln('$readyPrefix${jsonEncode({'port': server.port})}');
  await stdin.drain<void>();
  await server.stop();
  exit(0);
}

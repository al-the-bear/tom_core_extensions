/// A spawnable fixture that reports **the `PATH` it was started with**.
///
/// The Agent SDK does not run inside the server process — it spawns the Claude
/// Code CLI as a grandchild, under the bare name `node`. So the interpreter the
/// grandchild gets is whatever `PATH` resolves, not the one the app chose, and
/// a stale entry there makes a correctly-configured transport fail with an
/// error that names no cause. The transport therefore puts its own Node's
/// directory at the front of the child's `PATH`.
///
/// That is only observable from the far side of the spawn, which is what this
/// fixture is for: it prints its inherited `PATH` on stdout before the ready
/// line, where the transport's "anything else on stdout is diagnostics" rule
/// hands it to `onStderr` and the test can read it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/agent_sdk_testing.dart';

/// Marks the reported line, so the test matches on intent rather than on a
/// substring that could plausibly occur in real diagnostics.
const pathReportPrefix = 'AGENT_SDK_TEST_PATH ';

Future<void> main(List<String> args) async {
  stdout.writeln('$pathReportPrefix${Platform.environment['PATH'] ?? ''}');
  final server = await FakeAiServer.start(
    behaviour: FakeAiServerBehaviour.echoPrompt,
  );
  stdout.writeln('$readyPrefix${jsonEncode({'port': server.port})}');
  await stdin.drain<void>();
  await server.stop();
  exit(0);
}

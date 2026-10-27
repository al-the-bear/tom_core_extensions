/// The compiled form of the `### Example` section of the Agent SDK provider in
/// `../../README.md`.
///
/// Every `dart` fence in that section appears here verbatim; a snippet that is
/// only displayed has not been shown to compile.
///
/// It is safe to run with no AI server anywhere: `initialize` never throws and
/// the gate is then shut, so the example prints the prompt and stops.
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/io.dart';

Future<void> main() async {
  const request = LlmRequest(
    prompt: WirePrompt(
      system: 'The formula engine now recalculates transitively.',
      user: 'Summarize this in five words.',
      anchorHash: '',
      roleId: 'summarize',
    ),
  );
  print(request.prompt.combined);
  // The formula engine now recalculates transitively.
  //
  // Summarize this in five words.

  final selector = AgentSdkTransportSelector([
    HostedCliServerAiTransport(), // a running VS Code
    StandaloneNodeAiTransport(
      node: llmNodeResolverFor(), // PATH, nvm, Homebrew, /usr/local
      apiKey: Platform.environment['ANTHROPIC_API_KEY'],
    ), // our own Node process
  ]);
  await selector.initialize(); // never throws
  // Every run is served from a session in its own isolate.
  final sessions = AgentSdkSessionManager();
  final provider = AgentSdkSessionProvider(
    selector: selector,
    sessions: sessions,
    toolServerName: 'tools',
  );

  if (provider.isAvailable) {
    await for (final delta in llmAnswerText(provider.run(request))) {
      stdout.write(delta);
    }
  } else {
    // The ordinary offline case: the app stays usable, AI gated off.
    print('AI unavailable');
  }
  await sessions.dispose();
  await selector.dispose();
}

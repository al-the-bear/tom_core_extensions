/// A spawned fixture that accepts a query and then says nothing — the standalone
/// counterpart to driving [FakeAiServerBehaviour.hang] over a hosted socket.
///
/// **Why a second script rather than an argument.** The standalone transport
/// spawns `[serverScript]` and nothing else, deliberately: the credential rule
///  is that nothing configurable reaches the child's `argv`, and adding a
/// `serverArgs` field to production code so that a test could pass one would be
/// production surface bought entirely by a test. A second entry point costs
/// nothing and keeps the spawn line exactly as it ships.
///
/// **Why it exists at all.** The stall bound is the provider's and reaches
/// every transport by construction, but the shared `error mapping` group only
/// drives the hosted one. The standalone path is the one where the Agent
/// SDK's indefinite stall was actually measured, so it is the last place a
/// stream that never ends should go unexercised: this fixture proves that a
/// hung child yields the bound nothing to count, and that the abandonment
/// names `standalone-node`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/agent_sdk_testing.dart';

Future<void> main(List<String> args) async {
  final server = await FakeAiServer.start(
    behaviour: FakeAiServerBehaviour.hang,
  );
  stdout.writeln('$readyPrefix${jsonEncode({'port': server.port})}');
  // The same liveness contract as the real server: stdin closes, we exit.
  await stdin.drain<void>();
  await server.stop();
  exit(0);
}

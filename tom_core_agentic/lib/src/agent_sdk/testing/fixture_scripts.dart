/// Where the spawnable fixture servers are on disk.
library;

import 'dart:io';
import 'dart:isolate';

/// The path of the spawnable fixture `<name>.dart` this package ships for
/// tests — `fake_ai_server` (scripted answers) or `echo_ai_server` (answers
/// with the prompt it received) — for a standalone transport to start as its
/// server script, with a Dart CLI standing in for Node.
///
/// Resolved through the package configuration, so a suite in another package
/// reaches the same fixture this package's own suites run.
String agentSdkFixtureScript(String name) {
  final uri = Isolate.resolvePackageUriSync(
    Uri.parse('package:tom_core_agentic/src/agent_sdk/testing/$name.dart'),
  );
  if (uri == null) {
    throw StateError('no package configuration resolves tom_core_agentic');
  }
  final path = File.fromUri(uri).path;
  if (!File(path).existsSync()) {
    throw ArgumentError.value(name, 'name', 'no such fixture server');
  }
  return path;
}

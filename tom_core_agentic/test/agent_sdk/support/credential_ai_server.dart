/// A spawnable fixture that reports **the credential environment it was
/// started with**.
///
/// Whether a key given to the standalone transport is the only credential the
/// child can use is only observable from the far side of the spawn: this
/// fixture prints, before the ready line, the configuration directory it was
/// pointed at, whether that directory exists and is empty, and the names of
/// every Anthropic or Claude Code variable it inherited. The transport hands
/// that line to `onStderr` (anything on stdout before the ready line is
/// diagnostics), where the test reads it. The key's value is never printed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/agent_sdk_testing.dart';

/// Marks the reported line.
const credentialReportPrefix = 'AGENT_SDK_TEST_CREDENTIAL ';

Future<void> main(List<String> args) async {
  final environment = Platform.environment;
  final configDir = environment['CLAUDE_CONFIG_DIR'];
  final dir = configDir == null ? null : Directory(configDir);
  stdout.writeln(
    '$credentialReportPrefix${jsonEncode({
      'configDir': configDir,
      'configDirEmpty': dir != null && dir.existsSync() && dir.listSync().isEmpty,
      'names': [for (final name in environment.keys)
        if (name.toUpperCase().startsWith('ANTHROPIC_') || name.toUpperCase().startsWith('CLAUDE')) name]..sort(),
    })}',
  );
  final server = await FakeAiServer.start(
    behaviour: FakeAiServerBehaviour.echoPrompt,
  );
  stdout.writeln('$readyPrefix${jsonEncode({'port': server.port})}');
  await stdin.drain<void>();
  await server.stop();
  exit(0);
}

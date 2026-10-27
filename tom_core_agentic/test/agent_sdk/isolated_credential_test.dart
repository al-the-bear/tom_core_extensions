/// A key given to the standalone transport is the only
/// credential the server child can use.
///
/// The environment map is asserted in `_child_environment_test.dart`;
/// here the transport is run against a fixture that reports what it actually
/// received, so the per-child configuration directory is seen from the far
/// side of the spawn: created empty under the root the transport was given,
/// handed to the child, and removed when the transport closes.
///
/// The live counterpart — an invalid explicit key yields "no model" on a
/// machine logged in to Claude Code — is the probe test in
/// `live_completion_test.dart`.
// Spawns a child: the harness bound is three times the startup bound, as
// `support/spawn_timings.dart` requires.
@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';

import 'package:tom_llm/tom_llm.dart';

import 'support/credential_ai_server.dart' show credentialReportPrefix;
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/stand_in.dart';

Future<Map<String, Object?>> _connectAndReport(
  StandaloneNodeAiTransport transport,
  List<String> reported,
) async {
  await transport.connect();
  final line = reported.firstWhere(
    (l) => l.startsWith(credentialReportPrefix),
    orElse: () => '',
  );
  expect(line, isNotEmpty, reason: 'the fixture reported nothing');
  return jsonDecode(line.substring(credentialReportPrefix.length))
      as Map<String, Object?>;
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('agent_sdk_credential-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a child started with a key gets a fresh, empty '
      'configuration directory under the given root, and only that key '
      '', () async {
    final reported = <String>[];
    final transport = StandaloneNodeAiTransport(
      node: llmNodeAt(standInExecutable),
      serverScript: 'test/agent_sdk/support/credential_ai_server.dart',
      apiKey: 'sk-ant-test-isolated',
      credentialIsolationRoot: root.path,
      startupTimeout: spawnStartupTimeout,
      onStderr: reported.add,
    );
    addTearDown(transport.close);
    final report = await _connectAndReport(transport, reported);

    final configDir = report['configDir'] as String?;
    expect(configDir, isNotNull);
    expect(Directory(configDir!).parent.path, root.path);
    expect(report['configDirEmpty'], isTrue);
    expect(report['names'], ['ANTHROPIC_API_KEY', 'CLAUDE_CONFIG_DIR']);

    await transport.close();
    expect(
      Directory(configDir).existsSync(),
      isFalse,
      reason: 'the directory is the child\'s and goes with it',
    );
  });

  test('two children never share a configuration directory '
      '', () async {
    final dirs = <String>[];
    for (var i = 0; i < 2; i++) {
      final reported = <String>[];
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        serverScript: 'test/agent_sdk/support/credential_ai_server.dart',
        apiKey: 'sk-ant-test-isolated',
        credentialIsolationRoot: root.path,
        startupTimeout: spawnStartupTimeout,
        onStderr: reported.add,
      );
      addTearDown(transport.close);
      dirs.add(
        (await _connectAndReport(transport, reported))['configDir']! as String,
      );
    }
    expect(dirs.toSet(), hasLength(2));
  });

  test('with no key no configuration directory is made and '
      'the parent\'s is kept', () async {
    final reported = <String>[];
    final transport = StandaloneNodeAiTransport(
      node: llmNodeAt(standInExecutable),
      serverScript: 'test/agent_sdk/support/credential_ai_server.dart',
      credentialIsolationRoot: root.path,
      startupTimeout: spawnStartupTimeout,
      onStderr: reported.add,
    );
    addTearDown(transport.close);
    final report = await _connectAndReport(transport, reported);
    expect(report['configDir'], Platform.environment['CLAUDE_CONFIG_DIR']);
    expect(root.listSync(), isEmpty);
  });

  test('an app keeps its configuration directories beside '
      'the installed server', () {
    final sep = Platform.pathSeparator;
    expect(
      StandaloneNodeAiTransport.credentialIsolationRootFor('${sep}data'),
      '${sep}data${sep}ai${sep}isolated-config',
    );
  });
}

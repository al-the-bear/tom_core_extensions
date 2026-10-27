/// The transport, its probe and the installer run the one Node the
/// resolution names, never the bare name `node`.
///
/// The search itself is core's (`_node_discovery_test.dart`). What
/// is under test here is the hand-over: a transport is given a resolver, runs
/// it on its first probe, keeps a resolution that found a Node and re-runs one
/// that found none; the gate's `noRuntime` sentence is the search's own
/// account of where it looked; and the installer is handed the resolution
/// rather than asking for a Node of its own.
///
/// **Deadline.** The stand-in probes are child processes of a few seconds at
/// most, so the file states its own bound (seam TEST-DEADLINE).
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/stand_in.dart';

final String _sep = Platform.pathSeparator;

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// A source folder carrying the three shipped files, so an install gets as
/// far as the Node check.
String _source() {
  final dir = _tempDir('agent_sdk_source').path;
  for (final name in agentSdkServerSourceFiles) {
    File('$dir$_sep$name').writeAsStringSync('// $name\n');
  }
  return dir;
}

/// The measured machine from Finder: a v16 in /usr/local, nothing else.
const _nothingNew = LlmNodeResolution(
  executable: null,
  version: null,
  looked: [
    LlmNodeCandidate(
      path: '/usr/bin/node',
      source: LlmNodeSource.path,
      outcome: LlmNodeLookOutcome.absent,
    ),
    LlmNodeCandidate(
      path: '/Users/alexis/.nvm/versions/node/*/bin/node',
      source: LlmNodeSource.nvm,
      outcome: LlmNodeLookOutcome.absent,
    ),
    LlmNodeCandidate(
      path: '/usr/local/bin/node',
      source: LlmNodeSource.usrLocal,
      outcome: LlmNodeLookOutcome.tooOld,
      version: 'v16.17.0',
      major: 16,
    ),
  ],
  setting: null,
  pathEntries: ['/usr/bin'],
);

/// Records every command the installer runs and refuses to run any.
class _Recorder {
  final List<String> executables = [];

  Future<int> call(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required void Function(String line) onOutput,
  }) async {
    executables.add(executable);
    throw ProcessException(executable, arguments, 'refused by the test', 1);
  }
}

void main() {
  group('the gate speaks for the search', () {
    test('a resolution that found nothing is noRuntime, and the '
        'sentence names where the search looked and what it found', () async {
      var runs = 0;
      final transport = StandaloneNodeAiTransport(
        node: () async {
          runs++;
          return _nothingNew;
        },
        serverScript: '${_source()}$_sep$agentSdkServerScriptName',
      );
      addTearDown(transport.close);

      expect(await transport.probe(), isFalse);
      expect(transport.unavailableKind, AgentSdkUnavailableKind.noRuntime);
      final reason = transport.unavailableReason!;
      expect(
        reason,
        contains('"/usr/local/bin/node" is v16.17.0, below 20'),
        reason: 'THE POINT: the v16 is named by its version',
      );
      expect(reason, contains('nothing under ~/.nvm/versions/node'));
      expect(reason, contains('no node on PATH (/usr/bin)'));
      expect(
        reason,
        contains('point the setting'),
        reason: 'the remedy the user can perform from the app',
      );
      expect(transport.nodeExecutable, isNull);
      expect(runs, 1);
    });

    test('a search that found nothing runs again on the next '
        'probe — Retry after installing Node must see the new machine; one '
        'that found a Node is kept', () async {
      var runs = 0;
      var found = false;
      final transport = StandaloneNodeAiTransport(
        node: () async {
          runs++;
          return found
              ? LlmNodeResolution.explicit(standInExecutable)
              : _nothingNew;
        },
        serverScript: '${_source()}$_sep$agentSdkServerScriptName',
      );
      addTearDown(transport.close);

      expect(await transport.probe(), isFalse);
      expect(await transport.probe(), isFalse);
      expect(runs, 2, reason: 'not found: searched again');

      found = true;
      expect(await transport.probe(), isTrue);
      expect(transport.nodeExecutable, standInExecutable);
      expect(await transport.probe(), isTrue);
      expect(runs, 3, reason: 'found: kept, not searched again');
    });

    test('a vouched-for path that is not runnable is reported as '
        'such, naming the path — not as "not found"', () async {
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt('/nonexistent/agent_sdk/node'),
        serverScript: '${_source()}$_sep$agentSdkServerScriptName',
      );
      addTearDown(transport.close);
      expect(await transport.probe(), isFalse);
      expect(transport.unavailableKind, AgentSdkUnavailableKind.noRuntime);
      expect(
        transport.unavailableReason,
        agentSdkNodeNotRunnableReason('/nonexistent/agent_sdk/node'),
      );
      expect(transport.unavailableReason, isNot(contains('was found')));
    });
  });

  group('the installer is handed the resolution', () {
    test('an install with no Node found fails with the search\'s '
        'sentence and runs nothing', () async {
      final recorder = _Recorder();
      final installer = AgentSdkServerInstaller(
        sourceDir: _source(),
        installDir: '${_tempDir('agent_sdk_app_data').path}${_sep}ai',
        runCommand: recorder.call,
      );
      final result = await installer.install(node: _nothingNew);
      expect(result.ok, isFalse);
      expect(result.failure, agentSdkNodeMissingReason(_nothingNew));
      expect(
        recorder.executables,
        isEmpty,
        reason: 'nothing to probe, so nothing is spawned',
      );
    });

    test('the transport installs with the Node it resolved, so '
        'the probe, the connect and npm agree on one executable', () async {
      final recorder = _Recorder();
      final appData = _tempDir('agent_sdk_app_data').path;
      var runs = 0;
      final transport = StandaloneNodeAiTransport(
        node: () async {
          runs++;
          return LlmNodeResolution.explicit(standInExecutable);
        },
        installer: AgentSdkServerInstaller(
          sourceDir: _source(),
          installDir: AgentSdkServerInstaller.installDirFor(appData),
          runCommand: recorder.call,
        ),
      );
      addTearDown(transport.close);

      // Node is fine, the server is not installed: the gate offers Install.
      expect(await transport.probe(), isFalse);
      expect(transport.unavailableKind, AgentSdkUnavailableKind.notInstalled);

      final outcome = await transport.install();
      expect(outcome.ok, isFalse, reason: 'the recorder refuses to run npm');
      expect(
        recorder.executables,
        [standInExecutable],
        reason:
            'THE POINT: the installer probed the resolved executable, '
            'not `node`',
      );
      expect(runs, 1, reason: 'one resolution, shared by probe and install');
    });

    test('forApp takes the resolver and builds an installer '
        'without a Node of its own', () async {
      final transport = StandaloneNodeAiTransport.forApp(
        appDataDirectory: _tempDir('agent_sdk_app_data').path,
        node: () async => _nothingNew,
      );
      addTearDown(transport.close);
      expect(transport.installer, isNotNull);
      expect(await transport.probe(), isFalse);
      expect(
        transport.unavailableKind,
        AgentSdkUnavailableKind.noRuntime,
        reason: 'Node first: Install is not offered without one',
      );
      expect(transport.unavailableReason, contains('below 20'));
    });

    test('the floor the probe enforces is the floor the search '
        'enforces', () {
      expect(requiredNodeMajorVersion, _nothingNew.floor);
    });
  });
}

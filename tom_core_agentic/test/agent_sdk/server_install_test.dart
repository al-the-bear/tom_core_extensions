/// The Agent SDK is installed by the user, not shipped.
///
/// A build carries the AI server's three source files and no `node_modules`;
/// the app installs Anthropic's Claude Agent SDK into its own data folder when
/// the user presses Install in the availability notice. Under test:
///
///  - **the build** carries exactly the source and nothing of the SDK, and the
///  release gate refuses a build that carries either too little or too much;
///  - **the gate** reports `notInstalled` as its own kind, distinct from a
///  missing Node and from an unanswered server, with the explanation link;
///  - **the installer** runs `npm ci --omit=dev` into the target with the
///  probed Node first on `PATH`, checks the tree before calling it
///  installed, and leaves the previous state untouched when anything fails;
///  - **the platform choice** never ends in "no CLI": a Node the locked SDK
///  ships nothing for is refused before anything is downloaded.
///
/// The installer is driven through an injected command runner, because `npm
/// ci` needs a registry and a network. The real install is
/// `_packaging_test.dart`'s last group, against
/// `AGENT_SDK_APP_DATA`.
///
/// **Deadline.** The gate tests probe a stand-in executable (a child process,
/// a few seconds at most), so the file states its own bound (seam
/// TEST-DEADLINE).
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/stand_in.dart';
import 'support/sessions.dart';

final String _sep = Platform.pathSeparator;

const _absentNode = '/nonexistent/agent_sdk/node-that-is-not-installed';

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Every platform suffix the Agent SDK 0.3.286 ships a CLI package for.
const _sdk0_3_286 = {
  'darwin-arm64',
  'darwin-x64',
  'linux-arm64',
  'linux-arm64-musl',
  'linux-x64',
  'linux-x64-musl',
  'win32-arm64',
  'win32-x64',
};

/// A lockfile that locks the SDK with [platforms] as its CLI packages.
String _lockfile({
  Set<String> platforms = _sdk0_3_286,
  String version = '0.3.286',
}) => jsonEncode({
  'name': 'agent-sdk-server',
  'lockfileVersion': 3,
  'packages': {
    '': {
      'dependencies': {'@anthropic-ai/claude-agent-sdk': '^$version'},
    },
    'node_modules/@anthropic-ai/claude-agent-sdk': {
      'version': version,
      'optionalDependencies': {
        for (final p in platforms) '@anthropic-ai/claude-agent-sdk-$p': version,
      },
    },
  },
});

/// A server source folder: the three files a build carries.
String _source({String? lockfile}) {
  final dir = _tempDir('agent_sdk_source').path;
  File('$dir$_sep$agentSdkServerScriptName').writeAsStringSync('// server');
  File('$dir${_sep}package.json').writeAsStringSync('{"name":"server"}');
  File(
    '$dir$_sep$agentSdkServerLockfileName',
  ).writeAsStringSync(lockfile ?? _lockfile());
  return dir;
}

/// Writes what `npm ci` would leave for a Node on [platform] into [dir].
void _writeInstalledTree(String dir, String platform, {bool withCli = true}) {
  final modules = '$dir${_sep}node_modules';
  final scope = '$modules$_sep@anthropic-ai';
  final sdk = '$scope${_sep}claude-agent-sdk';
  Directory(sdk).createSync(recursive: true);
  File('$sdk${_sep}package.json').writeAsStringSync(
    jsonEncode({
      'name': '@anthropic-ai/claude-agent-sdk',
      'main': 'sdk.mjs',
      'peerDependencies': {'@anthropic-ai/sdk': '>=0.93.0', 'zod': '^4.0.0'},
    }),
  );
  File('$sdk${_sep}sdk.mjs').writeAsStringSync('// entry');
  for (final peer in ['$scope${_sep}sdk', '$modules${_sep}zod']) {
    Directory(peer).createSync(recursive: true);
    File('$peer${_sep}package.json').writeAsStringSync('{}');
  }
  if (!withCli) return;
  final cliDir = '$scope${_sep}claude-agent-sdk-$platform';
  Directory(cliDir).createSync(recursive: true);
  final cli = File(
    '$cliDir$_sep${platform.startsWith('win32-') ? 'claude.exe' : 'claude'}',
  )..writeAsStringSync('#!/bin/sh');
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['+x', cli.path], runInShell: false);
  }
}

/// One command the installer ran.
typedef _Call = ({
  String executable,
  List<String> arguments,
  String workingDirectory,
  Map<String, String> environment,
});

/// Stands in for both `node -p …` and `npm ci`: answers the probe with a
/// stated runtime, and "installs" by writing the tree npm would.
class _FakeCommands {
  _FakeCommands({
    this.nodeVersion = '22.22.3',
    this.platform = 'darwin',
    this.arch = 'arm64',
    this.npmExit = 0,
    this.writeCli = true,
    this.nodeStartFails = false,
  });

  final String nodeVersion;
  final String platform;
  final String arch;
  final String execPath = '/opt/agent-sdk-test-node/bin/node';
  final int npmExit;
  final bool writeCli;
  final bool nodeStartFails;
  final calls = <_Call>[];

  bool get ranNpm => calls.any((c) => c.arguments.contains('ci'));

  Future<int> call(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required void Function(String line) onOutput,
  }) async {
    calls.add((
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    ));
    if (arguments.contains('-p')) {
      if (nodeStartFails) {
        throw ProcessException(executable, arguments, 'not found', 2);
      }
      for (final line in [nodeVersion, platform, arch, execPath]) {
        onOutput(line);
      }
      return 0;
    }
    if (npmExit != 0) {
      onOutput('npm ERR! code ECONNREFUSED');
      return npmExit;
    }
    _writeInstalledTree(workingDirectory, '$platform-$arch', withCli: writeCli);
    onOutput('added 103 packages in 6s');
    return 0;
  }
}

AgentSdkServerInstaller _installer({
  required String source,
  required String installDir,
  required _FakeCommands commands,
}) => AgentSdkServerInstaller(
  sourceDir: source,
  installDir: installDir,
  runCommand: commands.call,
);

/// The installer's Node, as the transport would hand it over: a path the
/// caller vouches for, probed through the fake runner like any other.
const _node = LlmNodeResolution.explicit('node');

/// A transport whose install the test controls, for the selector's half.
class _InstallableTransport implements AgentSdkInstallableTransport {
  /// Lives only where it was made: its state is the test's.
  @override
  AgentSdkServerTransport Function()? get sessionCopy => null;

  bool installed = false;
  int installs = 0;
  Completer<void>? hold;

  @override
  String get id => 'installable';

  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    canUseTools: false,
    maxContextTokens: 1000,
  );

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  AgentSdkUnavailableKind? get unavailableKind =>
      installed ? null : AgentSdkUnavailableKind.notInstalled;

  @override
  String? get unavailableReason =>
      installed ? null : 'not installed — see $agentSdkInstallExplanationUrl';

  @override
  String? get selectionNotice => null;

  @override
  Future<bool> probe() async => installed;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) =>
      Stream.value(const AgentSdkTrailed(LlmTextDelta('ok')));

  @override
  Future<void> close() async => _connected = false;

  @override
  Future<AgentSdkInstallOutcome> install({
    void Function(String line)? onProgress,
  }) async {
    installs++;
    onProgress?.call('installing');
    await hold?.future;
    installed = true;
    return const AgentSdkInstallOutcome.succeeded();
  }
}

void main() {
  group('the build carries the source and nothing of the SDK', () {
    test('staging writes exactly the three source files, never '
        'node_modules — even from a checkout that has one', () {
      final source = _source();
      _writeInstalledTree(source, 'darwin-arm64');
      final dest = '${_tempDir('agent_sdk_build').path}${_sep}ai';

      final report = stageAgentSdkServer(
        nodeSourceDir: source,
        destination: dest,
      );

      final written =
          Directory(dest)
              .listSync(recursive: true)
              .map((e) => e.path.substring(dest.length + 1))
              .toList()
            ..sort();
      expect(written, [...agentSdkServerSourceFiles]..sort());
      expect(report.files, agentSdkServerSourceFiles);
      expect(Directory('$dest${_sep}node_modules').existsSync(), isFalse);
    });

    test('a stale node_modules from an older build is removed, '
        'not merged into', () {
      final source = _source();
      final dest = '${_tempDir('agent_sdk_build').path}${_sep}ai';
      _writeInstalledTree(dest, 'darwin-arm64');

      stageAgentSdkServer(nodeSourceDir: source, destination: dest);

      expect(Directory('$dest${_sep}node_modules').existsSync(), isFalse);
      expect(verifyAgentSdkServerSource(sourceDir: dest).ok, isTrue);
    });

    test('the release gate refuses a plain flutter build, naming '
        'the step that was skipped', () {
      final exeDir = _tempDir('agent_sdk_plain_build');
      final result = verifyAgentSdkServerSource(
        sourceDir: '${exeDir.path}${_sep}ai',
      );
      expect(result.ok, isFalse);
      expect(result.problems, hasLength(1));
      expect(result.problems.single, contains('package_app.dart'));
    });

    test('the release gate refuses a build that carries the SDK '
        '— in node_modules or anywhere else', () {
      final withModules = _source();
      _writeInstalledTree(withModules, 'darwin-arm64');
      final refused = verifyAgentSdkServerSource(sourceDir: withModules);
      expect(refused.ok, isFalse);
      expect(refused.problems.join(' | '), contains('node_modules'));
      expect(refused.problems.join(' | '), contains("Anthropic's terms"));

      final stray = _source();
      Directory(
        '$stray${_sep}vendor$_sep@anthropic-ai${_sep}claude-agent-sdk',
      ).createSync(recursive: true);
      final strayResult = verifyAgentSdkServerSource(sourceDir: stray);
      expect(strayResult.ok, isFalse);
      expect(strayResult.problems.join(' | '), contains('Agent SDK'));
    });

    test('every source file is required, and the lockfile must '
        'lock the SDK', () {
      for (final name in agentSdkServerSourceFiles) {
        final source = _source();
        File('$source$_sep$name').deleteSync();
        final result = verifyAgentSdkServerSource(sourceDir: source);
        expect(result.ok, isFalse, reason: 'removing $name was ignored');
        expect(result.problems.join(' | '), contains(name));
      }
      final noSdk = _source(lockfile: jsonEncode({'packages': {}}));
      final result = verifyAgentSdkServerSource(sourceDir: noSdk);
      expect(result.ok, isFalse);
      expect(result.problems.join(' | '), contains('does not lock'));
    });

    test('the repository\'s own server source stages into a '
        'shippable build', () {
      final source = Directory('node');
      expect(
        File('node$_sep$agentSdkServerLockfileName').existsSync(),
        isTrue,
        reason: 'run from tom_core_agentic; the tracked source is the input',
      );
      final dest = '${_tempDir('agent_sdk_build').path}${_sep}ai';
      stageAgentSdkServer(nodeSourceDir: source.path, destination: dest);
      final result = verifyAgentSdkServerSource(sourceDir: dest);
      expect(result.problems, isEmpty, reason: result.toString());
    });
  });

  group('the gate says "not installed", and links the explanation', () {
    test('an empty app-data folder is notInstalled, distinct '
        'from no Node, and the reason carries the link', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final transport = StandaloneNodeAiTransport(
        // A runnable stand-in: Node is fine, only the install is missing.
        node: llmNodeAt(standInExecutable),
        installer: AgentSdkServerInstaller(
          sourceDir: _source(),
          installDir: AgentSdkServerInstaller.installDirFor(appData),
        ),
      );
      addTearDown(transport.close);

      expect(await transport.probe(), isFalse);
      expect(transport.unavailableKind, AgentSdkUnavailableKind.notInstalled);
      expect(transport.unavailableReason, contains('not installed'));
      expect(
        transport.unavailableReason,
        contains(agentSdkInstallExplanationUrl),
      );
      expect(transport.unavailableReason, contains('Install'));
      expect(
        transport.serverScript,
        '$appData$_sep$agentSdkServerPayloadDir$_sep'
        '$agentSdkServerScriptName',
      );

      // And `connect`, forced anyway, says the same thing instead of
      // starting a script whose import of the SDK cannot resolve.
      await expectLater(
        transport.connect(),
        throwsA(
          isA<LlmTransportException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.unreachable)
              .having((e) => e.message, 'message', contains('not installed')),
        ),
      );
    });

    test('the selector reports the kind, offers the install, '
        'and the notice carries the link', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final selector = AgentSdkTransportSelector([
        StandaloneNodeAiTransport(
          node: llmNodeAt(standInExecutable),
          installer: AgentSdkServerInstaller(
            sourceDir: _source(),
            installDir: AgentSdkServerInstaller.installDirFor(appData),
          ),
        ),
      ]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();

      expect(selector.isAvailable, isFalse);
      expect(selector.unavailableKind, AgentSdkUnavailableKind.notInstalled);
      expect(selector.needsInstall, isTrue);
      expect(notices.single.message, contains(agentSdkInstallExplanationUrl));
      expect(
        AgentSdkSessionProvider(
          sessions: testSessions(inProcess: true),
          selector: selector,
          toolServerName: 'tools',
        ).unavailableReason,
        contains(agentSdkInstallExplanationUrl),
      );
    });

    test('with no Node it is noRuntime — and no Install is '
        'offered, because an install needs Node', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final selector = AgentSdkTransportSelector([
        StandaloneNodeAiTransport(
          node: llmNodeAt(_absentNode),
          installer: AgentSdkServerInstaller(
            sourceDir: _source(),
            installDir: AgentSdkServerInstaller.installDirFor(appData),
          ),
        ),
      ]);
      addTearDown(selector.dispose);

      await selector.initialize();

      expect(selector.unavailableKind, AgentSdkUnavailableKind.noRuntime);
      expect(selector.needsInstall, isFalse);
      expect(selector.unavailableReason, contains('Node.js'));
    });

    test('a build that wired nothing is notConfigured', () async {
      final selector = AgentSdkTransportSelector(const []);
      addTearDown(selector.dispose);
      await selector.initialize();
      expect(selector.unavailableKind, AgentSdkUnavailableKind.notConfigured);
      expect(selector.needsInstall, isFalse);
    });

    test('selector.install installs, then retries — one action '
        'opens the gate; a second install while one runs is refused', () async {
      final transport = _InstallableTransport();
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);
      await selector.initialize();
      expect(selector.needsInstall, isTrue);

      transport.hold = Completer<void>();
      final lines = <String>[];
      final first = selector.install(onProgress: lines.add);
      final second = await selector.install();
      expect(second.ok, isFalse);
      expect(second.failure, contains('already running'));
      transport.hold!.complete();
      final outcome = await first;

      expect(outcome.ok, isTrue);
      expect(transport.installs, 1);
      expect(lines, ['installing']);
      expect(selector.isAvailable, isTrue);
      expect(selector.unavailableKind, isNull);
      expect(selector.needsInstall, isFalse);
    });
  });

  group('the installer', () {
    test('runs `npm ci --omit=dev` in a staging folder with the '
        'probed Node first on PATH, then the transport resolves it', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final installDir = AgentSdkServerInstaller.installDirFor(appData);
      final commands = _FakeCommands();
      final source = _source();
      final installer = _installer(
        source: source,
        installDir: installDir,
        commands: commands,
      );
      expect(installer.state, AgentSdkServerInstallState.notInstalled);

      final progress = <String>[];
      final result = await installer.install(
        node: _node,
        onProgress: progress.add,
      );

      expect(result.ok, isTrue, reason: '$result');
      expect(result.platform, 'darwin-arm64');
      expect(result.sdkVersion, '0.3.286');
      expect(result.verification?.ok, isTrue);

      final npm = commands.calls.singleWhere((c) => c.arguments.contains('ci'));
      expect(npm.arguments, containsAllInOrder(['ci', '--omit=dev']));
      expect(npm.workingDirectory, '$installDir.installing');
      expect(
        npm.environment['PATH'],
        startsWith(File(commands.execPath).parent.path),
        reason: 'npm and the SDK spawn `node` by name; it must be this one',
      );
      expect(progress, contains('added 103 packages in 6s'));

      expect(installer.state, AgentSdkServerInstallState.installed);
      expect(Directory('$installDir.installing').existsSync(), isFalse);
      final marker =
          jsonDecode(
                File(
                  '$installDir$_sep$agentSdkInstallMarkerName',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(marker['platform'], 'darwin-arm64');

      // After the install, the transport sees a server and the post-install
      // check passes on the tree where it now lives.
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        installer: installer,
      );
      addTearDown(transport.close);
      expect(
        await transport.probe(),
        isTrue,
        reason: '${transport.unavailableReason}',
      );
      expect(transport.unavailableKind, isNull);
      expect(
        verifyAgentSdkPayloadFor(
          payloadDir: installDir,
          expectedPlatform: 'darwin-arm64',
        ).ok,
        isTrue,
      );
    });

    test('an npm failure is reported with its last lines and '
        'leaves nothing behind', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final installDir = AgentSdkServerInstaller.installDirFor(appData);
      final installer = _installer(
        source: _source(),
        installDir: installDir,
        commands: _FakeCommands(npmExit: 1),
      );

      final result = await installer.install(node: _node);

      expect(result.ok, isFalse);
      expect(result.failure, contains('exit code 1'));
      expect(result.failure, contains('ECONNREFUSED'));
      expect(Directory(installDir).existsSync(), isFalse);
      expect(Directory('$installDir.installing').existsSync(), isFalse);
      expect(installer.state, AgentSdkServerInstallState.notInstalled);
    });

    test('a failed reinstall leaves the previous install '
        'working', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final installDir = AgentSdkServerInstaller.installDirFor(appData);
      final source = _source();
      expect(
        (await _installer(
          source: source,
          installDir: installDir,
          commands: _FakeCommands(),
        ).install(node: _node)).ok,
        isTrue,
      );

      final again = _installer(
        source: source,
        installDir: installDir,
        commands: _FakeCommands(npmExit: 1),
      );
      expect((await again.install(node: _node)).ok, isFalse);
      expect(again.state, AgentSdkServerInstallState.installed);
    });

    test('a tree npm produced without a CLI fails the '
        'post-install check and is not called installed', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final installDir = AgentSdkServerInstaller.installDirFor(appData);
      final installer = _installer(
        source: _source(),
        installDir: installDir,
        commands: _FakeCommands(writeCli: false),
      );

      final result = await installer.install(node: _node);

      expect(result.ok, isFalse);
      expect(result.failure, contains('no Claude Code CLI'));
      expect(installer.state, AgentSdkServerInstallState.notInstalled);
    });

    test('no Node, or an old one, stops before npm with the '
        'probe\'s own sentence', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final missing = _FakeCommands(nodeStartFails: true);
      final result = await _installer(
        source: _source(),
        installDir: AgentSdkServerInstaller.installDirFor(appData),
        commands: missing,
      ).install(node: _node);
      expect(result.ok, isFalse);
      expect(result.failure, agentSdkNodeNotRunnableReason('node'));
      expect(missing.ranNpm, isFalse);

      final old = _FakeCommands(nodeVersion: '18.20.0');
      final tooOld = await _installer(
        source: _source(),
        installDir: AgentSdkServerInstaller.installDirFor(appData),
        commands: old,
      ).install(node: _node);
      expect(tooOld.failure, agentSdkNodeTooOldReason('node', 18));
      expect(old.ranNpm, isFalse);
    });

    test('an app update that moved the lockfile makes the install '
        'outdated, and the gate says so', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final installDir = AgentSdkServerInstaller.installDirFor(appData);
      final source = _source();
      final installer = _installer(
        source: source,
        installDir: installDir,
        commands: _FakeCommands(),
      );
      expect((await installer.install(node: _node)).ok, isTrue);

      File(
        '$source$_sep$agentSdkServerLockfileName',
      ).writeAsStringSync(_lockfile(version: '0.3.300'));
      expect(installer.state, AgentSdkServerInstallState.outdated);

      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        installer: installer,
      );
      addTearDown(transport.close);
      expect(await transport.probe(), isFalse);
      expect(transport.unavailableKind, AgentSdkUnavailableKind.notInstalled);
      expect(transport.unavailableReason, contains('earlier version'));
    });

    test('a build with no server source cannot install, and says '
        'which build step was skipped', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final commands = _FakeCommands();
      final result = await _installer(
        source: '${_tempDir('agent_sdk_no_source').path}${_sep}ai',
        installDir: AgentSdkServerInstaller.installDirFor(appData),
        commands: commands,
      ).install(node: _node);
      expect(result.ok, isFalse);
      expect(result.failure, contains('package_app.dart'));
      expect(commands.calls, isEmpty);
    });
  });

  group('the CLI platform choice never ends in "none"', () {
    test('Windows on ARM gets the arm64 CLI when the SDK ships '
        'one', () {
      final choice = chooseAgentSdkPlatform(
        nodePlatform: 'win32',
        nodeArch: 'arm64',
        shipped: _sdk0_3_286,
      );
      expect(choice.platform, 'win32-arm64');
    });

    test('Windows on ARM with an SDK that ships only x64 REFUSES, '
        'naming the x64-Node remedy — it does not fall back to an x64 CLI the '
        'SDK would never find', () {
      final choice = chooseAgentSdkPlatform(
        nodePlatform: 'win32',
        nodeArch: 'arm64',
        shipped: _sdk0_3_286.difference({'win32-arm64'}),
        sdkVersion: '0.3.1',
      );
      expect(choice.ok, isFalse);
      expect(choice.platform, isNull);
      expect(choice.refusal, contains('Windows on ARM'));
      expect(choice.refusal, contains('x64 build of Node.js'));
      expect(choice.refusal, contains('0.3.1'));
    });

    test('an arch or OS the SDK has no CLI for refuses rather '
        'than installing a tree with nothing to spawn', () {
      for (final (os, arch) in [
        ('win32', 'ia32'),
        ('freebsd', 'x64'),
        ('linux', 'ppc64'),
      ]) {
        final choice = chooseAgentSdkPlatform(
          nodePlatform: os,
          nodeArch: arch,
          shipped: _sdk0_3_286,
        );
        expect(choice.ok, isFalse, reason: '$os-$arch');
        expect(choice.refusal, contains('$os-$arch'));
      }
      // Linux accepts the musl build alone: the SDK picks by libc.
      expect(
        chooseAgentSdkPlatform(
          nodePlatform: 'linux',
          nodeArch: 'x64',
          shipped: const {'linux-x64-musl'},
        ).platform,
        'linux-x64',
      );
    });

    test('the locked SDK ships a CLI for every platform the app '
        'is built for, Windows on ARM included', () {
      final lock = agentSdkInLockfile(
        File('node$_sep$agentSdkServerLockfileName').readAsStringSync(),
      );
      expect(lock, isNotNull);
      for (final (os, arch) in [
        ('darwin', 'arm64'),
        ('darwin', 'x64'),
        ('linux', 'arm64'),
        ('linux', 'x64'),
        ('win32', 'arm64'),
        ('win32', 'x64'),
      ]) {
        final choice = chooseAgentSdkPlatform(
          nodePlatform: os,
          nodeArch: arch,
          shipped: lock!.platforms,
          sdkVersion: lock.version,
        );
        expect(choice.platform, '$os-$arch', reason: '${choice.refusal}');
      }
    });

    test('the installer refuses a Node whose platform the locked '
        'SDK skips BEFORE downloading anything', () async {
      final appData = _tempDir('agent_sdk_app_data').path;
      final commands = _FakeCommands(platform: 'win32', arch: 'arm64');
      final result = await _installer(
        source: _source(
          lockfile: _lockfile(
            platforms: _sdk0_3_286.difference({'win32-arm64'}),
          ),
        ),
        installDir: AgentSdkServerInstaller.installDirFor(appData),
        commands: commands,
      ).install(node: _node);
      expect(result.ok, isFalse);
      expect(result.failure, contains('x64 build of Node.js'));
      expect(commands.ranNpm, isFalse);
    });
  });
}

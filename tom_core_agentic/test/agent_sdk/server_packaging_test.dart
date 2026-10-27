/// How the standalone Node server is shipped.
///
/// Three decisions are under test here, and each is testable in a different
/// way, which is why they are one file rather than three:
///
///  1. **Node is a prerequisite the user supplies, not something the app
///  bundles.** The consequence that matters is behavioural: a machine
///  without Node must reach the availability gate, not an error. Asserted directly,
///  by pointing the transport at an interpreter that does not exist.
///  2. **The Agent SDK is installed by the user, not shipped**. A
///  build carries the server's three source files in
///  `<app-executable-dir>/ai/` and no `node_modules`; the release gate for
///  that lives in `server_install_test.dart`, with the
///  installer. Here: the source resolves from the packaged layout, and the
///  packaged layout is never *run* from.
///  3. **What an install produces is checked before it is trusted** — the
///  post-install verification (`verifyAgentSdkPayloadFor`), taken apart one
///  piece at a time on a fixture.
///
/// The last group starts the real server out of a real install, so it needs
/// Node and an installed tree; it reads the install from
/// `AGENT_SDK_APP_DATA` (`dart run tom_core_agentic:install_agent_sdk_server
/// --app-data DIR` produces one) and skips without it — unless
/// `AGENT_SDK_REQUIRE_PAYLOAD` is set, which is what CI does.
///
/// **Deadline.** the packaged-payload tests start the **real** Node server, and one of them allows it 90s — which under the harness's 30s default was a bound that could never fire.
@Timeout(Duration(seconds: 180))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/sessions.dart';

/// Set where the end-to-end payload group must **run** rather than skip.
///
/// A release machine sets it. Locally it is unset, so a developer who has not
/// run `npm ci` in `tom_core_agentic/node` still gets a clean skip rather than a
/// failure about a tree they never asked for.
const _requirePayloadVar = 'AGENT_SDK_REQUIRE_PAYLOAD';

final bool _payloadRequired =
    (Platform.environment[_requirePayloadVar] ?? '').isNotEmpty;

/// The app data folder an installed AI server lives in (`<dir>/ai`), as
/// `dart run tom_core_agentic:install_agent_sdk_server --app-data <dir>` leaves it.
const _appDataVar = 'AGENT_SDK_APP_DATA';

const _noInstall =
    '$_appDataVar names no installed AI server — run '
    '`dart run tom_core_agentic:install_agent_sdk_server --app-data <dir>` and set '
    '$_appDataVar=<dir>';

/// `<AGENT_SDK_APP_DATA>/ai` when it holds a finished install, else null.
String? _installedServerDir() {
  final appData = Platform.environment[_appDataVar] ?? '';
  if (appData.isEmpty) return null;
  final dir = AgentSdkServerInstaller.installDirFor(appData);
  return File(
        '$dir${Platform.pathSeparator}$agentSdkInstallMarkerName',
      ).existsSync()
      ? dir
      : null;
}

/// The platform this host keeps, so a test can look for the CLI that survived
/// pruning rather than guessing which one did.
final String _hostPlatform = agentSdkHostPlatform ?? 'linux-x64';

/// A platform that is certainly not this host's.
final String _foreignPlatform = _hostPlatform == 'win32-x64'
    ? 'darwin-arm64'
    : 'win32-x64';

/// The CLI binary's name inside a platform package.
String _cliName(String platform) =>
    platform.startsWith('win32-') ? 'claude.exe' : 'claude';

/// Writes an executable CLI stand-in for [platform] under [scope].
void _writeCli(String scope, String platform) {
  final dir = '$scope${_sep}claude-agent-sdk-$platform';
  Directory(dir).createSync(recursive: true);
  final cli = File('$dir$_sep${_cliName(platform)}')
    ..writeAsStringSync('#!/bin/sh');
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['+x', cli.path], runInShell: false);
  }
}

/// A path that cannot resolve to an executable on any platform.
const _absentNode = '/nonexistent/agent_sdk/node-that-is-not-installed';

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// The repository's own `node/` folder, or null when it cannot be found.
Directory? _sourceNodeDir() {
  final sep = Platform.pathSeparator;
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}${sep}node');
    if (File('${candidate.path}${sep}agent_sdk_server.js').existsSync()) {
      return candidate;
    }
    final nested = Directory('${dir.path}${sep}tom_core_agentic${sep}node');
    if (File('${nested.path}${sep}agent_sdk_server.js').existsSync()) {
      return nested;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// The platform separator, named once because the payload layout is six
/// segments deep and the noise otherwise buries what each path is for.
final String _sep = Platform.pathSeparator;

/// A payload holding everything `verifyAgentSdkPayloadFor` asks for.
///
/// A fixture rather than a real bundle, because the point of most of these
/// tests is to remove exactly one piece and see exactly one problem — and a
/// quarter-gigabyte tree of somebody else's files cannot be taken apart that
/// precisely. The real tree answers the one question the fixture cannot (does
/// the checker agree with the *bundler*), in "the installed server runs".
String _fixturePayload({
  required String platform,
  List<String> extraPlatforms = const [],
}) {
  final root = _tempDir('agent_sdk_fixture').path;

  File('$root${_sep}agent_sdk_server.js').writeAsStringSync('// server');
  File('$root${_sep}package.json').writeAsStringSync('{"name":"fixture"}');

  final modules = '$root${_sep}node_modules';
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
  File('$sdk${_sep}sdk.mjs').writeAsStringSync('// the importable half');

  for (final peer in ['$scope${_sep}sdk', '$modules${_sep}zod']) {
    Directory(peer).createSync(recursive: true);
    File('$peer${_sep}package.json').writeAsStringSync('{}');
  }

  for (final name in [platform, ...extraPlatforms]) {
    _writeCli(scope, name);
  }
  return root;
}

void main() {
  group('no Node on this machine — the availability gate, not an error', () {
    test('probe answers false rather than throwing', () async {
      final script = _tempDir('agent_sdk_script');
      File(
        '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
      ).writeAsStringSync('// present, but there is nothing to run it with');

      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(_absentNode),
        serverScript:
            '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
      );
      addTearDown(transport.close);

      // The question "is AI available?" must be answerable on a machine that
      // cannot answer it in the affirmative.
      expect(await transport.probe(), isFalse);
    });

    test('the selector leaves the gate shut and never throws', () async {
      final script = _tempDir('agent_sdk_script');
      File(
        '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
      ).writeAsStringSync('// present');

      final selector = AgentSdkTransportSelector([
        StandaloneNodeAiTransport(
          node: llmNodeAt(_absentNode),
          serverScript:
              '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
        ),
      ]);
      addTearDown(selector.dispose);

      await selector.initialize();

      expect(selector.isAvailable, isFalse);
      expect(selector.active, isNull);
      // The provider is the thing the editor asks, so assert the gate where
      // the editor reads it and not only where the selector holds it.
      expect(
        AgentSdkSessionProvider(
          sessions: testSessions(inProcess: true),
          selector: selector,
          toolServerName: 'tools',
        ).isAvailable,
        isFalse,
      );
    });

    test('the child process is never started', () async {
      final script = _tempDir('agent_sdk_script');
      File(
        '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
      ).writeAsStringSync('// present');

      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(_absentNode),
        serverScript:
            '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
        // A short timeout so a regression that *does* spawn something fails
        // fast rather than hanging the suite for twenty seconds.
        startupTimeout: const Duration(seconds: 2),
      );
      addTearDown(transport.close);

      expect(await transport.probe(), isFalse);
      expect(transport.isConnected, isFalse);
    });

    test('the notice names the remedy, not just the symptom', () async {
      final script = _tempDir('agent_sdk_script');
      File(
        '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
      ).writeAsStringSync('// present');

      final selector = AgentSdkTransportSelector([
        StandaloneNodeAiTransport(
          node: llmNodeAt(_absentNode),
          serverScript:
              '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
        ),
      ]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();

      expect(notices, hasLength(1));
      final reported = notices.single.message;
      // "Not reachable" is true of a missing runtime, a missing script and a
      // stopped editor alike, and is actionable for none of them. Node is the
      // user's to supply, so the message has to say so.
      expect(reported, isNot(contains('not reachable')));
      expect(reported, contains('Node.js'));
      expect(reported, contains('$requiredNodeMajorVersion'));
    });

    test(
      'a missing script is a different sentence from a missing runtime',
      () async {
        // The script ships with the app and the runtime does not, so their
        // absences have different causes and different remedies. Collapsing them
        // into one message would tell a user to install Node when the actual
        // fault is a broken build.
        final transport = StandaloneNodeAiTransport(
          // Absent too, and never reached: the script is checked first.
          node: llmNodeAt(_absentNode),
          serverScript:
              '${_tempDir('agent_sdk_missing').path}'
              '${Platform.pathSeparator}absent.js',
        );
        addTearDown(transport.close);

        expect(await transport.probe(), isFalse);
        expect(transport.unavailableReason, contains('was not found'));
        expect(transport.unavailableReason, contains(standaloneScriptEnvVar));
        expect(transport.unavailableReason, isNot(contains('Node.js')));
        // A transport with no installer is a developer's tool (a shipped app
        // uses `forApp`, whose missing server is `notInstalled`), so the
        // remedies are a developer's.
        expect(transport.unavailableReason, contains('npm ci'));
      },
    );

    test(
      'connect, if called anyway, is a typed unreachable — not a crash',
      () async {
        final script = _tempDir('agent_sdk_script');
        File(
          '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
        ).writeAsStringSync('// present');

        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(_absentNode),
          serverScript:
              '${script.path}${Platform.pathSeparator}agent_sdk_server.js',
        );
        addTearDown(transport.close);

        await expectLater(
          transport.connect(),
          throwsA(
            isA<LlmTransportException>()
                .having((e) => e.kind, 'kind', LlmErrorKind.unreachable)
                .having((e) => e.message, 'message', contains('Node')),
          ),
        );
      },
    );
  });

  group('the packaged layout', () {
    test('resolves the server source beside the app executable', () {
      final exeDir = _tempDir('agent_sdk_app_exe');
      final sep = Platform.pathSeparator;
      final source = Directory('${exeDir.path}$sep$agentSdkServerPayloadDir')
        ..createSync();
      for (final name in agentSdkServerSourceFiles) {
        File('${source.path}$sep$name').writeAsStringSync('// shipped');
      }

      expect(
        resolveAgentSdkServerSourceFor(executableDir: exeDir.path),
        source.path,
      );
    });

    test('the packaged source outranks any source checkout', () {
      // A developer runs the built app from inside the repository often enough
      // that this ordering is load-bearing: the shipped source is the one the
      // build verified, and a working tree above it on disk is not.
      final exeDir = _tempDir('agent_sdk_app_exe');
      final sep = Platform.pathSeparator;
      final candidates = agentSdkServerSourceCandidates(
        executableDir: exeDir.path,
      );
      expect(candidates.first, '${exeDir.path}$sep$agentSdkServerPayloadDir');
    });

    test('the packaged folder is never RUN from: it holds no node_modules', () {
      // The script beside the executable is source for an install. Resolving
      // it as a runnable server would start a script whose `import` of the SDK
      // fails, which is a worse failure than "not installed".
      final exeDir = _tempDir('agent_sdk_app_exe');
      final sep = Platform.pathSeparator;
      Directory('${exeDir.path}$sep$agentSdkServerPayloadDir').createSync();
      final packaged =
          '${exeDir.path}$sep$agentSdkServerPayloadDir'
          '$sep$agentSdkServerScriptName';
      File(packaged).writeAsStringSync('// shipped');

      expect(
        agentSdkServerScriptCandidates(executableDir: exeDir.path),
        isNot(contains(packaged)),
      );
    });

    test('names a concrete location when nothing is found', () {
      // An empty string here would produce "the script was not found at ''",
      // which tells a user nothing about where to look.
      final exeDir = _tempDir('agent_sdk_app_exe');
      expect(
        resolveAgentSdkServerSourceFor(executableDir: exeDir.path),
        contains(agentSdkServerPayloadDir),
      );
    });
  });

  group('the CLI platform', () {
    test('maps the platforms the SDK ships a CLI for', () {
      expect(
        agentSdkPlatformFor(operatingSystem: 'macos', isArm64: true),
        'darwin-arm64',
      );
      expect(
        agentSdkPlatformFor(operatingSystem: 'macos', isArm64: false),
        'darwin-x64',
      );
      expect(
        agentSdkPlatformFor(operatingSystem: 'linux', isArm64: true),
        'linux-arm64',
      );
      expect(
        agentSdkPlatformFor(operatingSystem: 'linux', isArm64: false),
        'linux-x64',
      );
      expect(
        agentSdkPlatformFor(operatingSystem: 'windows', isArm64: true),
        'win32-arm64',
      );
      expect(
        agentSdkPlatformFor(operatingSystem: 'windows', isArm64: false),
        'win32-x64',
      );
    });

    test('an unsupported platform yields null rather than a guess', () {
      // Pruning on a guess would leave a payload with no usable binary at all,
      // which is strictly worse than shipping every platform.
      expect(
        agentSdkPlatformFor(operatingSystem: 'android', isArm64: true),
        isNull,
      );
    });

    test('this host has a platform', () {
      // Every desktop platform a consuming app scaffolds (macOS, Linux, Windows) is
      // one the SDK ships a CLI for; if that stops being true the payload
      // silently stops being pruned, so it is asserted rather than assumed.
      expect(agentSdkHostPlatform, isNotNull);
    });
  });

  group('the release verification', () {
    // , re-aimed by: this is now the POST-INSTALL check.
    // `npm ci` exiting 0 is not proof of a runnable tree — it succeeds with
    // optional dependencies skipped, which for this SDK is a tree with no CLI
    // — so the installer runs this before it calls anything installed.

    test('an install that never ran fails once, naming the '
        'remedy', () {
      final appData = _tempDir('agent_sdk_app_data');

      final result = verifyAgentSdkPayloadFor(
        payloadDir: '${appData.path}${Platform.pathSeparator}ai',
        expectedPlatform: agentSdkHostPlatform,
      );

      expect(result.ok, isFalse);
      expect(
        result.problems,
        hasLength(1),
        reason: 'one fault, reported once — not the same absence six times',
      );
      expect(result.problems.single, contains('not installed'));
      expect(result.problems.single, contains('Install'));
    });

    test('a complete payload verifies', () {
      // The anti-vacuity half. A check nobody has seen pass is a check that
      // might be failing for a reason that has nothing to do with the payload.
      final payload = _fixturePayload(platform: _hostPlatform);

      final result = verifyAgentSdkPayloadFor(
        payloadDir: payload,
        expectedPlatform: _hostPlatform,
      );

      expect(result.problems, isEmpty, reason: result.toString());
      expect(result.ok, isTrue);
      expect(result.cliPlatforms, [_hostPlatform]);
    });

    test('every piece the SDK cannot run without is '
        'checked', () {
      // One removal at a time, from a payload that verifies — so a green here
      // is evidence about *that* piece rather than about the fixture.
      final sep = Platform.pathSeparator;
      final scope = 'node_modules$sep@anthropic-ai';
      final sdk = '$scope${sep}claude-agent-sdk';
      final cli = '$sdk-$_hostPlatform';
      final removals = <String, String>{
        'agent_sdk_server.js': 'the server script',
        'package.json': "the server's manifest",
        '$sdk${sep}sdk.mjs': "the Agent SDK's entry point",
        'node_modules${sep}zod': 'peer "zod"',
        '$scope${sep}sdk': 'peer "@anthropic-ai/sdk"',
        '$cli$sep${_cliName(_hostPlatform)}': 'the Claude Code CLI for',
        cli: 'no Claude Code CLI package',
        sdk: 'Agent SDK is not installed',
      };

      for (final entry in removals.entries) {
        final payload = _fixturePayload(platform: _hostPlatform);
        final victim = '$payload$sep${entry.key}';
        final type = FileSystemEntity.typeSync(victim);
        expect(
          type,
          isNot(FileSystemEntityType.notFound),
          reason:
              'the fixture must contain "${entry.key}" for its removal '
              'to mean anything',
        );
        if (type == FileSystemEntityType.directory) {
          Directory(victim).deleteSync(recursive: true);
        } else {
          File(victim).deleteSync();
        }

        final result = verifyAgentSdkPayloadFor(
          payloadDir: payload,
          expectedPlatform: _hostPlatform,
        );
        expect(result.ok, isFalse, reason: 'removing ${entry.key} was ignored');
        expect(
          result.problems.join(' | '),
          contains(entry.value),
          reason: 'removing ${entry.key} was reported as something else',
        );
      }
    });

    test('a zero-length file is a problem, not a presence '
        '', () {
      // What an interrupted copy leaves behind, and what passes every
      // existence check ever written.
      final payload = _fixturePayload(platform: _hostPlatform);
      File(
        '$payload${Platform.pathSeparator}agent_sdk_server.js',
      ).writeAsStringSync('');

      final result = verifyAgentSdkPayloadFor(
        payloadDir: payload,
        expectedPlatform: _hostPlatform,
      );

      expect(result.ok, isFalse);
      expect(result.problems.join(' | '), contains('empty'));
    });

    test('an unpruned tree fails as loudly as a missing one '
        '', () {
      // Both directions of the same check. Missing this host's CLI means the
      // SDK has nothing to spawn; carrying another platform's means ~225 MB
      // of bytes that cannot execute on the machine they shipped to.
      final unpruned = _fixturePayload(
        platform: _hostPlatform,
        extraPlatforms: [_foreignPlatform],
      );
      final tooMany = verifyAgentSdkPayloadFor(
        payloadDir: unpruned,
        expectedPlatform: _hostPlatform,
      );
      expect(tooMany.ok, isFalse);
      expect(tooMany.problems.join(' | '), contains(_foreignPlatform));

      final wrongOne = _fixturePayload(platform: _foreignPlatform);
      final missing = verifyAgentSdkPayloadFor(
        payloadDir: wrongOne,
        expectedPlatform: _hostPlatform,
      );
      expect(missing.ok, isFalse);
      expect(missing.problems.join(' | '), contains(_hostPlatform));
    });

    test('a host the SDK ships nothing for expects any CLI, but '
        'not none', () {
      // The bundler keeps every platform when it cannot name one to keep, so
      // the expectation follows it. It is not a way to switch the check off.
      final many = _fixturePayload(
        platform: 'linux-x64',
        extraPlatforms: const ['darwin-arm64'],
      );
      expect(
        verifyAgentSdkPayloadFor(payloadDir: many, expectedPlatform: null).ok,
        isTrue,
      );

      final none = _fixturePayload(platform: 'linux-x64');
      Directory(
        '$none${_sep}node_modules$_sep@anthropic-ai'
        '${_sep}claude-agent-sdk-linux-x64',
      ).deleteSync(recursive: true);
      final empty = verifyAgentSdkPayloadFor(
        payloadDir: none,
        expectedPlatform: null,
      );
      expect(empty.ok, isFalse);
      expect(empty.problems.join(' | '), contains('no Claude Code CLI'));
    });

    test('on Linux both libc builds of the host CLI are kept, '
        'and nothing else is', () {
      // The SDK picks between `linux-x64` and `linux-x64-musl` at run time by
      // the host's libc, so pruning one of the two would ship a payload that
      // works on half the Linux machines it reaches.
      final both = _fixturePayload(
        platform: 'linux-x64',
        extraPlatforms: const ['linux-x64-musl'],
      );
      final ok = verifyAgentSdkPayloadFor(
        payloadDir: both,
        expectedPlatform: 'linux-x64',
      );
      expect(ok.problems, isEmpty, reason: ok.toString());
      expect(ok.cliPlatforms, ['linux-x64', 'linux-x64-musl']);

      final other = _fixturePayload(
        platform: 'linux-x64',
        extraPlatforms: const ['linux-arm64-musl'],
      );
      final refused = verifyAgentSdkPayloadFor(
        payloadDir: other,
        expectedPlatform: 'linux-x64',
      );
      expect(refused.ok, isFalse);
      expect(refused.problems.join(' | '), contains('linux-arm64-musl'));
    });

    test('a CLI that lost its mode is caught, which no file '
        'listing would show', () {
      final payload = _fixturePayload(platform: _hostPlatform);
      final cli =
          '$payload${_sep}node_modules$_sep@anthropic-ai'
          '${_sep}claude-agent-sdk-$_hostPlatform'
          '$_sep${_cliName(_hostPlatform)}';
      expect(File(cli).existsSync(), isTrue);
      Process.runSync('chmod', ['-x', cli], runInShell: false);

      final result = verifyAgentSdkPayloadFor(
        payloadDir: payload,
        expectedPlatform: _hostPlatform,
      );

      expect(result.ok, isFalse);
      expect(result.problems.join(' | '), contains('executable'));
    }, skip: Platform.isWindows ? 'mode bits are a POSIX notion' : null);

    test('a real install verifies', () {
      // The other direction: the fixture proves the checker agrees with
      // itself; only a tree `npm ci` actually produced can say the checker
      // agrees with npm.
      final installDir = _installedServerDir();
      if (installDir == null) {
        if (_payloadRequired) {
          fail(
            '$_requirePayloadVar is set, so this test may not skip — '
            'and $_appDataVar names no installed AI server.',
          );
        }
        markTestSkipped(_noInstall);
        return;
      }
      final result = verifyAgentSdkPayloadFor(
        payloadDir: installDir,
        expectedPlatform: agentSdkHostPlatform,
      );
      expect(result.problems, isEmpty, reason: result.toString());
      expect(result.cliPlatforms, contains(agentSdkHostPlatform));
    });
  });

  group('the installed server runs', () {
    final node = findNodeForTests();
    final installDir = _installedServerDir();
    final source = _sourceNodeDir();

    if (node == null || installDir == null || source == null) {
      final missing = node == null
          ? 'no Node >= $requiredNodeMajorVersion is on this machine'
          : installDir == null
          ? _noInstall
          : 'the server source tom_core_agentic/node was not found';

      // Skipping is right for a developer who has not installed the server,
      // and wrong as the permanent state of the only end-to-end proof. This
      // flag is what lets both be true: unset, the group skips; set, a missing
      // prerequisite is a **failure** naming which one. The check lives here
      // rather than in the workflow because this is where the condition is
      // known.
      if (_payloadRequired) {
        test('the install prerequisites are REQUIRED in this '
            'environment', () {
          fail(
            '$_requirePayloadVar is set, so this group may not skip — and '
            '$missing.\n\n'
            'That variable exists for CI, where skipping is the failure: a '
            'regression in server_payload.dart (a file the source list '
            'forgets, a check that rejects a good tree) would otherwise land '
            'green, because the one group that would have caught it never '
            'ran. Install the prerequisites or unset the variable.',
          );
        });
        return;
      }

      test(
        'skipped — needs Node >= 20 and an installed AI '
        'server in $_appDataVar',
        () {},
        skip: missing,
      );
      return;
    }

    test('the server the installer put in app data starts, and its '
        'CLI runs', () async {
      // Resolved the way the packaged app resolves it — through the
      // installer, from the app-data folder — rather than by naming the
      // script: an install in the right place that the transport does not
      // recognise as installed is the failure under test.
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(node),
        installer: AgentSdkServerInstaller(
          sourceDir: source.path,
          installDir: installDir,
        ),
        // Syntactically plausible and certainly invalid. Starting is the
        // assertion; the model's opinion is the live suites' business, and asking
        // for one would make this depend on a credential.
        apiKey: 'sk-ant-invalid-key-for-a-packaging-test',
        startupTimeout: const Duration(seconds: 90),
        onStderr: (line) => printOnFailure('[installed] $line'),
      );
      addTearDown(transport.close);

      expect(
        transport.serverScript,
        '$installDir$_sep$agentSdkServerScriptName',
      );
      expect(
        await transport.probe(),
        isTrue,
        reason: '${transport.unavailableReason}',
      );
      expect(transport.unavailableKind, isNull);

      await transport.connect();
      expect(transport.isConnected, isTrue);

      // `remote` is announced by the native CLI, so only a CLI that actually
      // ran inside this install can produce it.
      await expectLater(
        transport
            .complete(const AgentSdkCompletionRequest(prompt: 'ping'))
            .toList(),
        throwsA(
          isA<LlmTransportException>().having(
            (e) => e.kind,
            'kind',
            LlmErrorKind.remote,
          ),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // ─── ──────────────────────────────────────────────────────────
  group('the Node floor is declared once', () {
    test('`engines.node` in the shipped package.json is the '
        'number `requiredNodeMajorVersion` carries', () {
      // The floor exists in two places by necessity, not by oversight. npm
      // needs it in `engines.node` to refuse an install; the probe needs it as
      // a Dart int to refuse a runtime, and it needs it on a path that must
      // work when the caller has pointed `AGENT_SDK_SERVER_SCRIPT` at a bare
      // script with no `package.json` beside it — so reading the manifest at
      // probe time would have to fall back to a constant anyway, restoring the
      // duplication and hiding it. Duplicate-and-check is also what this
      // workspace already does for version stamps against `pubspec.yaml`.
      //
      // So the number is written twice and this is the thing that keeps the
      // two in step: bump the engine field for a newer SDK and the Dart floor
      // no longer silently stays behind.
      final manifest = File('node/package.json');
      expect(
        manifest.existsSync(),
        isTrue,
        reason:
            'the shipped manifest is the source of this requirement; '
            'without it this test asserts nothing',
      );

      final json = jsonDecode(manifest.readAsStringSync());
      expect(json, isA<Map<String, dynamic>>());
      final engines = (json as Map<String, dynamic>)['engines'];
      expect(
        engines,
        isA<Map<String, dynamic>>(),
        reason:
            'an `engines` block that has been removed would leave the '
            'Dart floor as the only statement of a requirement npm is no '
            'longer enforcing',
      );
      final declared = (engines as Map<String, dynamic>)['node'];
      expect(declared, isA<String>());

      final floor = _minimumMajor(declared as String);
      expect(
        floor,
        isNotNull,
        reason:
            'only a simple `>=N` range is understood here. '
            '`engines.node` is "$declared"; widen `_minimumMajor` '
            'deliberately, and decide what floor the probe should enforce, '
            'rather than letting it approximate one',
      );

      expect(
        floor,
        requiredNodeMajorVersion,
        reason:
            'the shipped server declares Node "$declared" and the probe '
            'enforces $requiredNodeMajorVersion. They are the same '
            'requirement and must be the same number',
      );
    });

    test('the floor is not below what the Agent SDK itself '
        'requires', () {
      // The test above keeps two of OUR statements in step. Both of them are
      // a claim about a third thing — what the Agent SDK needs — and that
      // claim is hand-written. If the SDK raises its floor and ours stays put,
      // the probe accepts a Node the SDK rejects, which is the defect this
      // whole floor exists against, one level up and invisible.
      //
      // Read from `package-lock.json`, which is TRACKED, so this holds in a
      // fresh checkout with no `npm install`. `node_modules` is gitignored; a
      // guard that needed it would skip exactly where nobody has run npm,
      // which is where it would matter.
      final lock = File('node/package-lock.json');
      expect(
        lock.existsSync(),
        isTrue,
        reason:
            'the lockfile is the tracked record of what the SDK '
            'requires; without it this test asserts nothing',
      );

      final packages =
          (jsonDecode(lock.readAsStringSync())
                  as Map<String, dynamic>)['packages']
              as Map<String, dynamic>?;
      expect(packages, isNotNull);
      final sdk =
          packages!['node_modules/@anthropic-ai/claude-agent-sdk']
              as Map<String, dynamic>?;
      expect(
        sdk,
        isNotNull,
        reason:
            'the Agent SDK is the dependency whose runtime requirement '
            'the floor represents; if it has been renamed or removed, this '
            'test must be re-pointed rather than quietly pass',
      );

      final declared = (sdk!['engines'] as Map<String, dynamic>?)?['node'];
      expect(
        declared,
        isA<String>(),
        reason:
            'the SDK stopped declaring `engines.node`, so there is '
            'nothing left to compare against and the floor becomes a bare '
            'assertion — decide what to do rather than skip',
      );

      final sdkFloor = _minimumMajor(declared as String);
      expect(
        sdkFloor,
        isNotNull,
        reason:
            'the SDK declares Node "$declared", which `_minimumMajor` '
            'does not read; widen it deliberately',
      );

      // DIRECTIONAL, not equal. Stricter than the SDK is a deliberate and
      // safe position — it refuses some runtimes that would have worked, and
      // the cost is an upgrade the user can perform. Looser is the dangerous
      // direction: it admits a runtime the SDK will reject inside a child the
      // user cannot see. Today ours is 20 and the SDK's is 18, and this
      // asserts only that the gap never inverts.
      expect(
        requiredNodeMajorVersion,
        greaterThanOrEqualTo(sdkFloor!),
        reason:
            'the probe enforces Node $requiredNodeMajorVersion while '
            'the Agent SDK requires "$declared". A floor BELOW the SDK\'s '
            'admits a runtime the SDK rejects, and the failure resurfaces '
            'as the unreadable child error the floor was introduced to '
            'replace',
      );
    });
  });
}

/// The major version a simple `>=N[.M[.P]]` range admits, or null for any range
/// this deliberately refuses to interpret.
///
/// Narrow on purpose. A compound range (`^20 || ^22`, `>=20 <23`) has no single
/// floor a probe can enforce without someone choosing one, so it returns null
/// and the caller fails loudly instead of being handed a confident guess.
int? _minimumMajor(String range) {
  final match = RegExp(r'^>=\s*(\d+)(?:\.\d+)*$').firstMatch(range.trim());
  return match == null ? null : int.parse(match.group(1)!);
}

/// What a packaged app carries of the standalone AI server, and the installer
/// that turns it into a runnable server on the user's machine.
///
/// **What ships, and what does not.** The standalone transport runs a Node
/// script that imports Anthropic's Claude Agent SDK. The script is ours and is
/// BSD-3-Clause; the SDK is **proprietary**, licensed under Anthropic's
/// terms, and it is not ours to redistribute inside an application. So a
/// packaged app carries exactly three files of the server — the script, its
/// `package.json` and its `package-lock.json` — in `<app-executable-dir>/ai/`,
/// and no `node_modules` at all. The SDK and its dependencies are installed
/// **by the user, on their machine, under Anthropic's terms**, when they press
/// Install in the availability notice: [AgentSdkServerInstaller] runs
/// `npm ci --omit=dev` from the shipped lockfile into the app's own data
/// folder, then checks what npm produced.
///
/// **Why an installer rather than instructions.** The tree npm builds is
/// specific to the Node that runs it: since 0.3 the SDK runs the Claude Code
/// CLI as a **native binary**, shipped in a per-platform package
/// (`@anthropic-ai/claude-agent-sdk-darwin-arm64` and seven siblings) that npm
/// selects by the installing Node's `process.platform` and `process.arch` — the
/// same two values the SDK resolves the binary by at run time. An install run
/// by the app with the Node the app will use is the one arrangement in which
/// those two choices cannot disagree.
///
/// **What it deliberately does not do.** It does not fetch or provide a Node
/// runtime: Node is a prerequisite the user supplies, checked by the
/// same floor probe the transport uses, and without one the gate stays shut
/// with a sentence naming it. It never installs on its own initiative: the
/// download is third-party software under third-party terms, so only an
/// explicit user action starts it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
// For `agentSdkServerScriptName` and the Node floor. The producer, the
// verifier and the consumer must name the same file, and one declaration is
// how that stops being a thing anyone has to remember.

import 'package:tom_llm/tom_llm.dart';

import 'transport/transport.dart';
import 'transport/standalone_transport.dart';

/// Where a user is sent to read what Install does and why it is needed.
///
/// A section of this package's README, so the explanation is versioned with
/// the code that does what it describes.
const agentSdkInstallExplanationUrl =
    'https://github.com/al-the-bear/tom_ai_core/blob/main/'
    'tom_core_agentic/README.md#installing-the-server';

/// The lockfile the shipped source carries and `npm ci` installs from.
const agentSdkServerLockfileName = 'package-lock.json';

/// The three files a packaged app carries of the AI server, and the only ones.
const agentSdkServerSourceFiles = [
  agentSdkServerScriptName,
  'package.json',
  agentSdkServerLockfileName,
];

/// The file an install writes last, after its tree passed the post-install
/// check. Its presence is what "installed" means: a tree without it is one an
/// interrupted install left behind.
const agentSdkInstallMarkerName = '.agent_sdk_install.json';

/// The npm scope holding the SDK and its per-platform CLI packages.
const _sdkScope = '@anthropic-ai';

/// The SDK's package name within [_sdkScope]; a platform package is this plus
/// `-<platform>`.
const _sdkName = 'claude-agent-sdk';

/// The Agent SDK's name for a host's platform package suffix — `darwin-arm64`,
/// `linux-x64`, `win32-x64` — or null for a host it ships no CLI for.
///
/// The names are the SDK's (Node's `process.platform`-`process.arch`), not
/// Dart's, so this is a translation rather than a formatting. It answers for
/// the **Dart** process; the installer asks the Node it will run instead (see
/// [chooseAgentSdkPlatform]), because on Windows on ARM an x64 Flutter
/// build under emulation and an arm64 Node are an ordinary combination.
String? agentSdkPlatformFor({
  required String operatingSystem,
  required bool isArm64,
}) {
  final arch = isArm64 ? 'arm64' : 'x64';
  return switch (operatingSystem) {
    'macos' => 'darwin-$arch',
    'linux' => 'linux-$arch',
    'windows' => 'win32-$arch',
    _ => null,
  };
}

/// The platform suffix for the machine this Dart process is running on.
///
/// A test seam: the installer verifies against the platform of the Node it
/// installs with, which is not necessarily this process's, so only the
/// suites — checking a payload on the machine that built it — ask this.
@visibleForTesting
String? get agentSdkHostPlatform => agentSdkPlatformFor(
  operatingSystem: Platform.operatingSystem,
  isArm64: Platform.version.contains('arm64'),
);

/// The platform package names [platform] accepts: itself, and on Linux its
/// `-musl` twin, which the SDK chooses between at run time by the host's libc.
Set<String> _keptPlatformPackages(String platform) => {
  '$_sdkName-$platform',
  if (platform.startsWith('linux-')) '$_sdkName-$platform-musl',
};

/// Whether [name], a directory under [_sdkScope], is a platform CLI package.
bool _isPlatformPackage(String name) => name.startsWith('$_sdkName-');

/// Which Claude Code CLI an install will get, or why it can get none.
final class AgentSdkPlatformChoice {
  /// The SDK platform suffix npm will install (`darwin-arm64`, …), or null
  /// when [refusal] is set.
  final String? platform;

  /// Why no CLI can be installed for this Node, naming the remedy; null when
  /// [platform] is set.
  final String? refusal;

  const AgentSdkPlatformChoice._(this.platform, this.refusal);

  /// Whether a CLI was chosen.
  bool get ok => platform != null;

  @override
  String toString() => ok
      ? 'AgentSdkPlatformChoice($platform)'
      : 'AgentSdkPlatformChoice(refused: $refusal)';
}

/// Decides which Claude Code CLI package an install for a Node reporting
/// [nodePlatform] / [nodeArch] (`process.platform`, `process.arch`) gets, from
/// the set of platform suffixes the locked SDK version ships ([shipped]).
///
/// **Never "nothing".** npm installs the platform package whose `os`/`cpu`
/// match the installing Node and silently skips every other optional
/// dependency — so a Node the SDK ships no CLI for produces a tree that
/// installs cleanly and cannot answer a single prompt. This is the check that
/// turns that into a sentence before anything is downloaded.
///
/// **Windows on ARM refuses rather than falling back to the x64 CLI.** The
/// fallback looks free — Windows on ARM runs x64 binaries under emulation — and
/// is not: the SDK resolves the CLI at run time by the running Node's
/// `process.arch`, so an x64 CLI installed beside an arm64 Node is never
/// found. The fallback that *does* work is an x64 **Node**, for which npm
/// installs, and the SDK resolves, the x64 CLI; that is the remedy the refusal
/// names. (SDK 0.3.286 ships `win32-arm64`, so today this branch is reached
/// only by a lockfile that pins an SDK without it.)
AgentSdkPlatformChoice chooseAgentSdkPlatform({
  required String nodePlatform,
  required String nodeArch,
  required Set<String> shipped,
  String? sdkVersion,
}) {
  final sdk = sdkVersion == null
      ? "Anthropic's Claude Agent SDK"
      : "Anthropic's Claude Agent SDK $sdkVersion";
  if (!const {'darwin', 'linux', 'win32'}.contains(nodePlatform) ||
      !const {'arm64', 'x64'}.contains(nodeArch)) {
    return AgentSdkPlatformChoice._(
      null,
      '$sdk ships no Claude Code CLI for $nodePlatform-$nodeArch, so the AI '
      'server cannot run with this Node.js. Use a 64-bit Node.js on macOS, '
      'Linux or Windows',
    );
  }
  final suffix = '$nodePlatform-$nodeArch';
  final accepted = {suffix, if (nodePlatform == 'linux') '$suffix-musl'};
  if (shipped.any(accepted.contains)) {
    return AgentSdkPlatformChoice._(suffix, null);
  }
  if (suffix == 'win32-arm64' && shipped.contains('win32-x64')) {
    return AgentSdkPlatformChoice._(
      null,
      '$sdk ships no Claude Code CLI for Windows on ARM (win32-arm64). '
      'Install the x64 build of Node.js 20 or newer and point the app at it: '
      'Windows on ARM runs it under emulation, npm then installs the x64 CLI, '
      'and the SDK finds it — an x64 CLI beside an arm64 Node is never found',
    );
  }
  return AgentSdkPlatformChoice._(
    null,
    '$sdk ships no Claude Code CLI for $suffix (it ships '
    '${(shipped.toList()..sort()).join(', ')}), so the AI server cannot run '
    'with this Node.js',
  );
}

/// The locked SDK version and the platform suffixes it ships a CLI for, read
/// from a `package-lock.json`'s text. Null when the lockfile does not lock the
/// SDK.
({String? version, Set<String> platforms})? agentSdkInLockfile(
  String lockfile,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(lockfile);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final packages = decoded['packages'];
  if (packages is! Map) return null;
  final sdk = packages['node_modules/$_sdkScope/$_sdkName'];
  if (sdk is! Map) return null;
  final optional = sdk['optionalDependencies'];
  final platforms = <String>{
    if (optional is Map)
      for (final name in optional.keys.cast<String>())
        if (name.startsWith('$_sdkScope/$_sdkName-'))
          name.substring('$_sdkScope/$_sdkName-'.length),
  };
  final version = sdk['version'];
  return (version: version is String ? version : null, platforms: platforms);
}

// ─── The build side: what package_app.dart puts in the app ─────────────────

/// What a staging run did, so a build log says something a human can check.
final class AgentSdkStagingReport {
  /// Where the source files were written.
  final String destination;

  /// The files written, by name.
  final List<String> files;

  /// Bytes written.
  final int byteCount;

  const AgentSdkStagingReport({
    required this.destination,
    required this.files,
    required this.byteCount,
  });

  @override
  String toString() =>
      'AgentSdkStagingReport($destination: ${files.join(", ")}, '
      '${(byteCount / 1024).toStringAsFixed(1)} KiB)';
}

/// Thrown when the build cannot stage the server's source. A build failure,
/// never a runtime one: at run time a missing server is the availability gate.
final class AgentSdkStagingException implements Exception {
  final String message;
  const AgentSdkStagingException(this.message);
  @override
  String toString() => 'AgentSdkStagingException: $message';
}

/// Copies the server's three source files from [nodeSourceDir] into
/// [destination] — the `ai/` folder beside the built executable.
///
/// [destination] is **replaced**, not merged: a `node_modules` left in it by a
/// build from before the SDK stopped shipping would otherwise go out with the
/// release, which is exactly the redistribution this layout exists to avoid.
/// No `node_modules` is ever copied, whatever [nodeSourceDir] holds — a
/// developer's checkout usually has one.
AgentSdkStagingReport stageAgentSdkServer({
  required String nodeSourceDir,
  required String destination,
}) {
  final sep = Platform.pathSeparator;
  if (!Directory(nodeSourceDir).existsSync()) {
    throw AgentSdkStagingException(
      'The AI server source folder "$nodeSourceDir" does not exist.',
    );
  }
  for (final name in agentSdkServerSourceFiles) {
    if (!File('$nodeSourceDir$sep$name').existsSync()) {
      throw AgentSdkStagingException('Missing "$name" in "$nodeSourceDir".');
    }
  }
  final target = Directory(destination);
  if (target.existsSync()) target.deleteSync(recursive: true);
  target.createSync(recursive: true);
  var bytes = 0;
  for (final name in agentSdkServerSourceFiles) {
    bytes += File(
      '$nodeSourceDir$sep$name',
    ).copySync('$destination$sep$name').lengthSync();
  }
  return AgentSdkStagingReport(
    destination: destination,
    files: List.unmodifiable(agentSdkServerSourceFiles),
    byteCount: bytes,
  );
}

/// What [verifyAgentSdkServerSource] found: everything wrong with the AI
/// server source a build carries. Empty [problems] means shippable.
final class AgentSdkSourceVerification {
  /// The directory that was checked.
  final String sourceDir;

  /// Everything wrong with it, in the order checked.
  final List<String> problems;

  const AgentSdkSourceVerification({
    required this.sourceDir,
    required this.problems,
  });

  /// Whether the build's AI server source is shippable.
  bool get ok => problems.isEmpty;

  @override
  String toString() => ok
      ? 'AgentSdkSourceVerification($sourceDir: ok, '
            '${agentSdkServerSourceFiles.join(", ")}; no node_modules)'
      : 'AgentSdkSourceVerification($sourceDir: ${problems.length} '
            'problem${problems.length == 1 ? '' : 's'})\n'
            '${problems.map((p) => '  • $p').join('\n')}';
}

/// The release gate: checks that [sourceDir] — a build's `ai/` folder —
/// carries exactly what a release may ship of the AI server.
///
/// Two directions, both of which matter. **Missing**: a plain `flutter build`
/// produces an app with no `ai/` folder, whose Install button then has nothing
/// to install from; that is invisible at run time, so the build is the only
/// place it can be caught. **Too much**: a `node_modules`, or anything of the
/// Agent SDK, in the folder means the release redistributes proprietary
/// software inside the application — the one thing this layout exists to
/// prevent, and a mistake no user would ever report.
AgentSdkSourceVerification verifyAgentSdkServerSource({
  required String sourceDir,
}) {
  final sep = Platform.pathSeparator;
  final problems = <String>[];
  AgentSdkSourceVerification result() => AgentSdkSourceVerification(
    sourceDir: sourceDir,
    problems: List.unmodifiable(problems),
  );

  if (!Directory(sourceDir).existsSync()) {
    problems.add(
      'no AI server source at "$sourceDir" — this build never ran '
      'tool/package_app.dart, so its Install button has nothing to install '
      'from',
    );
    return result();
  }
  for (final name in agentSdkServerSourceFiles) {
    final file = File('$sourceDir$sep$name');
    if (!file.existsSync()) {
      problems.add('"$name" is missing: "${file.path}"');
    } else if (file.lengthSync() == 0) {
      problems.add('"$name" is empty: "${file.path}"');
    }
  }
  final lock = File('$sourceDir$sep$agentSdkServerLockfileName');
  if (lock.existsSync() && lock.lengthSync() > 0) {
    final sdk = agentSdkInLockfile(lock.readAsStringSync());
    if (sdk == null) {
      problems.add(
        'the lockfile does not lock $_sdkScope/$_sdkName — `npm ci` would '
        'install a server with no Agent SDK',
      );
    } else if (sdk.platforms.isEmpty) {
      problems.add(
        'the locked Agent SDK declares no platform CLI packages — an install '
        'would have nothing to spawn',
      );
    }
  }
  if (Directory('$sourceDir${sep}node_modules').existsSync()) {
    problems.add(
      'the build carries "node_modules" in "$sourceDir" — the Agent SDK is '
      "installed by the user under Anthropic's terms and must not ship",
    );
  }
  // Anything of the SDK anywhere in the folder, however it got there.
  for (final entity in Directory(
    sourceDir,
  ).listSync(recursive: true, followLinks: false)) {
    final name = entity.path.split(sep).last;
    if (name == _sdkScope || name.startsWith(_sdkName)) {
      problems.add('the build carries part of the Agent SDK: "${entity.path}"');
      break;
    }
  }
  return result();
}

// ─── The user's side: the post-install check ───────────────────────────────

/// What [verifyAgentSdkPayloadFor] found.
///
/// A list of problems rather than a throw on the first one: a check that
/// reports one fault per run makes fixing three faults three installs.
final class AgentSdkPayloadVerification {
  /// The directory that was checked.
  final String payloadDir;

  /// Everything wrong with it, in the order checked. Empty means runnable.
  final List<String> problems;

  /// The platform CLI packages actually present, by suffix, sorted.
  final List<String> cliPlatforms;

  /// The platform the install was expected to carry, or null for "any one".
  final String? expectedPlatform;

  const AgentSdkPayloadVerification({
    required this.payloadDir,
    required this.problems,
    required this.cliPlatforms,
    required this.expectedPlatform,
  });

  /// Whether the installed server can run.
  bool get ok => problems.isEmpty;

  @override
  String toString() => ok
      ? 'AgentSdkPayloadVerification($payloadDir: ok, '
            'CLI ${cliPlatforms.join(", ")})'
      : 'AgentSdkPayloadVerification($payloadDir: ${problems.length} '
            'problem${problems.length == 1 ? '' : 's'})\n'
            '${problems.map((p) => '  • $p').join('\n')}';
}

/// The **post-install check**: whether [payloadDir] — an installed AI server —
/// holds a tree the transport can actually run.
///
/// `npm ci` exiting 0 is not that proof. It succeeds with optional
/// dependencies skipped, which for this SDK means a tree with no CLI to spawn;
/// it succeeds for a Node whose platform the SDK ships nothing for; and an
/// install interrupted between npm and the marker leaves a tree that looks
/// complete. So the installer runs this before it calls anything installed.
///
/// What the SDK needs is read from the SDK's own manifest where it says so —
/// its entry point from `main`, its peers from `peerDependencies` — so an SDK
/// release that renames its entry or adds a peer is checked for what it now
/// requires rather than for what an earlier one did.
///
/// The installer states the installing Node's platform, which is the one the
/// SDK will look for; a caller checking for this Dart host passes
/// [agentSdkHostPlatform].
///
/// [expectedPlatform] null means "any one CLI" — not a way to switch the check
/// off: a tree with no CLI at all is a problem either way.
AgentSdkPayloadVerification verifyAgentSdkPayloadFor({
  required String payloadDir,
  required String? expectedPlatform,
}) {
  final sep = Platform.pathSeparator;
  final problems = <String>[];
  final platforms = <String>[];

  AgentSdkPayloadVerification result() => AgentSdkPayloadVerification(
    payloadDir: payloadDir,
    problems: List.unmodifiable(problems),
    cliPlatforms: List.unmodifiable(platforms..sort()),
    expectedPlatform: expectedPlatform,
  );

  if (!Directory(payloadDir).existsSync()) {
    // Everything below would report the same fact five more times.
    problems.add(
      'the AI server is not installed at "$payloadDir" — press Install in '
      'the AI notice, or run `dart run tom_core_agentic:install_agent_sdk_server`',
    );
    return result();
  }

  void requireFile(String path, String what) {
    final file = File(path);
    if (!file.existsSync()) {
      problems.add('$what is missing: "$path"');
    } else if (file.lengthSync() == 0) {
      // A zero-length file is what an interrupted copy leaves behind, and it
      // passes every existence check ever written.
      problems.add('$what is empty: "$path"');
    }
  }

  requireFile('$payloadDir$sep$agentSdkServerScriptName', 'the server script');
  requireFile('$payloadDir${sep}package.json', "the server's manifest");

  final modules = '$payloadDir${sep}node_modules';
  final scope = '$modules$sep$_sdkScope';
  final sdkDir = '$scope$sep$_sdkName';
  final manifest = File('$sdkDir${sep}package.json');
  if (!manifest.existsSync()) {
    problems.add(
      'the Agent SDK is not installed: "$sdkDir" — `npm ci` did not run '
      'here, or the SDK package was renamed upstream',
    );
    return result();
  }

  Map<String, Object?> sdk;
  try {
    sdk = jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
  } on FormatException catch (e) {
    problems.add('the Agent SDK\'s manifest is unreadable: ${e.message}');
    return result();
  }

  // The importable half: what the server's `import` resolves to.
  final main = sdk['main'];
  if (main is! String || main.isEmpty) {
    problems.add('the Agent SDK\'s manifest names no entry point (`main`)');
  } else {
    requireFile(
      '$sdkDir$sep${main.replaceAll('/', sep)}',
      "the Agent SDK's entry point",
    );
  }

  // npm installs peers since v7, so a missing one is a tree installed by a
  // tool that does not — and the SDK fails at import, not at install.
  final peers = sdk['peerDependencies'];
  if (peers is Map) {
    for (final peer in peers.keys.cast<String>()) {
      final dir = '$modules$sep${peer.replaceAll('/', sep)}';
      if (!File('$dir${sep}package.json').existsSync()) {
        problems.add('the Agent SDK\'s peer "$peer" is missing: "$dir"');
      }
    }
  }

  platforms.addAll(
    Directory(scope)
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split(sep).last)
        .where(_isPlatformPackage)
        .map((name) => name.substring(_sdkName.length + 1)),
  );

  if (platforms.isEmpty) {
    problems.add(
      'no Claude Code CLI package under "$scope" — the SDK has nothing to '
      'spawn; the tree was installed with optional dependencies omitted',
    );
    return result();
  }
  if (expectedPlatform != null) {
    final allowed = {
      for (final name in _keptPlatformPackages(expectedPlatform))
        name.substring(_sdkName.length + 1),
    };
    final foreign = platforms.where((p) => !allowed.contains(p)).toList();
    if (!platforms.any(allowed.contains)) {
      problems.add(
        'the install carries no CLI for "$expectedPlatform", only '
        '"${(platforms..sort()).join('", "')}"',
      );
    } else if (foreign.isNotEmpty) {
      // npm installs only the installing Node's own package; another one here
      // means the tree did not come from this install.
      problems.add(
        'the install should carry only the "$expectedPlatform" CLI and also '
        'carries "${(foreign..sort()).join('", "')}"',
      );
    }
  }

  for (final platform in platforms) {
    final dir = '$scope$sep$_sdkName-$platform';
    final binary = File(
      '$dir$sep${platform.startsWith('win32-') ? 'claude.exe' : 'claude'}',
    );
    requireFile(binary.path, 'the Claude Code CLI for $platform');
    // The bit, not the file: a native binary without `+x` fails at a depth no
    // directory listing reveals.
    if (!Platform.isWindows &&
        binary.existsSync() &&
        binary.statSync().mode & 0x49 == 0) {
      problems.add(
        'the Claude Code CLI for $platform is not executable: '
        '"${binary.path}"',
      );
    }
  }

  return result();
}

// ─── The installer ─────────────────────────────────────────────────────────

/// Runs one command and reports its output line by line; returns its exit
/// code. Throws [ProcessException] when the command cannot be started.
///
/// The seam the installer's suite replaces: `npm ci` needs a network and a
/// registry, and a test that needs those tests them.
typedef AgentSdkCommandRunner =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required Map<String, String> environment,
      required void Function(String line) onOutput,
    });

/// The production [AgentSdkCommandRunner]: [Process.start], no shell.
///
/// No shell, so no argument is ever a shell word — except for a Windows
/// `npm.cmd` fallback, which `CreateProcess` cannot start without one. That
/// fallback is reached only when the npm that ships with Node could not be
/// found beside it, and its arguments are constants.
Future<int> runAgentSdkCommand(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
  required void Function(String line) onOutput,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: true,
    runInShell: Platform.isWindows && executable.toLowerCase().endsWith('.cmd'),
  );
  // stdin is never written; closing it keeps npm from waiting on a prompt.
  unawaited(process.stdin.close());
  Future<void> drain(Stream<List<int>> stream) => stream
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach(onOutput);
  await Future.wait([drain(process.stdout), drain(process.stderr)]);
  return process.exitCode;
}

/// What the installing Node said about itself.
final class AgentSdkNodeRuntime {
  /// `process.versions.node`, e.g. `22.22.3`.
  final String version;

  /// The major version, or null when [version] is not that shape.
  final int? major;

  /// `process.platform` (`darwin`, `linux`, `win32`).
  final String platform;

  /// `process.arch` (`arm64`, `x64`).
  final String arch;

  /// `process.execPath`: the interpreter's absolute path.
  final String execPath;

  const AgentSdkNodeRuntime({
    required this.version,
    required this.major,
    required this.platform,
    required this.arch,
    required this.execPath,
  });
}

/// The installer's state as of the last look at the disk.
enum AgentSdkServerInstallState {
  /// Nothing installed, or an install that never finished.
  notInstalled,

  /// Installed, but from a different lockfile than this app carries — an app
  /// update moved the SDK, and the old tree is not what this server expects.
  outdated,

  /// Installed from this app's lockfile, and checked.
  installed,
}

/// Installs the AI server's dependencies into the app's data folder, on the
/// user's request.
///
/// [sourceDir] holds the three shipped files ([agentSdkServerSourceFiles]);
/// [installDir] is `<app-data>/ai`, where the runnable server ends up. The
/// install is built in a sibling directory and moved into place only after it
/// passed [verifyAgentSdkPayloadFor], so an interrupted or failed install
/// leaves the previous state — installed or not — exactly as it was.
final class AgentSdkServerInstaller {
  /// The shipped server source: the packaged app's `ai/` folder, or a source
  /// checkout's `tom_core_agentic/node`.
  final String sourceDir;

  /// Where the server is installed: `<app-data>/ai`.
  final String installDir;

  /// The npm command, as executable plus leading arguments, or null to use the
  /// npm that ships with the Node the install is given (falling back to `npm`
  /// on `PATH`).
  final List<String>? _npmCommand;

  final AgentSdkCommandRunner _run;

  /// The Node the install runs with is not a property of the installer but
  /// of each [install]: it is the transport's resolution — the one the server
  /// will run on, so npm picks the CLI the SDK will look for — and the
  /// transport makes it on its first probe, after this installer exists.
  AgentSdkServerInstaller({
    required this.sourceDir,
    required this.installDir,
    List<String>? npmCommand,
    AgentSdkCommandRunner? runCommand,
  }) : _npmCommand = npmCommand,
       _run = runCommand ?? runAgentSdkCommand;

  /// The `<app-data>/ai` directory for an app data directory.
  static String installDirFor(String appDataDirectory) =>
      '$appDataDirectory${Platform.pathSeparator}$agentSdkServerPayloadDir';

  /// The server script the transport runs once installed.
  String get serverScript =>
      '$installDir${Platform.pathSeparator}$agentSdkServerScriptName';

  /// Whether the server is installed and current. A handful of stats and one
  /// lockfile comparison; called from a probe, never from the availability gate.
  AgentSdkServerInstallState get state {
    final sep = Platform.pathSeparator;
    if (!File('$installDir$sep$agentSdkInstallMarkerName').existsSync() ||
        !File(serverScript).existsSync()) {
      return AgentSdkServerInstallState.notInstalled;
    }
    final shipped = File('$sourceDir$sep$agentSdkServerLockfileName');
    final installed = File('$installDir$sep$agentSdkServerLockfileName');
    if (shipped.existsSync()) {
      if (!installed.existsSync() ||
          shipped.readAsStringSync() != installed.readAsStringSync()) {
        return AgentSdkServerInstallState.outdated;
      }
    }
    return AgentSdkServerInstallState.installed;
  }

  /// Asks the Node [node] resolved for its version, platform, architecture
  /// and path.
  ///
  /// Returns the runtime, or the sentence the transport's probe would give for
  /// the same resolution — nothing found, not runnable, or below the floor —
  /// so the notice says the same thing whichever of the two looked first.
  Future<(AgentSdkNodeRuntime?, String?)> _probeNode(
    LlmNodeResolution node,
  ) async {
    final nodeExecutable = node.executable;
    if (nodeExecutable == null) return (null, agentSdkNodeMissingReason(node));
    final lines = <String>[];
    final int code;
    try {
      code = await _run(
        nodeExecutable,
        const [
          '-p',
          "[process.versions.node, process.platform, process.arch, "
              "process.execPath].join('\\n')",
        ],
        workingDirectory: Directory.systemTemp.path,
        environment: const {},
        onOutput: lines.add,
      );
    } on ProcessException {
      return (null, agentSdkNodeNotRunnableReason(nodeExecutable));
    }
    final answer = lines.where((l) => l.trim().isNotEmpty).toList();
    if (code != 0 || answer.length < 4) {
      return (null, agentSdkNodeNotRunnableReason(nodeExecutable));
    }
    final version = answer[0].trim();
    final major = int.tryParse(version.split('.').first);
    if (major != null && major < requiredNodeMajorVersion) {
      return (null, agentSdkNodeTooOldReason(nodeExecutable, major));
    }
    return (
      AgentSdkNodeRuntime(
        version: version,
        major: major,
        platform: answer[1].trim(),
        arch: answer[2].trim(),
        execPath: answer[3].trim(),
      ),
      null,
    );
  }

  /// The npm to run: [_npmCommand], else the `npm-cli.js` that ships with the
  /// probed Node run by that Node, else `npm` on `PATH`.
  ///
  /// Through the Node rather than through `npm` on `PATH`, because a desktop
  /// app started from a launcher inherits a `PATH` that rarely holds the
  /// user's Node at all — and an `npm` found there may belong to a different
  /// Node than the one the transport runs, which would install the wrong CLI.
  (String, List<String>) _npm(AgentSdkNodeRuntime node) {
    final explicit = _npmCommand;
    if (explicit != null && explicit.isNotEmpty) {
      return (explicit.first, explicit.sublist(1));
    }
    final sep = Platform.pathSeparator;
    final bin = File(node.execPath).parent;
    for (final candidate in [
      // Windows: <dir>\node.exe beside <dir>\node_modules\npm.
      '${bin.path}${sep}node_modules${sep}npm${sep}bin${sep}npm-cli.js',
      // POSIX: <prefix>/bin/node beside <prefix>/lib/node_modules/npm.
      '${bin.parent.path}${sep}lib${sep}node_modules${sep}npm${sep}bin'
          '${sep}npm-cli.js',
    ]) {
      if (File(candidate).existsSync()) return (node.execPath, [candidate]);
    }
    return (Platform.isWindows ? 'npm.cmd' : 'npm', const []);
  }

  /// Installs the server on the Node [node] resolved. Never throws; every
  /// failure is an outcome with a sentence for the user, and every one leaves
  /// the previous install alone.
  ///
  /// [onProgress] receives a line per step and every line npm writes, so the
  /// notice can show that a download of a quarter of a gigabyte is moving.
  Future<AgentSdkServerInstallResult> install({
    required LlmNodeResolution node,
    void Function(String line)? onProgress,
  }) async {
    void say(String line) => onProgress?.call(line);
    final sep = Platform.pathSeparator;

    final missing = agentSdkServerSourceFiles
        .where((name) => !File('$sourceDir$sep$name').existsSync())
        .toList();
    if (missing.isNotEmpty) {
      return AgentSdkServerInstallResult.failed(
        'this copy of the app carries no AI server to install: '
        '${missing.join(", ")} missing in "$sourceDir" (a release is '
        'produced with tool/package_app.dart)',
      );
    }

    say('Checking Node.js (${node.executable ?? 'none found'})…');
    final (runtime, nodeProblem) = await _probeNode(node);
    if (runtime == null) {
      return AgentSdkServerInstallResult.failed(nodeProblem!);
    }

    final lock = agentSdkInLockfile(
      File('$sourceDir$sep$agentSdkServerLockfileName').readAsStringSync(),
    );
    if (lock == null) {
      return AgentSdkServerInstallResult.failed(
        'the shipped package-lock.json does not lock the Agent SDK, so there '
        'is nothing to install',
      );
    }
    final choice = chooseAgentSdkPlatform(
      nodePlatform: runtime.platform,
      nodeArch: runtime.arch,
      shipped: lock.platforms,
      sdkVersion: lock.version,
    );
    if (!choice.ok) {
      return AgentSdkServerInstallResult.failed(choice.refusal!);
    }
    say(
      'Node.js ${runtime.version} (${choice.platform}); installing Anthropic\'s '
      'Claude Agent SDK ${lock.version ?? ''} into "$installDir"…',
    );

    final staging = Directory('$installDir.installing');
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);
      for (final name in agentSdkServerSourceFiles) {
        File('$sourceDir$sep$name').copySync('${staging.path}$sep$name');
      }
    } on FileSystemException catch (e) {
      return AgentSdkServerInstallResult.failed(
        'could not prepare "${staging.path}": ${e.message}',
      );
    }

    void discard() {
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort; the next install replaces it anyway.
      }
    }

    final (npm, npmLeading) = _npm(runtime);
    final nodeDir = File(runtime.execPath).parent.path;
    final inherited = Platform.environment['PATH'] ?? '';
    final pathSeparator = Platform.isWindows ? ';' : ':';
    final tail = <String>[];
    say('npm ci --omit=dev');
    final int code;
    try {
      code = await _run(
        npm,
        [...npmLeading, 'ci', '--omit=dev', '--no-audit', '--no-fund'],
        workingDirectory: staging.path,
        // The probed Node first on PATH: npm and the SDK's install scripts
        // spawn `node` by name, and it has to be this one.
        environment: {
          'PATH': inherited.isEmpty
              ? nodeDir
              : '$nodeDir$pathSeparator$inherited',
        },
        onOutput: (line) {
          tail.add(line);
          if (tail.length > 5) tail.removeAt(0);
          say(line);
        },
      );
    } on ProcessException catch (e) {
      discard();
      return AgentSdkServerInstallResult.failed(
        'could not run npm ("$npm"): ${e.message}. npm ships with Node.js; '
        'reinstall Node.js $requiredNodeMajorVersion or newer',
      );
    }
    if (code != 0) {
      discard();
      return AgentSdkServerInstallResult.failed(
        'npm ci failed with exit code $code'
        '${tail.isEmpty ? '' : ': ${tail.join(' | ')}'}',
      );
    }

    say('Checking the installed server…');
    final verification = verifyAgentSdkPayloadFor(
      payloadDir: staging.path,
      expectedPlatform: choice.platform,
    );
    if (!verification.ok) {
      discard();
      return AgentSdkServerInstallResult.failed(
        'the installed server failed its check:\n$verification',
        verification: verification,
      );
    }

    try {
      File('${staging.path}$sep$agentSdkInstallMarkerName').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'sdkVersion': lock.version,
          'platform': choice.platform,
          'node': runtime.version,
          'installedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      final target = Directory(installDir);
      if (target.existsSync()) {
        final previous = Directory('$installDir.previous');
        if (previous.existsSync()) previous.deleteSync(recursive: true);
        target.renameSync(previous.path);
        staging.renameSync(installDir);
        previous.deleteSync(recursive: true);
      } else {
        target.parent.createSync(recursive: true);
        staging.renameSync(installDir);
      }
    } on FileSystemException catch (e) {
      discard();
      return AgentSdkServerInstallResult.failed(
        'could not move the installed server into "$installDir": '
        '${e.message}',
      );
    }
    say('Installed (${choice.platform}).');
    return AgentSdkServerInstallResult._(
      ok: true,
      failure: null,
      platform: choice.platform,
      sdkVersion: lock.version,
      verification: verification,
    );
  }
}

/// What [AgentSdkServerInstaller.install] ended with.
final class AgentSdkServerInstallResult {
  /// Whether the server is installed and passed its post-install check.
  final bool ok;

  /// Why not, for the user; null when [ok].
  final String? failure;

  /// The CLI platform installed, e.g. `darwin-arm64`; null on failure.
  final String? platform;

  /// The Agent SDK version installed; null on failure.
  final String? sdkVersion;

  /// The post-install check, when it ran.
  final AgentSdkPayloadVerification? verification;

  const AgentSdkServerInstallResult._({
    required this.ok,
    required this.failure,
    required this.platform,
    required this.sdkVersion,
    required this.verification,
  });

  const AgentSdkServerInstallResult.failed(
    String this.failure, {
    this.verification,
  }) : ok = false,
       platform = null,
       sdkVersion = null;

  @override
  String toString() => ok
      ? 'AgentSdkServerInstallResult(ok: $platform, SDK $sdkVersion)'
      : 'AgentSdkServerInstallResult(failed: $failure)';
}

/// The `AgentSdkInstallOutcome` a transport reports for [result].
AgentSdkInstallOutcome agentSdkInstallOutcomeOf(
  AgentSdkServerInstallResult result,
) => result.ok
    ? const AgentSdkInstallOutcome.succeeded()
    : AgentSdkInstallOutcome.failed(result.failure!);

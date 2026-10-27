/// Installs the standalone AI server's dependencies into an app data folder —
/// what the app's Install button does, from a terminal.
///
/// ```bash
/// dart run tom_core_agentic:install_agent_sdk_server --app-data <dir>
/// ```
///
/// Runs `npm ci --omit=dev` from the server's shipped lockfile into
/// `<dir>/ai`, with the Node the server will run on — found the way the app
/// finds it (`PATH`, nvm, Homebrew, `/usr/local`; the first at or above 20)
/// unless `--node` names one — then runs the post-install check. It downloads Anthropic's Claude Agent SDK, which
/// the app does not ship: run it only when you mean to install that SDK under
/// Anthropic's terms. CI uses it to exercise the installer end to end.
library;

import 'dart:io';

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/io.dart';

Future<void> main(List<String> args) async {
  String? appData;
  String? installDir;
  var source = _defaultSourceDir();
  String? node;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String next() {
      if (i + 1 >= args.length) {
        stderr.writeln('Missing value for $arg');
        exit(2);
      }
      return args[++i];
    }

    switch (arg) {
      case '--app-data' || '-a':
        appData = next();
      case '--dest' || '-d':
        installDir = next();
      case '--source' || '-s':
        source = next();
      case '--node' || '-n':
        node = next();
      case '--help' || '-h':
        stdout.writeln(_usage);
        return;
      default:
        stderr.writeln('Unknown argument: $arg\n\n$_usage');
        exit(2);
    }
  }

  final target =
      installDir ??
      (appData == null ? null : AgentSdkServerInstaller.installDirFor(appData));
  if (target == null) {
    stderr.writeln('--app-data or --dest is required.\n\n$_usage');
    exit(2);
  }

  // The same search the app runs, so what this installs is what the app
  // will run; `--node` is the explicit path, vouched for as `ai.nodePath` is.
  final resolution = node == null
      ? await llmNodeResolverFor()()
      : LlmNodeResolution.explicit(node);
  stdout.writeln('Node.js: ${resolution.report}');
  final installer = AgentSdkServerInstaller(
    sourceDir: source,
    installDir: target,
  );
  final result = await installer.install(
    node: resolution,
    onProgress: stdout.writeln,
  );
  if (!result.ok) {
    stderr.writeln('AI server install failed: ${result.failure}');
    exit(1);
  }
  stdout.writeln(
    'AI server installed: $target (Agent SDK ${result.sdkVersion}, CLI '
    '${result.platform})',
  );
}

/// This package's own `node/` folder, found from the running script.
String _defaultSourceDir() {
  final sep = Platform.pathSeparator;
  final uri = Platform.script;
  if (uri.isScheme('file')) {
    final binDir = File.fromUri(uri).parent;
    final candidate = '${binDir.parent.path}${sep}node';
    if (Directory(candidate).existsSync()) return candidate;
  }
  return '${Directory.current.path}${sep}node';
}

const _usage = '''
Usage: dart run tom_core_agentic:install_agent_sdk_server --app-data <dir> [options]

  -a, --app-data <dir>  The app data folder; the server goes to <dir>/ai.
  -d, --dest <dir>      Install into <dir> exactly, instead of <app-data>/ai.
  -s, --source <dir>    The server source (agent_sdk_server.js, package.json,
                        package-lock.json). Defaults to this package's node/.
  -n, --node <exe>      The Node.js the server will run on (>= 20). By default
                        it is found as the app finds it: PATH, then
                        ~/.nvm/versions/node (newest first), then
                        /opt/homebrew/bin and /usr/local/bin. npm installs the
                        Claude Code CLI for THIS Node's platform, so it must
                        be the one the app runs.
''';

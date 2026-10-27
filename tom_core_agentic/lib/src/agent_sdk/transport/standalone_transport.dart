/// The **standalone** transport: a Node process the app starts and owns.
///
/// This is the path that keeps the app from being hostage to an editor. It
/// speaks the *same* wire as the hosted path — the CLI server's JSON-RPC
/// framing and its `agentSdk.queryVce` / `agentSdk.cancelVce` /
/// `agentSdk.chunk` methods — but only the subset the Anthropic binding needs.
/// It implements none of `workspace.*`, `tom_todo.*`, `executeExpressionVcb`,
/// or the reverse-RPC tool surface, because a document editor's AI button has
/// no business reaching any of them.
///
/// **Lifecycle.** Unlike the hosted transport, this one *does* start something,
/// and therefore owns it: [connect] spawns the child, [close] terminates it,
/// and the child exits on its own if its stdin closes — so an app that crashes
/// does not leave an orphaned server holding a credential.
///
/// **Credential.** Here the app owns the key (it is a `tokens`-group secret in
/// the settings KDBX). It is handed to the child **in its environment**, never
/// on a command line and never through a shell: [Process.start] is called with
/// `runInShell: false`, so the key never becomes a shell word, never lands in
/// a shell history, and never appears in the child's `argv` where any local
/// process could read it from the process table.
///
/// **Port.** The child binds an ephemeral loopback port and announces it on
/// stdout; nothing is hard-coded and nothing collides with the 19900–19909
/// range the VS Code server uses, so both can run at once.
///
/// **Node.** The transport is handed a [LlmNodeResolver] — a search of
/// the machine (`llmDiscoverNode`) or the one executable `ai.nodePath`
/// names — and never the bare name `node`: a desktop app launched from Finder
/// gets `/usr/bin:/bin:/usr/sbin:/sbin` as its `PATH`, on which `node` is
/// nowhere. The resolution is made once, on the first probe, and
/// the probe, the connect and the installer all run the one executable it
/// names. It governs the whole subtree, not just the server: the Agent SDK
/// spawns the Claude Code CLI as a grandchild under the bare name `node`, so
/// the resolved interpreter's directory is put at the front of the child's
/// `PATH` — see [agentSdkChildEnvironment] for what goes wrong when
/// it is not.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_llm/tom_llm.dart';

import '../server_payload.dart';
import 'transport.dart';
import 'cli_server_channel.dart';

/// The line the child prints once it is listening. Anything else on stdout is
/// diagnostics.
const standaloneReadyPrefix = 'AGENT_SDK_SERVER_READY ';

/// Environment variable naming the server script, for deployments that place
/// it somewhere the default resolution cannot guess.
const standaloneScriptEnvVar = 'AGENT_SDK_SERVER_SCRIPT';

/// The file a packaged app ships and this transport runs.
const agentSdkServerScriptName = 'agent_sdk_server.js';

/// The name of the AI server's folder in both places it lives: beside the app
/// executable, where a packaged app carries the server's **source** (the
/// script, its `package.json` and its `package-lock.json` — no
/// `node_modules`), and in the app's data folder, where the user's install
/// puts the **runnable** server.
///
/// A subdirectory rather than the parent itself, so "what is the app and what
/// is the AI server" stays answerable from a directory listing.
const agentSdkServerPayloadDir = 'ai';

/// The lowest Node major version the shipped server and the Agent SDK accept.
///
/// The same requirement is declared in `node/package.json` as
/// `engines.node`, and the duplication is deliberate: npm needs it there to
/// refuse an install, and the probe needs it here as an int on a path that has
/// to work when a caller has pointed [standaloneScriptEnvVar] at a bare script
/// with no manifest beside it. Reading the manifest at probe time would have to
/// fall back to a constant for exactly that case, which restores the
/// duplication and hides it.
///
/// The `engines.node` test in `server_packaging_test.dart` keeps the two in step: it parses `engines.node` and
/// fails when the numbers disagree, or when the range is written in a form it
/// will not approximate. Bump one and that test names the other.
///
/// Both are in turn a claim about what the Agent SDK needs, so a second
/// test requires this floor to be **at least** the SDK's own declared minimum —
/// directional, because stricter is safe and looser readmits the grandchild
/// failure the floor exists to prevent. This floor is currently above the
/// SDK's, which needs no separate defence: npm enforces the manifest at
/// install time, so a runtime below it cannot install the payload at all.
///
/// The number itself is core's `llmRequiredNodeMajorVersion`, so the
/// discovery that picks a Node and the probe that checks one enforce the same
/// floor.
const requiredNodeMajorVersion = llmRequiredNodeMajorVersion;

/// Reaches Anthropic through a Node server the app starts and owns.
final class StandaloneNodeAiTransport implements AgentSdkInstallableTransport {
  /// Produces the Node this transport runs on: the app's search of the
  /// machine, or a path the caller vouches for (`llmNodeAt`).
  ///
  /// Run on the first probe rather than at construction, because the search
  /// spawns `--version` runs and the selector is built before the settings
  /// that may name a path are read. A resolution that found a Node is kept
  /// for the transport's lifetime; one that found none is run again on the
  /// next probe, so a user who installs Node and presses Retry is not told
  /// about the machine as it was.
  final LlmNodeResolver _resolveNode;

  LlmNodeResolution? _node;

  /// The resolution this transport is running on, once a probe has made it;
  /// null before that.
  LlmNodeResolution? get node => _node;

  /// The executable the resolution named, or null before a probe or when it
  /// named none.
  String? get nodeExecutable => _node?.executable;

  Future<LlmNodeResolution> _resolved() async {
    final kept = _node;
    if (kept != null && kept.found) return kept;
    return _node = await _resolveNode();
  }

  /// The server script to run. Defaults to the [installer]'s installed
  /// script, or to [resolveDefaultServerScript] when there is no installer.
  final String serverScript;

  /// Installs the server's dependencies on the user's request, or null for a
  /// transport pointed at a server someone else installed (a developer's
  /// checkout, `$standaloneScriptEnvVar`).
  ///
  /// With one, "is the server there?" is the installer's question — a script
  /// in the install folder whose install never finished is not a server — and
  /// a missing install is the [AgentSdkUnavailableKind.notInstalled] the
  /// notice offers to fix.
  final AgentSdkServerInstaller? installer;

  /// The Anthropic credential, handed to the child in its environment.
  ///
  /// Given, it is the **only** credential the child can use: the child starts
  /// with a configuration directory of its own and none of the parent's
  /// Anthropic or Claude Code variables, so neither an ambient Claude Code
  /// login nor an inherited key answers in its place
  /// ([agentSdkChildEnvironment]). Null means "the child inherits
  /// whatever is already in the environment", which is how a developer machine
  /// with `ANTHROPIC_API_KEY` exported, or logged in to Claude Code, already
  /// works. The app never reads the value back out of the child.
  ///
  /// An empty key is refused when the transport is built: it can never
  /// authenticate, and as the only credential it would cut the child off from
  /// the ambient login and fail at the far end as a rejected credential.
  final String? apiKey;

  /// Environment variables of the app's own that the child must not inherit
  /// — credentials the app was handed for itself, such as a session token.
  /// The child runs a tool-running SDK, and a credential in its environment is
  /// one a tool can read ([agentSdkChildEnvironment]).
  final Set<String> scrubbedVariables;

  /// Where the empty configuration directory a child started with [apiKey]
  /// is created: one directory per started child, removed when it is closed.
  /// Null means the system's temporary directory.
  final String? _credentialIsolationRoot;

  /// The configuration directory the running child was started with, when it
  /// was started with [apiKey].
  Directory? _isolatedConfigDir;

  /// How long to wait for the child's ready line before giving up.
  ///
  /// Bounds a process that has not started. A process that has started and
  /// then gone quiet mid-completion is bounded by the provider's stall gap,
  /// which applies to every transport alike (`boundedAiRun`).
  @visibleForTesting
  final Duration startupTimeout;

  /// Builds the channel once the port is known. Injected for tests; null means
  /// the ordinary channel.
  final CliServerAiChannel Function(int port)? _channelFactory;

  Process? _process;
  CliServerAiChannel? _channel;
  StreamSubscription<String>? _stderrSub;

  /// Completes when the child's stderr closes — see [stderrDrainBound].
  Completer<void>? _stderrDrained;

  /// How long an early-exit report waits for the child's stderr to close.
  ///
  /// The exit code and the last lines arrive on different pipes, and the exit
  /// can win; a report composed at that moment says "wrote nothing to stderr"
  /// about a child that stated its cause. Bounded rather than unconditional,
  /// because a grandchild holding the inherited pipe keeps it open after the
  /// child has gone.
  @visibleForTesting
  static const stderrDrainBound = Duration(seconds: 2);

  /// The child's most recent stderr lines, kept whether or not [onStderr] is
  /// bound: when it dies before it is ready, these say WHY, and the exit code
  /// alone does not.
  final List<String> _stderrTail = [];
  static const _stderrTailLines = 5;
  String? _unavailableReason;
  AgentSdkUnavailableKind? _unavailableKind;

  /// Set by [close] so a [connect] still waiting for the ready line can tell
  /// *our* SIGTERM from the child dying on its own.
  ///
  /// Without it the two are indistinguishable at the point they are reported:
  /// `close` kills the child, the exit arrives while the startup timer is
  /// still running, and the in-flight connect announces "the standalone AI
  /// server exited with code -15 before it was ready" — blaming the child for a
  /// signal we sent, and sending whoever reads it after a crash that never
  /// happened.
  bool _closing = false;

  /// The child's stderr lines, for the diagnostics log. Never contains the
  /// credential: the child is written not to echo it.
  @visibleForTesting
  final void Function(String line)? onStderr;

  StandaloneNodeAiTransport({
    required LlmNodeResolver node,
    String? serverScript,
    this.installer,
    this.apiKey,
    this.scrubbedVariables = const {},
    String? credentialIsolationRoot,
    this.startupTimeout = const Duration(seconds: 20),
    this.onStderr,
    CliServerAiChannel Function(int port)? channelFactory,
  }) : _resolveNode = node,
       _credentialIsolationRoot = credentialIsolationRoot,
       serverScript =
           serverScript ??
           installer?.serverScript ??
           resolveDefaultServerScript(),
       _channelFactory = channelFactory {
    if (apiKey != null && apiKey!.isEmpty) {
      throw ArgumentError.value(
        apiKey,
        'apiKey',
        'is empty; pass null to let the server use the environment\'s '
            'credential',
      );
    }
  }

  /// The transport a packaged app uses: the server installed under
  /// [appDataDirectory], from the source the app carries beside its
  /// executable (or, run from a checkout, this package's `node/`), on the Node
  /// [node] resolves — the root's search of the machine, honouring
  /// `ai.nodePath`.
  ///
  /// `$standaloneScriptEnvVar` still wins, and then there is no installer: a
  /// developer who points at a server has installed it already.
  factory StandaloneNodeAiTransport.forApp({
    required String appDataDirectory,
    required LlmNodeResolver node,
    String? apiKey,
    Set<String> scrubbedVariables = const {},
    void Function(String line)? onStderr,
  }) {
    final override = Platform.environment[standaloneScriptEnvVar];
    if (override != null && override.isNotEmpty) {
      return StandaloneNodeAiTransport(
        node: node,
        serverScript: override,
        apiKey: apiKey,
        scrubbedVariables: scrubbedVariables,
        credentialIsolationRoot: credentialIsolationRootFor(appDataDirectory),
        onStderr: onStderr,
      );
    }
    return StandaloneNodeAiTransport(
      node: node,
      credentialIsolationRoot: credentialIsolationRootFor(appDataDirectory),
      installer: AgentSdkServerInstaller(
        sourceDir: resolveAgentSdkServerSourceFor(
          executableDir: File(Platform.resolvedExecutable).parent.path,
        ),
        installDir: AgentSdkServerInstaller.installDirFor(appDataDirectory),
      ),
      apiKey: apiKey,
      scrubbedVariables: scrubbedVariables,
      onStderr: onStderr,
    );
  }

  /// Where an app keeps the configuration directories of children started
  /// with an explicit key: beside the installed server, in its data directory.
  @visibleForTesting
  static String credentialIsolationRootFor(String appDataDirectory) =>
      '$appDataDirectory${Platform.pathSeparator}ai'
      '${Platform.pathSeparator}isolated-config';

  @override
  String get id => 'standalone-node';

  /// Identical to the hosted transport's, and deliberately so: the same models
  /// through the same Agent SDK. A user switching paths must not find that the
  /// feature set moved.
  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    canUseTools: true,
    maxContextTokens: 180000,
  );

  @override
  bool get isConnected => _channel?.isConnected ?? false;

  /// Why this transport is unavailable, as a sentence naming the remedy.
  ///
  /// The two false-probe cases are the two halves of the packaging decision
  /// The script is shipped with the
  /// app, so its absence is a build defect; the Node runtime is **supplied by
  /// the user**, so its absence is the expected state on a machine that has
  /// none, and the message has to say what to install.
  @override
  String? get unavailableReason => _unavailableReason;

  @override
  AgentSdkUnavailableKind? get unavailableKind => _unavailableKind;

  /// Runs the [installer], on the user's request, with the Node this
  /// transport resolved — the same one the server will run on, so npm picks
  /// the CLI the SDK will look for. A transport without an installer has
  /// nothing to install and says so rather than pretending to.
  @override
  Future<AgentSdkInstallOutcome> install({
    void Function(String line)? onProgress,
  }) async {
    final installer = this.installer;
    if (installer == null) {
      return const AgentSdkInstallOutcome.failed(
        'this AI server was installed outside the app '
        '($standaloneScriptEnvVar), so there is nothing for the app to '
        'install',
      );
    }
    return agentSdkInstallOutcomeOf(
      await installer.install(node: await _resolved(), onProgress: onProgress),
    );
  }

  /// Why the [installer]'s server cannot run yet, or null when it can (or
  /// there is no installer).
  String? _installProblem() {
    final installer = this.installer;
    if (installer == null) return null;
    return switch (installer.state) {
      AgentSdkServerInstallState.installed => null,
      AgentSdkServerInstallState.notInstalled =>
        'the AI server is not installed yet. This app does not ship '
            "Anthropic's Claude Agent SDK, which it runs on; select Install "
            'to download it with npm into this app\'s data folder (see '
            '$agentSdkInstallExplanationUrl)',
      AgentSdkServerInstallState.outdated =>
        'the installed AI server is from an earlier version of this app. '
            'Select Install to update it (see '
            '$agentSdkInstallExplanationUrl)',
    };
  }

  /// Always null: this transport starts the server it talks to, so there is
  /// never a choice between candidates for it to have resolved quietly.
  @override
  String? get selectionNotice => null;

  /// Checks the preconditions for starting, **without starting**.
  ///
  /// Spawning a Node process to answer "is AI available?" would make the
  /// availability check itself an expensive side effect, run at startup and
  /// again on every retry. So the probe asks the two questions that actually
  /// decide the answer — is there a script, and is there a Node — and leaves
  /// the real failure modes to [connect], which reports them properly.
  ///
  /// A false answer is never an error: Node is a prerequisite the user
  /// supplies, so "no Node on this machine" is an ordinary state that
  /// closes the availability gate and is reported once, not an install prompt and not a
  /// throw.
  @override
  Future<bool> probe() async {
    if (isConnected) {
      _unavailableReason = null;
      _unavailableKind = null;
      return true;
    }
    final installProblem = _installProblem();
    if (installProblem != null) {
      // Node first: an install needs it, so offering Install on a machine
      // without one offers a button that can only fail.
      final nodeProblem = await agentSdkNodeProblemFor(await _resolved());
      if (nodeProblem != null) {
        _unavailableReason = nodeProblem;
        _unavailableKind = AgentSdkUnavailableKind.noRuntime;
        return false;
      }
      _unavailableReason = installProblem;
      _unavailableKind = AgentSdkUnavailableKind.notInstalled;
      return false;
    }
    if (!File(serverScript).existsSync()) {
      // Two remedies, in the order they apply. In a shipped app this is a
      // build defect — the packaging step never ran — and telling its user to
      // set an environment variable points them at a script that was never
      // produced. The developer's remedy still follows, because the same
      // sentence is what a source checkout shows.
      _unavailableReason =
          'the AI server script was not found at "$serverScript" — set '
          '$standaloneScriptEnvVar to an installed server\'s script, or run '
          '`npm ci --omit=dev` in tom_core_agentic/node';
      _unavailableKind = AgentSdkUnavailableKind.unreachable;
      return false;
    }
    final problem = await agentSdkNodeProblemFor(await _resolved());
    if (problem != null) {
      _unavailableReason = problem;
      _unavailableKind = AgentSdkUnavailableKind.noRuntime;
      return false;
    }
    _unavailableReason = null;
    _unavailableKind = null;
    return true;
  }

  /// a transport that starts **its own** server, on the Node this
  /// one resolved and the script it runs. The server takes one client — the
  /// security boundary its header states — so a session cannot share this
  /// transport's child; it starts one, owned by the session's isolate and
  /// gone with it. The installer and the stderr listener stay here: installing
  /// is the main isolate's act, and the listener is the main isolate's object.
  @override
  AgentSdkServerTransport Function()? get sessionCopy {
    final executable = _node?.executable;
    if (executable == null) return null;
    return _copyOn(
      executable,
      serverScript,
      apiKey,
      scrubbedVariables,
      _credentialIsolationRoot,
      startupTimeout,
    );
  }

  /// Built here, from values alone, so the closure captures nothing else.
  static AgentSdkServerTransport Function() _copyOn(
    String executable,
    String serverScript,
    String? apiKey,
    Set<String> scrubbedVariables,
    String? credentialIsolationRoot,
    Duration startupTimeout,
  ) =>
      () => StandaloneNodeAiTransport(
        node: () async => LlmNodeResolution.explicit(executable),
        serverScript: serverScript,
        apiKey: apiKey,
        scrubbedVariables: scrubbedVariables,
        credentialIsolationRoot: credentialIsolationRoot,
        startupTimeout: startupTimeout,
      );

  @override
  Future<void> connect() async {
    if (isConnected) return;
    // A connect begun after a close is a new attempt, not a continuation of
    // the closed one.
    _closing = false;
    // A new attempt's crash is explained by its own output, not an older one's.
    _stderrTail.clear();

    final installProblem = _installProblem();
    if (installProblem != null) {
      throw LlmTransportException(
        LlmErrorKind.unreachable,
        'Could not start the standalone AI server: $installProblem.',
        transportId: id,
      );
    }
    if (!File(serverScript).existsSync()) {
      throw LlmTransportException(
        LlmErrorKind.unreachable,
        'The standalone AI server script was not found at "$serverScript". '
        'Set $standaloneScriptEnvVar or configure the path in settings.',
        transportId: id,
      );
    }

    // Before spawning, not after: an under-floor Node starts the server fine
    // and only fails as a grandchild the user cannot see, so the one moment
    // this is cheap to explain is now.
    final resolution = await _resolved();
    final nodeProblem = await agentSdkNodeProblemFor(resolution);
    if (nodeProblem != null) {
      throw LlmTransportException(
        // Permanent until the machine changes, so closing the availability gate is the
        // right consequence — unlike a stalled completion, which says nothing
        // about whether the backend can be reached.
        LlmErrorKind.unreachable,
        'Could not start the standalone AI server: $nodeProblem.',
        transportId: id,
      );
    }

    final nodeExecutable = resolution.executable!;
    final key = apiKey;
    final Directory? isolatedConfigDir;
    try {
      isolatedConfigDir = key == null ? null : _createIsolatedConfigDir();
    } on FileSystemException catch (e) {
      throw LlmTransportException(
        LlmErrorKind.unreachable,
        'Could not start the standalone AI server: no private configuration '
        'directory could be made for the AI key '
        '(${e.osError?.message ?? e.message}). Check that the app\'s data '
        'directory can be written to.',
        transportId: id,
        cause: e,
      );
    }
    _isolatedConfigDir = isolatedConfigDir;
    final Process process;
    try {
      process = await Process.start(
        nodeExecutable,
        [serverScript],
        // The credential travels here and nowhere else. `runInShell: false`
        // is the load-bearing part: with a shell in the way the environment
        // would be assembled by a command line. The parent environment is
        // copied by [agentSdkChildEnvironment] rather than inherited
        // wholesale, so a session token the app was launched with stays with
        // the app.
        environment: agentSdkChildEnvironment(
          parent: Platform.environment,
          nodeExecutable: nodeExecutable,
          scrubbed: scrubbedVariables,
          credential: key == null
              ? null
              : (apiKey: key, configDirectory: isolatedConfigDir!.path),
        ),
        includeParentEnvironment: false,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      _removeIsolatedConfigDir();
      throw LlmTransportException(
        LlmErrorKind.unreachable,
        'Could not start the standalone AI server: "$nodeExecutable" is not '
        'runnable. Install Node.js or point the setting at it.',
        transportId: id,
        cause: e,
      );
    }
    _process = process;

    final stderrDrained = Completer<void>();
    _stderrDrained = stderrDrained;
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _stderrTail.add(line);
            if (_stderrTail.length > _stderrTailLines) _stderrTail.removeAt(0);
            onStderr?.call(line);
          },
          onDone: () {
            if (!stderrDrained.isCompleted) stderrDrained.complete();
          },
          onError: (Object _) {
            if (!stderrDrained.isCompleted) stderrDrained.complete();
          },
        );

    final int port;
    try {
      port = await _awaitReadyPort(process);
    } on Object {
      await close();
      rethrow;
    }

    final channel = _channelFactory?.call(port) ?? _buildChannel(port);
    try {
      await channel.connect();
    } on Object {
      await close();
      rethrow;
    }
    _channel = channel;
  }

  /// Returns the channel's stream **directly** — see the hosted transport for
  /// why a wrapping generator would break cancellation.
  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) {
    final channel = _channel;
    if (channel == null) {
      return Stream.error(
        LlmTransportException(
          LlmErrorKind.unreachable,
          'The standalone AI transport is not connected.',
          transportId: id,
        ),
      );
    }
    return channel.complete(request);
  }

  /// Closes the channel and terminates the child. Idempotent.
  @override
  Future<void> close() async {
    _closing = true;
    await _channel?.close();
    _channel = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    final process = _process;
    _process = null;
    if (process != null) {
      // Closing stdin is the child's own shutdown signal; the kill is the
      // backstop for a child that ignores it.
      try {
        await process.stdin.close();
      } on Object {
        // The child may already be gone; that is the outcome we wanted.
      }
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    _removeIsolatedConfigDir();
  }

  /// A new, empty directory for one child's Claude Code configuration.
  ///
  /// Empty is the point: the Claude Code CLI the Agent SDK runs keeps its
  /// login under its configuration directory — and on macOS names the
  /// keychain item after that directory — so a child pointed at a directory
  /// nobody has logged in from finds no login, and the key it was handed is
  /// the only credential left. Fresh per child, so one child's state never
  /// becomes another's.
  Directory _createIsolatedConfigDir() {
    final root = Directory(
      _credentialIsolationRoot ?? Directory.systemTemp.path,
    )..createSync(recursive: true);
    return root.createTempSync('claude-config-');
  }

  /// Removes the running child's configuration directory: what the CLI wrote
  /// there (its session record of the conversation) is not kept.
  void _removeIsolatedConfigDir() {
    final dir = _isolatedConfigDir;
    _isolatedConfigDir = null;
    if (dir == null) return;
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone, or held open on Windows by a child that has not quite
      // exited; a leftover directory holds no credential, only a transcript
      // the next start does not read.
    }
  }

  /// Reads stdout until the ready line arrives, the child exits, or the
  /// timeout expires.
  Future<int> _awaitReadyPort(Process process) async {
    final ready = Completer<int>();

    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (ready.isCompleted) return;
          if (!line.startsWith(standaloneReadyPrefix)) {
            onStderr?.call(line);
            return;
          }
          try {
            final payload = jsonDecode(
              line.substring(standaloneReadyPrefix.length),
            );
            final port = (payload as Map)['port'];
            if (port is int) {
              ready.complete(port);
            } else {
              ready.completeError(
                LlmTransportException(
                  LlmErrorKind.protocol,
                  'The standalone AI server announced no port.',
                  transportId: id,
                ),
              );
            }
          } on Object catch (e) {
            ready.completeError(
              LlmTransportException(
                LlmErrorKind.protocol,
                'The standalone AI server sent an unreadable ready line.',
                transportId: id,
                cause: e,
              ),
            );
          }
        });

    unawaited(
      process.exitCode.then((code) async {
        if (ready.isCompleted) return;
        // The exit code and the child's last stderr lines travel on different
        // pipes, and the exit routinely arrives first — measured: one run in
        // twenty reported "wrote nothing to stderr" for a child that had written
        // its cause. So the report waits for stderr to close, bounded, because a
        // grandchild that inherited the pipe can hold it open after the child
        // itself is gone.
        await _stderrDrained?.future.timeout(
          stderrDrainBound,
          onTimeout: () {},
        );
        if (ready.isCompleted) return;
        ready.completeError(
          LlmTransportException(
            LlmErrorKind.unreachable,
            // Two exits, two different facts. A child that died on its own is a
            // failure to start; a child we killed because someone closed the
            // transport mid-start is not the child's doing at all, and saying so
            // is the difference between a report that points at the cause and one
            // that points at the corpse.
            _closing
                ? 'The standalone AI transport was closed while its server was '
                      'starting.'
                : 'The standalone AI server exited with code $code before it was '
                      'ready.${_stderrTail.isEmpty ? ' It wrote nothing to stderr.' : ' Its last output: ${_stderrTail.join(' | ')}'}',
            transportId: id,
          ),
        );
      }),
    );

    try {
      return await ready.future.timeout(
        startupTimeout,
        onTimeout: () => throw LlmTransportException(
          LlmErrorKind.timeout,
          'The standalone AI server did not become ready within '
          '${startupTimeout.inSeconds}s.',
          transportId: id,
        ),
      );
    } finally {
      await stdoutSub.cancel();
    }
  }

  CliServerAiChannel _buildChannel(int port) => CliServerAiChannel(
    transportId: id,
    client: VSCodeBridgeClient(host: '127.0.0.1', port: port),
  );
}

/// Why the Node [node] resolved cannot run the AI server, as a sentence naming
/// the remedy, or null when it can: the search's own account when it found
/// nothing ([agentSdkNodeMissingReason]), else [agentSdkNodeProblem] for the
/// executable it named.
///
/// One function for the transport's probe, its connect and the installer, so
/// the three can never disagree about the same runtime, and the sentence a
/// user sees in the availability gate is the one they get if they force a connection or
/// press Install anyway.
Future<String?> agentSdkNodeProblemFor(LlmNodeResolution node) async {
  final executable = node.executable;
  if (executable == null) return agentSdkNodeMissingReason(node);
  return agentSdkNodeProblem(executable);
}

/// Why [nodeExecutable] cannot run the AI server, as a sentence naming the
/// remedy, or null when it can.
///
/// **Why the version is checked and not only the runnability.** The Agent SDK
/// does not run the CLI in the server process: it spawns Claude Code as a
/// *grandchild*, which fails to parse its own bundle on an older Node. A
/// machine whose `node` is v16 therefore starts the server perfectly well and
/// then dies with "exited with code 1" from a process the user never asked
/// for. Checking here converts that into the sentence it always was.
///
/// **Why an unrecognisable version passes.** The check exists to catch a
/// *known-too-old Node*, not to gatekeep identity: refusing everything it
/// could not parse would refuse any wrapper, launcher or stand-in that works
/// fine. Only a positively identified major below the floor is rejected.
Future<String?> agentSdkNodeProblem(String nodeExecutable) async {
  final ProcessResult result;
  try {
    result = await Process.run(nodeExecutable, const [
      '--version',
    ], runInShell: false);
  } on ProcessException {
    return agentSdkNodeNotRunnableReason(nodeExecutable);
  }
  if (result.exitCode != 0)
    return agentSdkNodeNotRunnableReason(nodeExecutable);

  final match = RegExp(
    r'^v(\d+)\.\d+\.\d+',
  ).firstMatch('${result.stdout}${result.stderr}'.trim());
  final major = match == null ? null : int.tryParse(match.group(1)!);
  if (major != null && major < requiredNodeMajorVersion) {
    return agentSdkNodeTooOldReason(nodeExecutable, major);
  }
  return null;
}

/// The sentence for a search that found no Node at or above the floor: where
/// it looked and what it found, then the remedy.
///
/// "No Node.js runtime" was true of the Finder-launched app on a machine with
/// nine Nodes, and sent its user to install a tenth. The account of the
/// search is what makes the sentence answerable: "`/usr/local/bin/node` is
/// v16.17.0, below 20" says to upgrade or to point the setting at the one
/// that is new enough.
String agentSdkNodeMissingReason(LlmNodeResolution node) =>
    'no Node.js ${node.floor} or newer was found — ${node.report}. Install '
    'Node.js ${node.floor} or newer, or point the setting (Settings › AI › '
    'Node.js) at an existing installation';

/// The sentence for a Node that cannot be run at all.
String agentSdkNodeNotRunnableReason(String nodeExecutable) =>
    'no Node.js runtime — "$nodeExecutable" could not be run. Install '
    'Node.js $requiredNodeMajorVersion or newer, or point the setting at '
    'an existing installation';

/// The sentence for a Node below [requiredNodeMajorVersion].
String agentSdkNodeTooOldReason(String nodeExecutable, int major) =>
    '"$nodeExecutable" is Node $major, and the AI server needs Node '
    '$requiredNodeMajorVersion or newer — the Agent SDK runs the Claude '
    'Code CLI on it, and older runtimes cannot parse it. Upgrade Node, '
    'or point the setting at a newer installation';

/// Locates a runnable `agent_sdk_server.js` for a transport with no
/// installer — a developer's tool, not the packaged app's path.
///
/// Resolution order: the environment override, then a source checkout's
/// `tom_core_agentic/node`, found by walking up. A packaged app does not come
/// through here: the `ai/` folder beside its executable holds the server's
/// *source* without its dependencies, which cannot run until the user has
/// installed them (see [StandaloneNodeAiTransport.forApp]).
String resolveDefaultServerScript() {
  final override = Platform.environment[standaloneScriptEnvVar];
  if (override != null && override.isNotEmpty) return override;
  return resolveServerScriptFor(
    executableDir: File(Platform.resolvedExecutable).parent.path,
  );
}

/// The resolution proper, with the one unmockable input passed in.
///
/// [executableDir] only names the location reported when nothing is found;
/// the packaged layout is never *run* from (see [resolveDefaultServerScript]).
String resolveServerScriptFor({required String executableDir}) {
  final candidates = agentSdkServerScriptCandidates(
    executableDir: executableDir,
  );
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  // Nothing found: a concrete location rather than an empty string, so the
  // error message names somewhere.
  final sep = Platform.pathSeparator;
  return '$executableDir$sep$agentSdkServerPayloadDir$sep'
      '$agentSdkServerScriptName';
}

/// Every place a runnable server script is looked for, in order: source
/// checkouts only.
List<String> agentSdkServerScriptCandidates({required String executableDir}) =>
    _sourceCandidates(agentSdkServerScriptName, Platform.pathSeparator);

/// Every folder the server's **source** — the three files an install starts
/// from — is looked for in, in order.
///
/// The packaged layout first and the source checkout second, so a shipped app
/// never installs from a developer's working tree that happens to sit above it
/// on disk.
List<String> agentSdkServerSourceCandidates({required String executableDir}) {
  final sep = Platform.pathSeparator;
  return <String>[
    '$executableDir$sep$agentSdkServerPayloadDir',
    for (final script in _sourceCandidates(agentSdkServerScriptName, sep))
      File(script).parent.path,
  ];
}

/// The folder an install takes the server's source from: the first of
/// [agentSdkServerSourceCandidates] holding all three source files, else the
/// packaged location, so a failure names where the source was expected.
String resolveAgentSdkServerSourceFor({required String executableDir}) {
  final sep = Platform.pathSeparator;
  final candidates = agentSdkServerSourceCandidates(
    executableDir: executableDir,
  );
  for (final dir in candidates) {
    if (agentSdkServerSourceFiles.every(
      (name) => File('$dir$sep$name').existsSync(),
    )) {
      return dir;
    }
  }
  return candidates.first;
}

List<String> _sourceCandidates(String scriptName, String sep) {
  final found = <String>[
    // This package's own `node/`, when the program runs with a package
    // configuration that names it — a source checkout under `dart run` or
    // `dart test`. A compiled app has none, and the packaged layout serves.
    ..._packageNode(scriptName, sep),
    // The working directory, walked first because it is the one signal that
    // survives every way a source checkout gets run. `Platform.script` points
    // at a generated stub under `dart test`, so a resolver that trusted only
    // that would fail to find a script sitting right beside it.
    ..._walkUpFor(Directory.current, scriptName, sep),
    ..._walkUpForScriptUri(scriptName, sep),
  ];
  return found;
}

List<String> _packageNode(String scriptName, String sep) {
  final Uri? lib;
  try {
    lib = Isolate.resolvePackageUriSync(Uri.parse('package:tom_core_agentic/'));
  } on UnsupportedError {
    // A runner without package resolution (the Flutter test host); the
    // directory walks below still find a checkout.
    return const [];
  }
  if (lib == null || !lib.isScheme('file')) return const [];
  final candidate =
      '${Directory.fromUri(lib).parent.path}${sep}node$sep$scriptName';
  return File(candidate).existsSync() ? [candidate] : const [];
}

List<String> _walkUpForScriptUri(String scriptName, String sep) {
  final uri = Platform.script;
  if (!uri.isScheme('file')) return const [];
  return _walkUpFor(File.fromUri(uri).parent, scriptName, sep);
}

List<String> _walkUpFor(Directory start, String scriptName, String sep) {
  var dir = start;
  // Walk up looking for this package's `node/` in a source checkout;
  // bounded so a script run from `/` cannot turn this into a filesystem walk.
  for (var i = 0; i < 6; i++) {
    for (final package in [
      'tom_core_agentic',
      'tom_ai${sep}core_extension${sep}tom_core_agentic',
    ]) {
      final candidate = '${dir.path}$sep$package${sep}node$sep$scriptName';
      if (File(candidate).existsSync()) return [candidate];
    }
    final node = '${dir.path}${sep}node$sep$scriptName';
    if (File(node).existsSync()) return [node];
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return const [];
}

/// The environment the standalone server child is started with: [parent] —
/// the app's own — with [nodeExecutable]'s directory at the front of `PATH`,
/// and **without** the variables in [scrubbed] — credentials the app was
/// handed for itself, such as a session token it was launched with.
///
/// **The credential.** With no [credential] the child keeps the parent's
/// Anthropic and Claude Code variables, and the Agent SDK uses whatever it
/// finds: an exported `ANTHROPIC_API_KEY`, or the machine's Claude Code login.
/// With a [credential] the key it carries is the **only** one the child can
/// use. Every inherited variable whose name starts with `ANTHROPIC_` or
/// `CLAUDE` is dropped — another key, an auth token, a base URL, an OAuth
/// token, a configuration directory, the markers of a parent Claude Code
/// session — and `CLAUDE_CONFIG_DIR` names the credential's own empty
/// directory. That last part is what removes the ambient login: the Claude
/// Code CLI keeps its login under its configuration directory and on macOS
/// names its keychain item after it, so a directory nobody logged in from
/// holds none. Without it the SDK answered with the machine's login while
/// the user believed their key was in use — billed to and identified as
/// someone else, and with a wrong key never reported as wrong.
///
/// **Why those are scrubbed.** A token the user handed the app for one
/// session is the app's to use, not the AI server's to inherit: the
/// server runs Anthropic's Agent SDK, which runs tools, and a credential in a
/// tool-running process's environment is one a tool can read. The Anthropic
/// key is the one credential that process exists to hold; nothing else the
/// app was given travels with it.
///
/// **Why `PATH` is not cosmetic.** The Agent SDK does not run in the server
/// process: it spawns the Claude Code CLI as a *grandchild*, and it spawns it
/// as the bare name `node`. So the grandchild resolves its interpreter from
/// `PATH`, not from the Node that the app chose. On a machine whose `PATH`
/// still points at an older Node — an nvm default of v16 is the case this was
/// measured on — the grandchild fails to parse the CLI bundle and dies with a
/// syntax error, while the server it was launched from is running happily on
/// the Node 20 it was given. The symptom is a completion that reports "the
/// Claude Code process exited with code 1" and names no cause.
///
/// Prepending rather than replacing keeps everything else the SDK looks up on
/// `PATH` reachable, and prepending rather than appending is what makes it
/// win over the stale entry that caused the problem.
///
/// A bare executable name is left alone: it was itself resolved through
/// `PATH`, so the grandchild would find the same one anyway. (A discovered
/// Node is always an absolute path; only a vouched-for one can be bare.)
///
/// Variable names are compared case-insensitively, as Windows compares them.
///
/// A top-level function over a plain map rather than a method over
/// `Platform.environment`, so what the child is handed can be asserted
/// without spawning one.
Map<String, String> agentSdkChildEnvironment({
  required Map<String, String> parent,
  required String nodeExecutable,
  Set<String> scrubbed = const {},
  ({String apiKey, String configDirectory})? credential,
}) {
  bool claudeOrAnthropic(String name) {
    final upper = name.toUpperCase();
    return upper.startsWith('ANTHROPIC_') || upper.startsWith('CLAUDE');
  }

  final environment = <String, String>{
    for (final entry in parent.entries)
      if (!scrubbed.contains(entry.key) &&
          !(credential != null && claudeOrAnthropic(entry.key)))
        entry.key: entry.value,
  };
  if (credential != null) {
    environment['ANTHROPIC_API_KEY'] = credential.apiKey;
    environment['CLAUDE_CONFIG_DIR'] = credential.configDirectory;
  }
  if (nodeExecutable.contains(Platform.pathSeparator)) {
    final nodeDir = File(nodeExecutable).parent.path;
    final separator = Platform.isWindows ? ';' : ':';
    // The variable as the parent spells it: Windows environments are
    // case-insensitive and commonly carry `Path`, and a second spelling would
    // be two variables to a map and one to the child.
    final pathKey =
        environment.keys.where((k) => k.toUpperCase() == 'PATH').firstOrNull ??
        'PATH';
    final inherited = environment[pathKey] ?? '';
    environment[pathKey] = inherited.isEmpty
        ? nodeDir
        : '$nodeDir$separator$inherited';
  }
  return environment;
}

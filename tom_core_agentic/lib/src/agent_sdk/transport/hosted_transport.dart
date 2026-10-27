/// The **hosted** transport: the CLI server that a running VS Code already
/// operates.
///
/// Three questions define this path.
///
/// **Discovery.** The CLI server binds the first free port in 19900–19909, so
/// there is no fixed address to connect to. The scan-and-identify procedure
/// that resolves it already exists in `tom_vscode_scripting_api`
/// (`scanBridgePorts` / `findBridgePortsForWorkspace`) and is used verbatim; a
/// second copy here would drift the moment the port range moved. When
/// [workspaceName] is given the scan matches that workspace, which is what a
/// user with several VS Code windows open needs. When it is null, the
/// lowest-numbered responding server wins — the right default for a
/// single-window machine and an honest one for a multi-window machine, because
/// every such server reaches the same Anthropic account.
///
/// The name a window answers with is the basename of its open `.code-workspace`
/// file with the extension removed, falling back to the workspace's reported
/// name and then to the root folder's basename. It is therefore frequently
/// *not* the folder name a user would guess, and two windows on the same
/// workspace answer identically — a pin distinguishes windows by what they have
/// open, not by which window they are.
///
/// **Lifecycle.** This transport **never starts anything**. If VS Code is not
/// running there is no server, [probe] answers false, and the provider is
/// unavailable — which is the correct outcome, not a failure to paper over.
/// Launching an editor to answer a completion would be a startling side effect
/// of pressing a button in a document editor. The no-VS-Code case is the
/// standalone transport's job, and that division is exactly why there are two.
///
/// **Security.** The socket is loopback-only on both ends: the CLI server binds
/// `InternetAddress.loopbackIPv4`, and this client connects to `127.0.0.1`.
/// That is the entire boundary, and it is worth stating plainly rather than
/// implying more: any local process running as this user can reach the server.
/// The posture the app adds is **what it does not send** — the API credential
/// stays with the transport (the app never reads or copies it, and never
/// writes it to the settings KDBX), and no password material can reach the
/// wire because a [AgentSdkCompletionRequest] carries text, not sections.
/// [host] is settable only so a test can point at a loopback fixture; it is
/// validated to stay on loopback, so a misconfiguration cannot silently turn a
/// local socket into a network one.
library;

import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_llm/tom_llm.dart';

import 'transport.dart';
import 'cli_server_channel.dart';

/// Loopback addresses this transport is permitted to connect to.
const _loopbackHosts = {'127.0.0.1', '::1', 'localhost'};

/// One VS Code CLI server that answered a discovery scan.
///
/// Carries the port as well as the identity because the identity is **not
/// unique**: two windows with the same workspace open answer identically, and
/// a picker that showed only the name would offer two rows a user cannot tell
/// apart. The port is reassigned on every restart, so it is shown and
/// discarded, never stored.
final class AgentSdkWorkspaceCandidate {
  /// What the window reports as its workspace identity.
  final String identity;

  /// The loopback port it answered on, for this scan only.
  final int port;

  const AgentSdkWorkspaceCandidate({
    required this.identity,
    required this.port,
  });

  @override
  String toString() => 'AgentSdkWorkspaceCandidate($identity on $port)';

  @override
  bool operator ==(Object other) =>
      other is AgentSdkWorkspaceCandidate &&
      other.identity == identity &&
      other.port == port;

  @override
  int get hashCode => Object.hash(identity, port);
}

/// Every VS Code CLI server answering right now, for the workspace pin.
///
/// Lives here rather than in the composition root because the scan belongs
/// beside the transport that consumes it — and because the root would otherwise
/// need its own dependency on `tom_vscode_scripting_api` to ask a question this
/// package already knows how to ask.
///
/// Returns **every** responder, including duplicates of one identity: two
/// windows on one workspace answer identically, and a settings
/// picker needs to know that before it offers the name as a choice. Sorted by
/// port so the list is stable between scans.
Future<List<AgentSdkWorkspaceCandidate>> discoverHostedAiWorkspaces({
  String host = '127.0.0.1',
  int minPort = defaultVSCodeBridgePort,
  int maxPort = maxVSCodeBridgePort,
}) async {
  final table = await scanBridgePorts(
    host: host,
    minPort: minPort,
    maxPort: maxPort,
  );
  return [
    for (final entry in table.entries)
      AgentSdkWorkspaceCandidate(identity: entry.value, port: entry.key),
  ]..sort((a, b) => a.port.compareTo(b.port));
}

/// What one discovery scan concluded for a transport's configuration.
final class HostedServerResolution {
  /// The port to connect to, or null when nothing matched.
  final int? port;

  /// Every port whose server answered to the configured pin, ascending.
  ///
  /// **Empty when no pin is set**, and that is a statement rather than a
  /// shortcut: an unpinned scan takes the lowest responding server by
  /// documented rule, so there is no ambiguity to report — the user expressed
  /// no intent to choose between windows. Ambiguity is only a fact about a
  /// *pin*, because only a pin can fail to do what it was asked to do.
  final List<int> pinMatches;

  const HostedServerResolution(this.port, {this.pinMatches = const []});
}

/// Reaches Anthropic through the CLI server of a running VS Code.
final class HostedCliServerAiTransport implements AgentSdkServerTransport {
  /// The loopback host the CLI server is expected on.
  final String host;

  /// The workspace whose VS Code window to use, or null to take the
  /// lowest-numbered responding server.
  final String? workspaceName;

  /// The inclusive port range the CLI server binds within.
  final int minPort;
  final int maxPort;

  /// Builds the channel for a resolved port. Injected so a test can drive the
  /// discovery-and-connect logic against a fixture server; null means the
  /// ordinary channel.
  final CliServerAiChannel Function(String host, int port)? _channelFactory;

  /// Resolves the scan. Injected for the same reason as [_channelFactory].
  final Future<HostedServerResolution> Function(
    String host,
    int minPort,
    int maxPort,
    String? workspaceName,
  )
  _resolve;

  CliServerAiChannel? _channel;
  String? _unavailableReason;
  String? _selectionNotice;

  HostedCliServerAiTransport({
    this.host = '127.0.0.1',
    this.workspaceName,
    this.minPort = defaultVSCodeBridgePort,
    this.maxPort = maxVSCodeBridgePort,
    CliServerAiChannel Function(String host, int port)? channelFactory,
    Future<HostedServerResolution> Function(
      String host,
      int minPort,
      int maxPort,
      String? workspaceName,
    )?
    resolve,
  }) : _channelFactory = channelFactory,
       _resolve = resolve ?? _defaultResolve {
    if (!_loopbackHosts.contains(host)) {
      throw ArgumentError.value(
        host,
        'host',
        'The hosted AI transport only connects to loopback: the CLI server '
            'binds loopback and a non-loopback host would mean a different '
            'server entirely.',
      );
    }
  }

  @override
  String get id => 'vscode-cli-server';

  /// Both transports reach the same models through the same Agent SDK,
  /// so this is a constant rather than a handshake (see [AgentSdkServerTransport]).
  ///
  /// `canEmbed` is false and stays false: Anthropic exposes no embeddings API,
  /// so semantic search degrades to lexical for as long as no transport embeds.
  /// `canUseTools` is true: a request carrying tools declares them on an
  /// in-process MCP server the extension rebuilds, and each call comes back
  /// over this connection as `agentSdk.toolCall` (see [CliServerAiChannel]).
  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    canUseTools: true,
    maxContextTokens: 180000,
  );

  @override
  bool get isConnected => _channel?.isConnected ?? false;

  /// Why the last [probe] answered false — the same remedy text [connect]
  /// raises, so a user sees it in the ordinary "the server is off" case and
  /// not only in the race where it disappears between the scan and the
  /// handshake.
  @override
  String? get unavailableReason => _unavailableReason;

  @override
  String? get selectionNotice => _selectionNotice;

  @override
  Future<bool> probe() async {
    try {
      final resolution = await _resolveAndRecord();
      final reachable = resolution.port != null;
      _unavailableReason = reachable ? null : _noServerMessage;
      return reachable;
    } on Object {
      // A probe answers a question; it does not raise one.
      _unavailableReason = _noServerMessage;
      _selectionNotice = null;
      return false;
    }
  }

  /// One scan, and the one place [selectionNotice] is decided.
  ///
  /// Shared by [probe] and [connect] for the reason [_noServerMessage] is: two
  /// paths that resolve the same configuration must not reach different
  /// conclusions about it. The notice is recomputed on every resolution rather
  /// than latched, so closing the second window clears it without a restart.
  Future<HostedServerResolution> _resolveAndRecord() async {
    final resolution = await _resolve(host, minPort, maxPort, workspaceName);
    _selectionNotice = _ambiguityNoticeFor(resolution);
    return resolution;
  }

  /// The sentence for a pin that matched more than one window, or null.
  ///
  /// It says which port was taken, because "several matched" without naming
  /// the outcome tells a user there is a problem and not what happened; and it
  /// names the cause — a pin selects a *workspace*, and two windows on one
  /// workspace are identical to it — because that is the part a user cannot
  /// deduce from the symptom.
  String? _ambiguityNoticeFor(HostedServerResolution resolution) {
    if (resolution.pinMatches.length < 2) return null;
    final ports = resolution.pinMatches.join(', ');
    return '${resolution.pinMatches.length} VS Code windows report the '
        'workspace "$workspaceName" (ports $ports). AI is using '
        '${resolution.port}. A pin names a workspace, not a window, so two '
        'windows with the same workspace open cannot be told apart — every '
        'one of them reaches the same Anthropic account, so this changes '
        'nothing unless you meant a particular window.';
  }

  /// The one explanation of "no server answered", shared by [probe] and
  /// [connect] so the two can never drift into telling the user different
  /// things about the same situation.
  ///
  /// **It does not claim whether VS Code is running, because it cannot know
  /// and does not need to.** There is no out-of-band signal: every discovery
  /// route in `tom_vscode_scripting_api` goes *through* the bridge, so a
  /// silent port range is equally consistent with a closed editor and an open
  /// one whose server was never started. Deciding between them would mean
  /// enumerating processes — platform-specific, and wrong in the ordinary
  /// cases of Insiders, VSCodium, a flatpak, a remote window or two installs —
  /// and a confidently wrong "VS Code is running" is worse than a sentence
  /// that covers both. It costs nothing to leave open, because the remedy is
  /// the same either way, and the fact the user is actually missing is that
  /// the server is not automatic.
  String get _noServerMessage => workspaceName == null
      ? 'VS Code is not serving AI on $host:$minPort–$maxPort. The CLI '
            'server does not start with the editor, so this is the ordinary '
            'state of a running VS Code: use the Tom extension\'s "Start CLI '
            'Server" command in the window you want — or open a window first, '
            'if none is running.'
      : 'No VS Code CLI server on $host:$minPort–$maxPort reports the '
            'workspace "$workspaceName". A window reports the name of its '
            '.code-workspace file without the extension, which is often '
            'not the name of its folder.';

  @override
  Future<void> connect() async {
    if (isConnected) return;
    final port = (await _resolveAndRecord()).port;
    if (port == null) {
      throw LlmTransportException(
        LlmErrorKind.unreachable,
        _noServerMessage,
        transportId: id,
      );
    }
    final channel = _channelFactory?.call(host, port) ?? _buildChannel(port);
    await channel.connect();
    _channel = channel;
    _port = port;
  }

  /// The port the last [connect] reached, kept after a [close]: a session
  /// copy connects to the window this transport chose, not to whichever
  /// answers first when the copy scans.
  int? _port;

  /// the same CLI server, on the port this transport resolved —
  /// the server takes any number of clients, so a session's connection is its
  /// own socket to it.
  @override
  AgentSdkServerTransport Function()? get sessionCopy {
    final port = _port;
    if (port == null) return null;
    return _copyAt(host, port, workspaceName);
  }

  /// Built here, from values alone, so the closure captures nothing else.
  static AgentSdkServerTransport Function() _copyAt(
    String host,
    int port,
    String? workspaceName,
  ) =>
      () => HostedCliServerAiTransport(
        host: host,
        workspaceName: workspaceName,
        minPort: port,
        maxPort: port,
      );

  /// Returns the channel's stream **directly**, rather than re-yielding it from
  /// a generator: a wrapping `async*` would swallow cancellation exactly when
  /// the completion is still in flight, which is the only time cancelling is
  /// worth anything. No stall bound is applied here; the provider applies the
  /// one bound every transport gets (`boundedAiRun`).
  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) {
    final channel = _channel;
    if (channel == null) {
      return Stream.error(
        LlmTransportException(
          LlmErrorKind.unreachable,
          'The hosted AI transport is not connected.',
          transportId: id,
        ),
      );
    }
    return channel.complete(request);
  }

  @override
  Future<void> close() async {
    await _channel?.close();
    _channel = null;
  }

  CliServerAiChannel _buildChannel(int port) => CliServerAiChannel(
    transportId: id,
    client: VSCodeBridgeClient(host: host, port: port),
  );

  /// The default resolver: **one** upstream scan, either way.
  ///
  /// Pinned, `findBridgePortsForWorkspace` answers with every window that
  /// reports the workspace, ascending — the whole question in one pass, so
  /// this transport can take the lowest and still name the others in
  /// [selectionNotice]. Its singular, `findBridgePortForWorkspace`, stops at
  /// the first match by design and is the wrong call here for exactly that
  /// reason: a caller cannot report what the callee declined to look for.
  /// Unpinned, `scanBridgePorts` lists every responder and the lowest port
  /// wins by documented rule. The matching rule is upstream's in both cases
  /// (`normalizeWorkspaceName`), so a bare name, a `.code-workspace` filename
  /// and VS Code's `" (Workspace)"` suffix match each other here exactly as
  /// they do there.
  static Future<HostedServerResolution> _defaultResolve(
    String host,
    int minPort,
    int maxPort,
    String? workspaceName,
  ) async {
    if (workspaceName != null) {
      final matches = await findBridgePortsForWorkspace(
        workspaceName,
        host: host,
        minPort: minPort,
        maxPort: maxPort,
      );
      if (matches.isEmpty) return const HostedServerResolution(null);
      return HostedServerResolution(matches.first, pinMatches: matches);
    }
    final table = await scanBridgePorts(
      host: host,
      minPort: minPort,
      maxPort: maxPort,
    );
    if (table.isEmpty) return const HostedServerResolution(null);
    // Ascending, so "the one we take" is a rule and not an accident of map
    // ordering. `scanBridgePorts` already returns ascending order; sorting is
    // cheap and makes this file's guarantee independent of that.
    final ports = table.keys.toList()..sort();
    return HostedServerResolution(ports.first);
  }
}

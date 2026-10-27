// Bridge connection discovery + choice persistence.
//
// The TomSpecs editor connects to a running VS Code CLI Integration Server to
// reach Claude Code over the bridge. Multiple VS Code windows each run a
// server on a distinct port in 19900–19909; this layer scans that range, runs
// the workspace-identify handshake (`workspace.getInfoVce`, via
// `scanBridgePorts`), and persists the user's picked server so it is restored
// on the next launch.
//
// This file is the **non-UI** half (no Flutter): the scan service, the picker
// model, and the YAML sidecar store. The Flutter controller + picker widget
// that drive it live in `tom_forge_agentic`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';

import 'agent_sidecar.dart';

/// Lowest CLI bridge port scanned (inclusive).
const int bridgeScanMinPort = defaultVSCodeBridgePort;

/// Highest CLI bridge port scanned (inclusive).
const int bridgeScanMaxPort = maxVSCodeBridgePort;

/// The host every bridge default in this package points at: IPv4 loopback.
///
/// Named rather than spelled out at each site because the sites have to agree
/// and once did not — [AgentSettings.bridgeHost] defaulted to `localhost`
/// while the other three defaulted to `127.0.0.1`, and since a binding was
/// matched against a scan by comparing the host *strings*, a bridge that was
/// up and answering was reported as gone. [BridgeChoice.matches] now makes
/// that comparison endpoint-wise so the spellings can differ safely; this
/// constant makes the defaults unable to differ in the first place.
const String defaultBridgeHost = '127.0.0.1';

/// Every spelling of the local loopback interface.
const Set<String> _loopbackHosts = {'localhost', '127.0.0.1', '::1'};

/// Lowercases a host and strips the brackets an IPv6 literal is written with,
/// so `[::1]` and `::1` are one token.
String _canonicalHost(String host) {
  final trimmed = host.trim().toLowerCase();
  return trimmed.length > 1 && trimmed.startsWith('[') && trimmed.endsWith(']')
      ? trimmed.substring(1, trimmed.length - 1)
      : trimmed;
}

/// Whether [a] and [b] name the same bridge endpoint.
///
/// Case-insensitive (host names are), and every spelling of loopback is one
/// endpoint. Everything else compares as text — this layer scans a local port
/// range and does no name resolution, so two hosts it cannot prove identical
/// must stay distinct rather than a binding silently following a scan onto a
/// different machine.
bool _sameEndpoint(String a, String b) {
  final x = _canonicalHost(a);
  final y = _canonicalHost(b);
  return x == y || (_loopbackHosts.contains(x) && _loopbackHosts.contains(y));
}

/// How a discovered server relates to the editor right now.
enum BridgeServerStatus {
  /// A live server, reachable but not currently bound.
  available('available'),

  /// The server the editor is bound to.
  bound('bound');

  const BridgeServerStatus(this.token);

  /// Stable token for display / persistence.
  final String token;
}

/// One responsive VS Code bridge: its port, the workspace its window has open,
/// and how it relates to the editor (`available` / `bound`). Shown in the
/// picker as *port · workspace · status*.
final class BridgeServer {
  const BridgeServer({
    required this.port,
    required this.workspace,
    this.host = defaultBridgeHost,
    this.status = BridgeServerStatus.available,
  });

  /// The CLI Integration Server port.
  final int port;

  /// Host the server is reachable on.
  final String host;

  /// The workspace name reported by the window-identity handshake.
  final String workspace;

  /// How this server relates to the editor right now.
  final BridgeServerStatus status;

  BridgeServer copyWith({BridgeServerStatus? status}) => BridgeServer(
    port: port,
    host: host,
    workspace: workspace,
    status: status ?? this.status,
  );

  @override
  bool operator ==(Object other) =>
      other is BridgeServer &&
      other.port == port &&
      other.host == host &&
      other.workspace == workspace &&
      other.status == status;

  @override
  int get hashCode => Object.hash(port, host, workspace, status);

  @override
  String toString() =>
      'BridgeServer($host:$port · $workspace · ${status.token})';
}

/// Scans the bridge port range and returns a `port → workspace` table.
///
/// Injected into [BridgeConnectionService] so a test can supply fake bridges
/// without opening sockets. The production default delegates to
/// [scanBridgePorts].
typedef BridgePortScanner =
    Future<Map<int, String>> Function({
      required String host,
      required int minPort,
      required int maxPort,
    });

Future<Map<int, String>> _defaultScanner({
  required String host,
  required int minPort,
  required int maxPort,
}) => scanBridgePorts(host: host, minPort: minPort, maxPort: maxPort);

/// Discovers live VS Code bridge servers.
///
/// Wraps the port scan so the UI controller depends only on `tom_core_agentic`
/// and never touches the transport package directly.
final class BridgeConnectionService {
  BridgeConnectionService({
    this.host = defaultBridgeHost,
    this.minPort = bridgeScanMinPort,
    this.maxPort = bridgeScanMaxPort,
    BridgePortScanner scanner = _defaultScanner,
  }) : _scanner = scanner;

  /// Host to scan (default loopback).
  final String host;

  /// First port scanned (inclusive).
  final int minPort;

  /// Last port scanned (inclusive).
  final int maxPort;

  final BridgePortScanner _scanner;

  /// Scans the port range and returns the responsive servers in ascending
  /// port order. Every result is [BridgeServerStatus.available]; binding is
  /// the caller's concern.
  Future<List<BridgeServer>> scan() async {
    final table = await _scanner(
      host: host,
      minPort: minPort,
      maxPort: maxPort,
    );
    final ports = table.keys.toList()..sort();
    return [
      for (final port in ports)
        BridgeServer(port: port, host: host, workspace: table[port]!),
    ];
  }
}

/// The persisted choice: which host+port the editor last bound to.
final class BridgeChoice {
  const BridgeChoice({required this.host, required this.port});

  /// Bound host.
  final String host;

  /// Bound port.
  final int port;

  Map<String, Object?> toMap() => {'host': host, 'port': port};

  /// Reads a choice from a persisted mapping, defaulting either field it
  /// cannot use.
  ///
  /// Type-tests rather than casts, so a hand-edited `port: "19900"` reads as
  /// the default instead of throwing a `TypeError` past the store's catch. An
  /// unusable value and an absent one are the same thing to a reader, and the
  /// absent case already defaulted.
  factory BridgeChoice.fromMap(Map map) {
    final host = map['host'];
    final port = map['port'];
    return BridgeChoice(
      host: host is String && host.isNotEmpty ? host : defaultBridgeHost,
      port: port is num ? port.toInt() : defaultVSCodeBridgePort,
    );
  }

  /// Whether [server] is the bridge this binding names.
  ///
  /// The port must be equal; the host must name the same *endpoint*, which is
  /// weaker than being the same string. The two sides reach this comparison
  /// from different places — the binding from the sidecar (or its
  /// [defaultBridgeHost] fallback), the server from a scan of
  /// `AgentSettings.bridgeHost` — so they can spell one loopback endpoint
  /// differently while meaning the same bridge. When the comparison was
  /// textual that reported a live bridge as gone: the still-gone modal for a
  /// working bridge, no auto-resend, and the picker showing the bound server
  /// as merely available.
  ///
  /// Deliberately not folded into [operator ==], which is value equality on
  /// the record that was persisted and has to keep agreeing with [toMap].
  bool matches(BridgeServer server) =>
      server.port == port && _sameEndpoint(server.host, host);

  @override
  bool operator ==(Object other) =>
      other is BridgeChoice && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'BridgeChoice($host:$port)';
}

/// Persists the picked bridge server to a YAML sidecar so the binding is
/// restored on the next launch.
///
/// Mirrors the editor's other sidecars: a small YAML file written
/// synchronously on every change. The file lives outside the document so it is
/// never part of a `*.docspecs.yaml` save.
final class BridgeChoiceStore {
  BridgeChoiceStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the sidecar location. Honors `TOM_SPECS_BRIDGE_FILE`; falls back
  /// to `<cwd>/.tom/bridge_connection.yaml`.
  factory BridgeChoiceStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_BRIDGE_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'bridge_connection.yaml');
    return BridgeChoiceStore(File(path));
  }

  /// Loads the persisted choice, or `null` when the file is missing, empty,
  /// unreadable or malformed.
  ///
  /// Degrades exactly like the other nine sidecar stores — and now through
  /// the same code, which is what makes "exactly" checkable. A damaged
  /// sidecar should cost the user a re-pick, not a crash on launch. This is
  /// the sidecar most likely to be hand-edited, since it is the file you open
  /// to check which port the editor bound to, so the damage this swallows is
  /// the realistic case rather than the exotic one.
  BridgeChoice? load() => decodeAgentYamlValue(
    readAgentYamlFile(file),
    key: 'bridge',
    fromYaml: BridgeChoice.fromMap,
    orElse: null,
  );

  /// Persists [choice], creating the parent directory if needed.
  void save(BridgeChoice choice) {
    final buffer = StringBuffer()
      ..writeln('# TomSpecs editor — bound VS Code bridge server.')
      ..writeln('# Written by the agent connection picker.')
      ..writeln('version: 1')
      ..writeln('bridge:')
      ..writeln('  host: ${choice.host}')
      ..writeln('  port: ${choice.port}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(buffer.toString());
  }

  /// Removes the persisted choice (e.g. on explicit unbind).
  void clear() {
    if (file.existsSync()) file.deleteSync();
  }
}

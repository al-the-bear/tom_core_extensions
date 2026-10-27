// Reconnect protocol for the TomSpecs editor's VS Code bridge connection.
//
// When the bound VS Code bridge stops responding the transport itself is gone
// — there is no way to hold the live socket / in-flight exchange open. We
// therefore preserve the *user's intent*, not the connection: re-scan with a
// back-off, and on reconnect re-issue the interrupted prompt prefixed with the
// active profile's `interruptRetryPrefix`.
//
// This file is the **non-UI** half (no Flutter): the back-off retry loop, the
// same/different-workspace classification, and the prefix composition. The
// Flutter `AgentSendController` in `tom_forge_agentic` drives it, owns the
// informational popup / modal / confirmation UI, and performs the auto-resend.
library;

import 'bridge_connection.dart';

/// Composes the auto-resend body for an interrupted prompt:
/// the active profile's [prefix] followed by the original [prompt].
///
/// An empty [prefix] yields the prompt unchanged. The original prompt is used
/// verbatim — composition never stacks, so repeated drops re-send a single
/// prefix rather than nesting them.
String composeInterruptRetry(String prefix, String prompt) =>
    prefix.isEmpty ? prompt : '$prefix\n\n$prompt';

/// The default reconnect back-off: retry after 10 s, 30 s, 60 s.
const List<Duration> defaultReconnectBackoff = [
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(seconds: 60),
];

/// How a reconnect attempt resolved.
enum ReconnectResolution {
  /// The bound port came back serving the **same** workspace: rebind
  /// silently and auto-resend the prefixed prompt.
  sameWorkspace,

  /// The bound port came back but serves a **different** workspace: bind +
  /// resend only after the user confirms.
  differentWorkspace,

  /// The bound port never answered across all back-offs: show the modal;
  /// fail only if the user chooses to.
  stillGone,
}

/// The outcome of [ReconnectCoordinator.reconnect].
final class ReconnectResult {
  const ReconnectResult(this.resolution, {this.server, required this.attempts});

  /// How the reconnect resolved.
  final ReconnectResolution resolution;

  /// The server found on the bound port, for [ReconnectResolution.sameWorkspace]
  /// and [ReconnectResolution.differentWorkspace]; `null` when still gone.
  final BridgeServer? server;

  /// How many back-off attempts ran before resolving (1-based for a server that
  /// came back; the full [defaultReconnectBackoff] length when still gone).
  final int attempts;

  @override
  String toString() =>
      'ReconnectResult(${resolution.name}, server: $server, attempts: $attempts)';
}

/// Delays for [duration] before the next rescan. Injected so tests run the
/// protocol instantly instead of waiting the real 10/30/60 s.
typedef ReconnectDelay = Future<void> Function(Duration duration);

/// Runs the reconnect back-off: after each delay it rescans the bridge
/// range and, the first time the bound port answers, classifies the result as
/// the same or a different workspace; if the port never answers it resolves
/// [ReconnectResolution.stillGone].
///
/// Pure protocol logic over an injectable [BridgeConnectionService] (the
/// rescan) and [ReconnectDelay] (the back-off). The UI side — the informational
/// popup, the still-gone modal, the different-workspace confirmation, and the
/// auto-resend — is the Flutter controller's concern.
final class ReconnectCoordinator {
  ReconnectCoordinator({
    required this.service,
    this.backoff = defaultReconnectBackoff,
    ReconnectDelay? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  /// The scan service used to rediscover the bound port.
  final BridgeConnectionService service;

  /// The per-attempt back-off durations.
  final List<Duration> backoff;

  final ReconnectDelay _delay;

  /// Attempts to recover the connection to [bound], whose window served
  /// [boundWorkspace] when it was bound.
  ///
  /// After each [backoff] delay it rescans; the first time a server answers on
  /// the bound port it resolves [ReconnectResolution.sameWorkspace] (or
  /// [ReconnectResolution.differentWorkspace] when the workspace name no longer
  /// matches a known [boundWorkspace]). A `null`/empty [boundWorkspace] (e.g. a
  /// binding restored from persistence, where only host+port are known) is
  /// treated as the same workspace — there is nothing to contradict it. If the
  /// port stays silent across every back-off it resolves
  /// [ReconnectResolution.stillGone].
  Future<ReconnectResult> reconnect({
    required BridgeChoice bound,
    String? boundWorkspace,
  }) async {
    for (var attempt = 0; attempt < backoff.length; attempt++) {
      await _delay(backoff[attempt]);
      final match = _serverOnPort(await _safeScan(), bound);
      if (match != null) {
        final sameWorkspace =
            boundWorkspace == null ||
            boundWorkspace.isEmpty ||
            match.workspace == boundWorkspace;
        return ReconnectResult(
          sameWorkspace
              ? ReconnectResolution.sameWorkspace
              : ReconnectResolution.differentWorkspace,
          server: match,
          attempts: attempt + 1,
        );
      }
    }
    return ReconnectResult(
      ReconnectResolution.stillGone,
      attempts: backoff.length,
    );
  }

  /// Rescans, swallowing scan failures as "no servers" so a transient scan
  /// error just becomes another silent attempt rather than aborting recovery.
  Future<List<BridgeServer>> _safeScan() async {
    try {
      return await service.scan();
    } catch (_) {
      return const [];
    }
  }

  /// The server answering on [bound]'s endpoint, or `null`.
  ///
  /// Matching is [BridgeChoice.matches], not string equality on the host: the
  /// binding and the scan can spell one loopback endpoint differently, and a
  /// textual match would then resolve [ReconnectResolution.stillGone] for a
  /// bridge that is up and answering.
  static BridgeServer? _serverOnPort(
    List<BridgeServer> servers,
    BridgeChoice bound,
  ) {
    for (final s in servers) {
      if (bound.matches(s)) return s;
    }
    return null;
  }
}

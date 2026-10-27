/// Startup transport selection and the availability gate.
///
///  makes `isAvailable` the single gate for every AI feature, and
/// requires that an unreachable backend produce **hidden or disabled
/// affordances, never a failing call**. Two consequences shape this class.
///
/// **The gate must be free to read.** The editor asks it on every rebuild — in
/// effect on every keystroke. So [isAvailable] is a plain field read: it never
/// probes, never connects, never logs, and never allocates. All the work
/// happens in [initialize] and [retry], which the app calls deliberately.
///
/// **The failure must be reported once.** A user whose VS Code is closed
/// should be told that once, not once per character typed. Notices are
/// therefore emitted on *state transitions* and on *explicit retries* only.
/// Reading the gate a million times in the unavailable state emits nothing.
library;

import 'dart:async';

import 'package:tom_llm/tom_llm.dart';

import 'transport/transport.dart';

/// Something about AI the shell should show **once**.
///
/// Two things arrive here and they are not the same fact. A transport that
/// could not be reached degrades the app, and the notice explains why every AI
/// affordance has gone. A transport that WAS reached can still have something
/// to say — today, that a workspace pin matched more than one VS Code window —
/// and nothing is degraded by it.
///
/// They share this type because they share the only thing the shell does with
/// them: show one sentence, once, and forget it. The shell already flattens
/// both to strings at its boundary, so a reader downstream could not act on the
/// distinction even if it were encoded here.
final class AgentSdkNotice {
  /// A user-facing explanation. Credential-free and content-free.
  final String message;

  const AgentSdkNotice(this.message);

  @override
  String toString() => 'AgentSdkNotice: $message';
}

/// Picks the transport to use and owns the availability verdict.
///
/// Candidates are tried **in order**, and the order is the meaningful part:
/// the hosted transport comes first because when VS Code is already running it
/// costs nothing and holds the credential itself, and the standalone transport
/// follows because starting a process is the fallback, not the default.
final class AgentSdkTransportSelector {
  /// The candidates, in preference order.
  final List<AgentSdkServerTransport> candidates;

  final StreamController<AgentSdkNotice> _notices =
      StreamController<AgentSdkNotice>.broadcast();

  AgentSdkServerTransport? _active;
  bool _reportedUnavailable = false;
  bool _reportedSelection = false;
  String? _unavailableReason;
  AgentSdkUnavailableKind? _unavailableKind;
  AgentSdkInstallableTransport? _installable;
  bool _installing = false;

  AgentSdkTransportSelector(this.candidates);

  /// The selected transport, or null when none is reachable.
  AgentSdkServerTransport? get active => _active;

  /// The availability gate. A field read — see the library doc for why that matters.
  bool get isAvailable => _active != null;

  /// Why the gate is shut, or null when it is open.
  ///
  /// **Retained, where the notice is consumed.** The notice exists to be shown
  /// once and then forgotten; this exists to be readable for as long as the
  /// condition lasts, because the affordance it explains is greyed out for
  /// exactly that long. A user who dismissed the snack bar — or who was not
  /// looking when it appeared — otherwise has a disabled button and no way
  /// back to the sentence.
  ///
  /// Also a field read, for the same reason [isAvailable] is: the surface that
  /// renders a disabled control asks on every rebuild.
  String? get unavailableReason => _unavailableReason;

  /// What kind of unavailable the gate is, or null when it is open.
  ///
  /// [AgentSdkUnavailableKind.notInstalled] is reported whenever **any**
  /// candidate is missing only its install, even when another candidate failed
  /// for a different reason first: of everything that is wrong, it is the one
  /// the app can fix itself, and it is the one the notice offers an action
  /// for. Otherwise a missing runtime outranks an unanswered server, for the
  /// same reason — it says what to install. A field read, like the gate.
  AgentSdkUnavailableKind? get unavailableKind => _unavailableKind;

  /// Whether a candidate is waiting for the user to install its server — the
  /// condition under which the availability notice offers Install. A field read.
  bool get needsInstall => _installable != null;

  /// Whether an [install] is running.
  bool get isInstalling => _installing;

  /// Installs the server of the candidate that reported
  /// [AgentSdkUnavailableKind.notInstalled], then retries selection, so a
  /// successful install opens the gate without a second action.
  ///
  /// Only ever called because the user asked (: the SDK is downloaded on
  /// the user's request, never on the app's initiative). Never throws; a
  /// second call while one runs answers a failure rather than starting two
  /// `npm ci`s into the same folder.
  Future<AgentSdkInstallOutcome> install({
    void Function(String line)? onProgress,
  }) async {
    final target = _installable;
    if (target == null) {
      return const AgentSdkInstallOutcome.failed(
        'no AI server is waiting to be installed',
      );
    }
    if (_installing) {
      return const AgentSdkInstallOutcome.failed(
        'an install is already running',
      );
    }
    _installing = true;
    try {
      final outcome = await target.install(onProgress: onProgress);
      if (outcome.ok) await retry();
      return outcome;
    } finally {
      _installing = false;
    }
  }

  /// Emits **once per unavailability episode**: when selection first fails,
  /// when a live transport drops, and on each explicit [retry] that fails.
  /// Never on a read of [isAvailable].
  Stream<AgentSdkNotice> get notices => _notices.stream;

  /// Probes and connects the first reachable candidate.
  ///
  /// Safe to call when nothing is reachable: that is the ordinary offline
  /// case, and it leaves the app fully usable with every AI affordance gated
  /// off. It does not throw.
  Future<void> initialize() async {
    // A root that configured no transports has not *failed* to reach one — it
    // ships without AI, which is a build decision and not an episode to report.
    // Saying "no AI server could be reached" here would be untrue, and it would
    // put a notice on every launch of a build that never intended to have one.
    // The gate is shut either way, which is all the gate has to say.
    if (candidates.isEmpty) {
      _active = null;
      // Said even though no notice is emitted: a build that ships without AI
      // owes the user an explanation for the greyed-out control, and "nothing
      // was configured" is a different fact from "nothing answered".
      _unavailableReason = llmNotConfiguredReason;
      _unavailableKind = AgentSdkUnavailableKind.notConfigured;
      _installable = null;
      return;
    }

    final failures = <String, String>{};
    final kinds = <AgentSdkUnavailableKind>{};
    AgentSdkInstallableTransport? installable;

    for (final candidate in candidates) {
      if (!await candidate.probe()) {
        // The transport's own reason when it has one. "Not reachable" is the
        // honest answer only when nothing more specific was recorded; a
        // missing Node runtime and a stopped CLI server are both "not
        // reachable" and neither is fixable from that sentence.
        failures[candidate.id] = candidate.unavailableReason ?? 'not reachable';
        final kind = candidate is AgentSdkInstallableTransport
            ? candidate.unavailableKind
            : null;
        kinds.add(kind ?? AgentSdkUnavailableKind.unreachable);
        if (kind == AgentSdkUnavailableKind.notInstalled) {
          installable ??= candidate as AgentSdkInstallableTransport;
        }
        continue;
      }
      try {
        await candidate.connect();
        // The connection proved the candidate; it is not the one runs use.
        // Every run is served from a session, which holds a
        // connection of its own, so this one is released rather than left
        // open — for the standalone transport that is a Node child nothing
        // would ever send a query to.
        await candidate.close();
        _active = candidate;
        _reportedUnavailable = false;
        _unavailableReason = null;
        _unavailableKind = null;
        _installable = null;
        _announce(candidate);
        return;
      } on LlmTransportException catch (e) {
        failures[candidate.id] = e.message;
        kinds.add(AgentSdkUnavailableKind.unreachable);
      } on Object catch (e) {
        failures[candidate.id] = e.toString();
        kinds.add(AgentSdkUnavailableKind.unreachable);
      }
    }

    _active = null;
    _installable = installable;
    _unavailableKind =
        [
          AgentSdkUnavailableKind.notInstalled,
          AgentSdkUnavailableKind.noRuntime,
          AgentSdkUnavailableKind.unreachable,
        ].firstWhere(
          kinds.contains,
          orElse: () => AgentSdkUnavailableKind.unreachable,
        );
    _report(failures);
  }

  /// An explicit, user-initiated retry. Unlike [initialize] this always
  /// reports its outcome, because the user asked and is waiting for an answer.
  Future<bool> retry() async {
    _reportedUnavailable = false;
    _reportedSelection = false;
    await initialize();
    return isAvailable;
  }

  /// Records that the active transport was lost mid-use.
  ///
  /// Called by the provider when a completion fails with
  /// [LlmErrorKind.unreachable] — the one error kind that means
  /// "the backend is gone" rather than "this request failed". The gate closes
  /// and exactly one notice is emitted, so the next thousand keystrokes see a
  /// disabled button and no further noise.
  void markLost(LlmTransportException error) {
    if (_active == null) return;
    final id = _active!.id;
    _active = null;
    _unavailableKind = AgentSdkUnavailableKind.unreachable;
    _installable = null;
    _report({id: error.message});
  }

  /// Closes every candidate, including ones never selected (a candidate that
  /// failed after starting a child process still has one to reap).
  Future<void> dispose() async {
    _active = null;
    for (final candidate in candidates) {
      try {
        await candidate.close();
      } on Object {
        // Shutdown is best-effort; a failed close must not mask the others.
      }
    }
    await _notices.close();
  }

  /// Passes on a working transport's [AgentSdkServerTransport.selectionNotice].
  ///
  /// Once per episode, exactly as a failure is. A transport with nothing to say
  /// **clears** the flag rather than leaving it set: the next time there is
  /// something to say it is a new fact, and a latched flag would swallow it.
  void _announce(AgentSdkServerTransport transport) {
    final notice = transport.selectionNotice;
    if (notice == null) {
      _reportedSelection = false;
      return;
    }
    if (_reportedSelection) return;
    _reportedSelection = true;
    _notices.add(AgentSdkNotice(notice));
  }

  void _report(Map<String, String> failures) {
    // Outside the once-per-episode guard, and deliberately: the *notice* is
    // rate-limited because it interrupts, and the *reason* is not because it
    // only answers when asked. A repeated failure that told the user nothing
    // new must still leave the current explanation current.
    _unavailableReason = _messageFor(failures);
    if (_reportedUnavailable) return;
    _reportedUnavailable = true;
    _notices.add(AgentSdkNotice(_messageFor(failures)));
  }

  /// The sentence a user is shown.
  ///
  /// The transports' reasons are the message, not a diagnostics appendix. "No
  /// AI server could be reached" is true of a missing Node runtime, an
  /// uninstalled server payload and an editor whose CLI server was never
  /// started — and it is actionable for none of them, which is the whole
  /// reason [AgentSdkServerTransport.unavailableReason] exists. A transport that
  /// recorded nothing still contributes its id, so the list never claims to be
  /// shorter than the set of things that were tried.
  static String _messageFor(Map<String, String> failures) {
    const lead = 'AI features are unavailable';
    if (failures.isEmpty) return '$lead: no AI server could be reached.';
    if (failures.length == 1) {
      // A reason is usually a sentence already; one full stop, not two.
      final reason = failures.values.single;
      final stop = RegExp(r'[.!?]$').hasMatch(reason) ? '' : '.';
      return '$lead: $reason$stop';
    }
    final lines = failures.entries
        .map((e) => '• ${e.key}: ${e.value}')
        .join('\n');
    return '$lead:\n$lines';
  }
}

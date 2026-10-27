/// One sync unit's state, and the status an application renders.
library;

import 'package:tom_core_storage/tom_core_storage.dart';

import 'conflict.dart';

/// A sync unit's position in the loop's state machine.
///
/// Four states, each answering a different question a user asks: *is my work
/// saved* ([clean] against [dirty]), *is something happening right now*
/// ([syncing]), and *does something need me* ([conflicted]).
enum TomSyncState {
  /// The working copy and the remote agree; nothing is pending.
  clean,

  /// There are local changes the remote does not have yet — including the
  /// offline case, where they are also journaled.
  dirty,

  /// A cycle is in flight. Edits are still accepted and re-dirty the unit.
  syncing,

  /// The last cycle settled at least one two-sided divergence and flagged it
  /// for review.
  ///
  /// Not a dead end: the unit is fully usable — the winner is live and the
  /// loser retained — and it returns to [clean] on the first clean cycle
  /// after the conflicts are cleared.
  conflicted,
}

/// A snapshot of one unit's sync situation.
class TomSyncStatus {
  /// The container the status is about.
  final String locator;

  /// Where the unit is in the state machine.
  final TomSyncState state;

  /// Journaled commits still awaiting delivery.
  final int pendingCount;

  /// Flagged conflicts awaiting review, in the order found.
  final List<TomSyncConflict> conflicts;

  /// Whether the last cycle failed to reach the transport.
  ///
  /// Distinct from [state]: an offline unit is dirty, but so is one that
  /// simply has unpushed edits, and an application says different things
  /// about the two.
  final bool offline;

  /// End of the last cycle that completed without a transport failure.
  final DateTime? lastSyncedAt;

  /// When the backend's quota is expected back, or null when the last cycle
  /// was not rate limited. A throttled remote is reachable and the work is
  /// not at risk, so this is not [offline].
  final DateTime? rateLimitedUntil;

  /// Which limit [rateLimitedUntil] belongs to, or null when nothing is
  /// limited. Carried beside the time rather than read off its length, which
  /// says nothing once a backend states its own wait.
  final TomRateLimitKind? rateLimitKind;

  /// Why the container did not open, or null when a key is not what is
  /// missing. A field rather than a state: a locked container changes neither
  /// whether the work is saved nor whether something needs the user — only
  /// what to say and what pressing the indicator should do. A sentence, never
  /// key material.
  final String? keyRequiredReason;

  /// Why the last cycle did not fully succeed, or null when it did.
  final Object? lastError;

  /// Why an offline commit could not be queued on this device, or null when
  /// it was or none was needed — the one state the journal exists to prevent,
  /// and so the one that must be said. A sentence, never the raw error.
  final String? unqueuedReason;

  /// How far the unit's push has got, or null when none is in flight.
  final TomCommitProgress? commitProgress;

  const TomSyncStatus({
    required this.locator,
    required this.state,
    required this.pendingCount,
    required this.conflicts,
    required this.offline,
    required this.lastSyncedAt,
    required this.lastError,
    this.rateLimitedUntil,
    this.rateLimitKind,
    this.keyRequiredReason,
    this.unqueuedReason,
    this.commitProgress,
  });

  /// Whether any conflict awaits review.
  bool get hasConflicts => conflicts.isNotEmpty;

  /// Whether the backend is refusing until [rateLimitedUntil].
  bool get isRateLimited => rateLimitedUntil != null;

  /// Whether the loop is blocked waiting for the container's key.
  bool get needsKey => keyRequiredReason != null;

  /// Whether offline work exists only in the open working copy.
  bool get isUnqueued => unqueuedReason != null;

  @override
  String toString() =>
      'TomSyncStatus($locator: ${state.name}'
      '${offline ? ', offline' : ''}'
      '${keyRequiredReason == null ? '' : ', key required'}'
      '${unqueuedReason == null ? '' : ', not queued'}'
      '${rateLimitedUntil == null ? '' : ', ${rateLimitKind?.name ?? 'rate'} '
                'limited until $rateLimitedUntil'}'
      '${pendingCount == 0 ? '' : ', $pendingCount pending'}'
      '${conflicts.isEmpty ? '' : ', ${conflicts.length} conflicts'})';
}

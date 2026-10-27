/// The conflict vocabulary a merge produces and a sync loop queues.
library;

/// A merge outcome that a person still has to look at.
///
/// Merges of unrelated record kinds produce conflicts of different shapes, and
/// converting one into another to share a queue would misstate what the merge
/// found. They share the one thing they have in common: the **anchor** a
/// person navigates to. That is enough for a sync engine to hold one queue per
/// unit and for an application to offer one review surface.
abstract interface class TomSyncConflict {
  /// The key the conflict is anchored on — the record a person opens to
  /// review it. Several conflicts may share an anchor.
  String get anchor;
}

/// Two divergent versions of one record, as a keyed merge found them.
///
/// Raised for two different edits of the same record, and — under
/// [TomDeleteEditPolicy.keepEditAndReport] — for an edit against a deletion.
/// [chosen] is the version the merge kept; [loser] is the one a caller retains
/// so both stay recoverable.
class TomMergeConflict<R> implements TomSyncConflict {
  /// The record's key.
  final String key;

  /// The common ancestor, or null when both sides added the record
  /// independently and there is none.
  final R? base;

  /// The local version, or null when the local side deleted the record.
  final R? ours;

  /// The remote version, or null when the remote side deleted the record.
  final R? theirs;

  /// The version the merge kept. Never a deletion: an edit always beats one.
  final R chosen;

  const TomMergeConflict({
    required this.key,
    required this.base,
    required this.ours,
    required this.theirs,
    required this.chosen,
  });

  @override
  String get anchor => key;

  /// Whether the local version is the one kept.
  bool get oursChosen => identical(chosen, ours);

  /// The version that did not survive, or null when the losing side was a
  /// deletion — a deletion has nothing to retain.
  R? get loser => oursChosen ? theirs : ours;

  @override
  String toString() =>
      'TomMergeConflict($key, ${oursChosen ? 'ours' : 'theirs'} kept)';
}

/// The persistent record of an unresolved conflict: the part that survives a
/// save, a close and a reopen.
///
/// A [TomMergeConflict] holds both sides, but only for as long as the process
/// does. What a later session cannot re-derive is **which record** is
/// unsettled and **where the losing version was retained**; everything else is
/// reachable from those two — the winner is the live record, and the loser is
/// read back out of history.
///
/// [loser] is the history store's own spelling of a location (a path in a file
/// medium, a history index in a record container), because different stores
/// address history differently and a common spelling would be one neither
/// uses.
class TomConflictRecord<R> implements TomSyncConflict {
  /// The key of the unsettled record.
  final String key;

  /// Where the losing version is retained, or null between the merge that
  /// produced the record and the save that stores the loser.
  ///
  /// A record read back from storage always has one, though it may no longer
  /// resolve; a reader keeps such a record rather than dropping it, because
  /// which record is unsettled is not re-derivable.
  String? loser;

  /// The losing version itself, or null when it is no longer reachable.
  ///
  /// Held beside [loser] rather than instead of it: it is what lets a save
  /// retain the loser in the first place, and what lets a record move between
  /// two kinds of history store without decaying into a locator neither can
  /// follow.
  R? retained;

  TomConflictRecord({required this.key, this.loser, this.retained});

  @override
  String get anchor => key;

  /// A copy whose [retained] version is copied with [copy].
  TomConflictRecord<R> copyWith(R Function(R) copy) => TomConflictRecord<R>(
    key: key,
    loser: loser,
    retained: retained == null ? null : copy(retained as R),
  );

  @override
  String toString() => 'TomConflictRecord($key, loser: ${loser ?? 'unstored'})';
}

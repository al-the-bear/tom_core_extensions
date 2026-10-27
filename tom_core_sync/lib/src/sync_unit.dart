/// What the sync loop converges: a unit, not a document.
library;

import 'package:tom_core_storage/tom_core_storage.dart';

import 'conflict.dart';

/// One container the loop keeps converged, on its own cadence.
///
/// The contract is transport-shaped rather than content-shaped: it names a
/// container, a revision, and the two halves of a cycle, and never the kind of
/// content inside. Implementations own their serialization and their merge;
/// the engine owns the state machine, the journal and the schedule — which is
/// what lets unrelated kinds of container share one loop, one conflict queue
/// and one status surface.
abstract interface class TomSyncUnit {
  /// The container this unit converges — the journal key, the status key and
  /// the key the scheduler batches head reads by.
  String get locator;

  /// The revision [locator] held when it was last read or written; null
  /// means the container does not exist yet.
  ///
  /// Settable because the journal drain commits outside [push] and records
  /// where it landed; nothing else writes it.
  String? head;

  /// Where [locator] lives.
  TomStorage get storage;

  /// Fires once per local change. The payload is nothing: the engine pushes
  /// the working copy, never an individual edit, so it needs to know only
  /// *that* something changed.
  Stream<void> get edits;

  /// Whether local work is waiting for a push.
  ///
  /// The one record of it: the engine reads this live and keeps no copy. A
  /// [push] must therefore clear exactly what it carried — a unit that stayed
  /// dirty after its work landed would cycle on every tick, and one that
  /// cleared an edit made while the push was in flight would never send it.
  bool get hasLocalChanges;

  /// Converges the working copy with the container as of [remoteHead], which
  /// the caller has established differs from [head].
  ///
  /// Answers the two-sided divergences a person should review; everything
  /// else the merge settles silently.
  Future<List<TomSyncConflict>> pull(String remoteHead);

  /// Publishes the working copy under compare-and-swap.
  ///
  /// Throws a `TomCasExhaustedException` when the container outran the retry
  /// budget and a `TomCommitFailedException` when the commit never reached
  /// the transport — the engine waits out the first and journals the second.
  Future<List<TomSyncConflict>> push();

  /// Releases what the unit holds.
  Future<void> dispose();
}

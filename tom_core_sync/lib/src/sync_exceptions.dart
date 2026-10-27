/// The two ways a compare-and-swap push can fail without the transport being
/// at fault for the content.
library;

import 'package:tom_core_storage/tom_core_storage.dart';

import 'conflict.dart';

/// The container moved on every commit attempt.
///
/// The merged working copy is intact in memory; a later cycle picks it up.
/// [conflicts] are what the attempts' merges reported, so they still reach the
/// unit's queue.
class TomCasExhaustedException extends TomStorageException {
  /// The conflicts the merges between attempts reported.
  final List<TomSyncConflict> conflicts;

  /// How many commits were attempted.
  final int attempts;

  TomCasExhaustedException(
    String locator, {
    required this.conflicts,
    required this.attempts,
  }) : super(
         locator,
         'The container moved on every one of $attempts commit attempts; '
         'the merged copy is intact in memory',
       );
}

/// The commit could not be attempted: the transport failed and the container
/// did not move.
///
/// The response is the opposite of a lost race — nothing to re-merge, nothing
/// to retry — so the work is journaled and tried again when the transport
/// returns. It carries [changeset] and [baseHead] because those two values are
/// the pending-commit record, and the layer that built the commit is the only
/// one holding both: re-deriving the changeset later is not possible when
/// building it advanced a counter.
class TomCommitFailedException extends TomStorageException {
  /// Exactly the write that did not land.
  final TomChangeset changeset;

  /// The head [changeset] was built against.
  final String? baseHead;

  /// The save counter [changeset] writes, or zero for a container that has
  /// none.
  final int version;

  /// The commit message the write was to carry.
  final String? commitMessage;

  TomCommitFailedException(
    String locator, {
    required this.changeset,
    required this.baseHead,
    required this.version,
    required this.commitMessage,
    required Object cause,
  }) : super(
         locator,
         'The commit could not be delivered; the changeset is intact and can '
         'be journaled',
         cause: cause,
       );
}

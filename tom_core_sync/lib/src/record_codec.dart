/// What the keyed merge needs to know about a record, and nothing more.
library;

import 'dart:typed_data';

/// How the keyed merge reads one kind of record.
///
/// A merge classifies each key by who changed it, which needs three facts and
/// no others: **which record** a value is ([idOf]), **when** it was last
/// changed ([modifiedOf], to pick a winner between two edits), and **whether
/// two versions are the same** ([canonicalBytes]). Everything else about a
/// record — its fields, its serialization, its place in a tree — is the
/// application's, which is what lets one merge serve unrelated record kinds.
abstract interface class TomRecordCodec<R> {
  /// The key the record is merged by. Stable across edits and devices.
  String idOf(R record);

  /// When the record was last changed, or null when it carries no stamp.
  ///
  /// Two edits with different stamps are settled by the newer one; two with
  /// equal or missing stamps by the merge's [TomMergeTie] rule.
  DateTime? modifiedOf(R record);

  /// The bytes two versions of the record are compared by.
  ///
  /// Two versions are the same exactly when these are equal, so the encoding
  /// must be canonical: the same content always yields the same bytes,
  /// whatever order it was built in. The merge also orders versions by these
  /// bytes when [TomMergeTie.canonicalOrder] settles a tie.
  Uint8List canonicalBytes(R record);
}

/// How a merge settles two different edits that carry the same stamp, or
/// none.
enum TomMergeTie {
  /// The local side wins. Two devices can then settle the same tie
  /// differently, which is acceptable when the result is checked by a person.
  ours,

  /// The version whose canonical bytes sort later wins, so every device
  /// merging the same three inputs settles the tie the same way.
  canonicalOrder,
}

/// What a merge does when one side deleted a record the other side edited.
enum TomDeleteEditPolicy {
  /// The edit stands and nothing is reported: the deleting side can delete
  /// again, a deletion has no state to retain, and there is nothing for a
  /// person to compare.
  keepEditSilently,

  /// The edit stands and the disagreement is reported as a conflict, for
  /// record kinds where a deletion is itself something a person should see.
  keepEditAndReport,
}

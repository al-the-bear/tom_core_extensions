/// The keyed three-way merge.
library;

import 'dart:typed_data';

import 'conflict.dart';
import 'record_codec.dart';

/// Two copies that are not copies of the same thing, refused before anything
/// was compared.
class TomMergeRefusedException implements Exception {
  /// What disagrees, as a sentence naming both values.
  final String reason;

  /// The container being merged into, when known.
  final String? location;

  const TomMergeRefusedException(this.reason, {this.location});

  /// The refusal as one sentence.
  String get message =>
      '${location == null ? 'The two copies' : 'The copy at $location and '
                'the one being merged'} are not the same document: $reason';

  @override
  String toString() => 'TomMergeRefusedException: $message';
}

/// What a keyed merge produced.
class TomKeyedMergeResult<R> {
  /// The merged records by key, in the order their keys were first seen in
  /// the ancestor, then the local side, then the remote side.
  final Map<String, R> merged;

  /// The disagreements the merge settled and reports, in the same order.
  final List<TomMergeConflict<R>> conflicts;

  const TomKeyedMergeResult({required this.merged, required this.conflicts});

  /// Each conflict's losing version by key, for a caller to retain in
  /// history. A conflict whose losing side was a deletion has nothing to
  /// retain and is absent.
  Map<String, R> get losers => {
    for (final c in conflicts)
      if (c.loser != null) c.key: c.loser as R,
  };
}

/// Merges two divergent copies of one keyed collection against their common
/// ancestor [base] — never line by line, always per key.
///
/// The ancestor is what keeps the result honest. Without it every key that
/// differs between the two sides looks like a conflict, including the ones
/// only one side touched, and a record one side deliberately deleted would be
/// resurrected by the other side's untouched copy. With it each key is
/// classified by who changed it, a deletion counting as a change in its own
/// right:
///
/// * neither side changed it, or only one did → that side stands, no
///   conflict;
/// * both changed it to the same thing (or both deleted it) → that, no
///   conflict;
/// * one side deleted it and the other edited it → the edit stands; reported
///   only under [TomDeleteEditPolicy.keepEditAndReport];
/// * both edited it differently → the newer stamp wins, a tie is settled by
///   [tie], and the conflict is reported with the loser on it.
///
/// [base] is required on purpose: a caller that cannot name the ancestor is
/// merging blind, and passing an empty map says so explicitly (everything
/// present is then "added by that side").
///
/// [formatVersions], when given, refuses copies written in different major
/// format versions — the number before the first dot of a `major.minor`
/// version — with a [TomMergeRefusedException] naming both versions and
/// [location], before any record is compared, so a refused merge has
/// classified nothing. Different minors merge.
TomKeyedMergeResult<R> tomMergeKeyed<R>({
  required Map<String, R> base,
  required Map<String, R> ours,
  required Map<String, R> theirs,
  required TomRecordCodec<R> codec,
  TomMergeTie tie = TomMergeTie.ours,
  TomDeleteEditPolicy deleteEdit = TomDeleteEditPolicy.keepEditSilently,
  ({String ours, String theirs})? formatVersions,
  String? location,
}) {
  if (formatVersions != null &&
      _major(formatVersions.ours) != _major(formatVersions.theirs)) {
    throw TomMergeRefusedException(
      'they are in different major format versions '
      '(${formatVersions.ours} and ${formatVersions.theirs}).',
      location: location,
    );
  }
  final bytes = Expando<Uint8List>();
  Uint8List canonical(R record) =>
      bytes[record as Object] ??= codec.canonicalBytes(record);
  bool same(R? a, R? b) {
    if (a == null || b == null) return a == null && b == null;
    return identical(a, b) || _equalBytes(canonical(a), canonical(b));
  }

  final merged = <String, R>{};
  final conflicts = <TomMergeConflict<R>>[];
  for (final key in {...base.keys, ...ours.keys, ...theirs.keys}) {
    final ancestor = base[key];
    final our = ours[key];
    final their = theirs[key];

    if (same(ancestor, their)) {
      // Only we touched it, or nobody did — ours being a deletion included.
      if (our != null) merged[key] = our;
      continue;
    }
    if (same(ancestor, our)) {
      if (their != null) merged[key] = their;
      continue;
    }
    if (same(our, their)) {
      // The same edit on both sides, or a deletion on both. No disagreement.
      if (our != null) merged[key] = our;
      continue;
    }
    if (our == null || their == null) {
      // One side deleted what the other edited: the edit stands. Checked
      // after the agreement case above, which keeps two deletions out.
      final edit = (our ?? their) as R;
      merged[key] = edit;
      if (deleteEdit == TomDeleteEditPolicy.keepEditAndReport) {
        conflicts.add(
          TomMergeConflict<R>(
            key: key,
            base: ancestor,
            ours: our,
            theirs: their,
            chosen: edit,
          ),
        );
      }
      continue;
    }
    final chosen = _winner(our, their, codec, tie, canonical);
    merged[key] = chosen;
    conflicts.add(
      TomMergeConflict<R>(
        key: key,
        base: ancestor,
        ours: our,
        theirs: their,
        chosen: chosen,
      ),
    );
  }
  return TomKeyedMergeResult<R>(merged: merged, conflicts: conflicts);
}

/// A conflict over a `(base, ours, theirs)` triple any caller holds, with
/// [TomMergeConflict.chosen] picked as [tomMergeKeyed] would pick it: an edit
/// beats a deletion, otherwise the newer stamp, otherwise [tie].
///
/// [ours] and [theirs] may not both be null: two sides that both deleted a
/// record agree, and that is no conflict.
TomMergeConflict<R> tomMergeConflictOf<R>({
  required String key,
  R? base,
  required R? ours,
  required R? theirs,
  required TomRecordCodec<R> codec,
  TomMergeTie tie = TomMergeTie.ours,
}) {
  if (ours == null && theirs == null) {
    throw ArgumentError(
      'Both sides deleted $key: they agree, so there is no conflict to show.',
    );
  }
  final R chosen;
  if (ours == null) {
    chosen = theirs as R;
  } else if (theirs == null) {
    chosen = ours;
  } else {
    chosen = _winner(ours, theirs, codec, tie, codec.canonicalBytes);
  }
  return TomMergeConflict<R>(
    key: key,
    base: base,
    ours: ours,
    theirs: theirs,
    chosen: chosen,
  );
}

/// The surviving version of two different edits: the newer stamp, else [tie].
R _winner<R>(
  R our,
  R their,
  TomRecordCodec<R> codec,
  TomMergeTie tie,
  Uint8List Function(R) canonical,
) {
  final ourStamp = codec.modifiedOf(our);
  final theirStamp = codec.modifiedOf(their);
  if (ourStamp != null && theirStamp != null && ourStamp != theirStamp) {
    return theirStamp.isAfter(ourStamp) ? their : our;
  }
  return switch (tie) {
    TomMergeTie.ours => our,
    TomMergeTie.canonicalOrder =>
      _compareBytes(canonical(their), canonical(our)) > 0 ? their : our,
  };
}

/// The major part of a `major.minor` version: everything before the first
/// dot.
String _major(String version) {
  final dot = version.indexOf('.');
  return (dot < 0 ? version : version.substring(0, dot)).trim();
}

bool _equalBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _compareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

/// Prior versions of keyed records, and how many of them are kept.
library;

import 'dart:async';

/// How many prior versions of a record a history store keeps by default.
///
/// One number for every store, because a record can move between two kinds of
/// container, and a retention that differed between them would lose versions
/// in one direction and not the other. It is bounded because on a remote
/// backend that reads a whole container, each retained version is paid for on
/// every open; twenty keeps a record recoverable across weeks of ordinary
/// editing while that cost stays proportional to the content.
const int tomHistoryDepth = 20;

/// Where prior versions of keyed records are retained.
///
/// [S] is how the store holds one version: the text of a file in a file
/// medium, a detached entry in a record container. A **locator** is the
/// store's own spelling of where a version is — a path, a history index — and
/// is what a [TomConflictRecord] keeps as its `loser`.
///
/// Methods answer [FutureOr] because the two kinds of store differ in kind: a
/// file medium is read and written asynchronously, while a record container
/// that is already in memory is written synchronously, inside a save that is
/// itself synchronous. An implementation declares the narrower type.
abstract interface class TomHistoryStore<S> {
  /// Retains [snapshot] as a prior version of [recordId] and answers its
  /// locator.
  FutureOr<String> retain(String recordId, S snapshot);

  /// Whether [locator] still names a retained version of [recordId].
  FutureOr<bool> holds(String recordId, String locator);

  /// The version [locator] names, or null when it is gone.
  FutureOr<S?> read(String recordId, String locator);

  /// The locators of [recordId]'s retained versions, oldest first.
  FutureOr<List<String>> versionsOf(String recordId);

  /// Drops all but the newest [depth] versions of every record, keeping each
  /// version [protected] names wherever it falls.
  ///
  /// [protected] maps a record id to the locator a conflict record points at;
  /// pruning one would turn a resolvable conflict into one whose losing side
  /// is gone. Answers the protected locators that **moved** — a store that
  /// addresses versions by position renumbers what it keeps — keyed by record
  /// id, so the caller re-points its records. A negative [depth] keeps
  /// everything.
  FutureOr<Map<String, String>> prune({
    int depth = tomHistoryDepth,
    Map<String, String> protected = const {},
  });
}

/// The history file-name stamp for [time]: `yyyyMMddTHHmmssSSS`, in UTC.
///
/// Lexicographic order of these stamps is chronological order, which is what
/// lets a file-medium store sort versions by name.
String tomHistoryStamp(DateTime time) {
  final t = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${t.year}${two(t.month)}${two(t.day)}'
      'T${two(t.hour)}${two(t.minute)}${two(t.second)}'
      '${three(t.millisecond)}';
}

// Symlink-aware (I/O-backed) containment for [PathScope].
//
// [PathScope] itself is deliberately *lexical* and pure: it normalises `..`
// and absolute segments with `package:path` only, never touching the
// filesystem, so it stays web-safe and its result is stable on paths that do
// not (yet) exist. That lexical rule is correct for the common case but blind
// to one real escape: a **symlink** inside a root whose target points *outside*
// every root. Lexically the link's path is contained; following it is not.
//
// This extension adds the I/O-backed counterpart. It resolves filesystem
// symlinks on the candidate's existing prefix before the containment check, so
// a link that escapes its root is rejected. It lives in a
// separate, `dart:io`-importing file so the pure lexical [PathScope] API does
// not drag `dart:io` into web builds — callers opt into the filesystem-aware
// check explicitly by importing/using these methods.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_scope.dart';

/// Filesystem-aware containment for [PathScope], resolving symlinks so a link
/// that points outside its root cannot slip past the lexical check.
extension PathScopeIo on PathScope {
  /// Like [PathScope.resolve], but canonicalises the candidate through the
  /// filesystem first — following any symlinks on its existing prefix — so a
  /// path that *lexically* sits inside a root but *physically* resolves outside
  /// it (a symlink escape) is dropped.
  ///
  /// Each root is itself canonicalised before comparison, so a root that is (or
  /// lives under) a symlink is handled consistently. A non-existent candidate
  /// falls back to its nearest existing ancestor's real path plus the remaining
  /// lexical segments, so containment still holds for paths about to be created.
  List<ScopedPath> resolveCanonical(String relative) {
    final hits = <ScopedPath>[];
    for (final root in roots) {
      final canonicalRoot = _canonicalize(root);
      final candidate = p.normalize(p.join(root, relative));
      final real = _canonicalize(candidate);
      if (real == canonicalRoot || p.isWithin(canonicalRoot, real)) {
        hits.add((root: root, path: real));
      }
    }
    return hits;
  }

  /// Whether [relative] stays within at least one root once symlinks are
  /// resolved — the filesystem-aware counterpart of [PathScope.admits].
  bool admitsCanonical(String relative) =>
      resolveCanonical(relative).isNotEmpty;

  /// Resolves symlinks on the longest existing prefix of [path] and re-appends
  /// the non-existent tail. Equivalent to `resolveSymbolicLinksSync` for a path
  /// that exists, but defined (no throw) for one that does not yet.
  String _canonicalize(String path) {
    final normalized = p.normalize(p.absolute(path));
    var existing = normalized;
    final tail = <String>[];
    while (FileSystemEntity.typeSync(existing, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      if (parent == existing) return normalized; // nothing on this path exists
      tail.insert(0, p.basename(existing));
      existing = parent;
    }
    final real = File(existing).resolveSymbolicLinksSync();
    return tail.isEmpty ? real : p.normalize(p.join(real, p.joinAll(tail)));
  }
}

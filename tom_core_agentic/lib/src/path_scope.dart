// Domain-free file-scope path containment.
//
// Sandboxed agent runtimes confine filesystem access to a set of roots: a
// relative path the agent supplies is only allowed when it resolves inside one
// of them. The normalisation-and-containment rule is identical everywhere — the
// only thing that differs is what each runtime does on a breach (the brain
// raises a wire-coded `FileScopeViolation`; another runtime might return an
// error value). [PathScope] owns the rule; the breach policy stays with the
// caller, so the containment logic is written once.

import 'package:path/path.dart' as p;

/// A root that admits a resolved path, paired with that resolved path.
///
/// `root` is the normalised, absolute root (so callers can rebase a match
/// back onto it); `path` is the resolved, containment-checked absolute path
/// under that root. Both are record fields, which dartdoc cannot link.
typedef ScopedPath = ({String root, String path});

/// A union of filesystem roots a path must stay within.
///
/// Construction normalises every root to an absolute, canonical form. A path is
/// *in scope* when, after normalisation, it lands inside at least one root —
/// roots form a union, not an intersection. A `..` segment, an absolute path,
/// or any other escape simply drops out of the roots it leaves; only a path
/// that escapes *every* root is fully out of scope.
///
/// ## Lexical only — symlinks are NOT followed
///
/// [resolve] and [admits] are **purely lexical**: they normalise `..` and
/// absolute segments with `package:path` and never touch the filesystem. This
/// keeps the type web-safe and its answer stable on paths that do not yet
/// exist — but it means a **symlink inside a root whose target points outside
/// every root is admitted** (lexically the link's path is contained; following
/// it is not). When the scope guards real filesystem access against untrusted
/// input, use the filesystem-aware `resolveCanonical` / `admitsCanonical`
/// (extension `PathScopeIo` in `path_scope_io.dart`), which resolve symlinks
/// before the containment check and reject such an escape.
final class PathScope {
  /// The normalised, absolute roots, in their configured priority order.
  final List<String> roots;

  /// Builds a scope over [roots]. Each is normalised to `normalize(absolute(r))`.
  ///
  /// Throws [ArgumentError] when [roots] is empty — a scope with no roots admits
  /// nothing and is always a configuration mistake.
  PathScope(Iterable<String> roots)
    : roots = List<String>.unmodifiable(
        roots.map((r) => p.normalize(p.absolute(r))),
      ) {
    if (this.roots.isEmpty) {
      throw ArgumentError.value(roots, 'roots', 'must not be empty');
    }
  }

  /// Resolves [relative] against every root, returning one [ScopedPath] per root
  /// whose bounds the resolved path stays within.
  ///
  /// Hits keep the roots' configured order, so the first hit is the
  /// earliest-priority root that admits the path (the write target, the first
  /// read candidate). An empty result means the path escaped every root.
  ///
  /// **Lexical only** — does not follow symlinks; see the class doc and
  /// `resolveCanonical` (extension `PathScopeIo`) for the symlink-safe variant.
  List<ScopedPath> resolve(String relative) {
    final hits = <ScopedPath>[];
    for (final root in roots) {
      final candidate = p.normalize(p.join(root, relative));
      if (candidate == root || p.isWithin(root, candidate)) {
        hits.add((root: root, path: candidate));
      }
    }
    return hits;
  }

  /// Whether [relative] stays within at least one root.
  ///
  /// **Lexical only** — does not follow symlinks; use `admitsCanonical`
  /// (extension `PathScopeIo`) to reject a symlink that escapes its root.
  bool admits(String relative) => resolve(relative).isNotEmpty;
}

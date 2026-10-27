/// History in a keyed file medium: one file per retained version.
library;

import 'package:tom_core_storage/tom_core_storage.dart';

import 'history_store.dart';

/// Retains prior versions of records as files under [directory] of a
/// [TomBundleMedium]: `<directory>/<recordId>/<stamp><extension>`.
///
/// The locator of a version is its path, which removing a sibling does not
/// change — so [prune] never has a locator to re-point. One instance serves
/// one save: every version it retains carries the same [stamp], and a second
/// version of the same record within that save is disambiguated with a `_1`,
/// `_2`… suffix, which sorts after the bare stamp in the order the files were
/// written.
class TomMediumHistoryStore implements TomHistoryStore<String> {
  /// The medium the files live in.
  final TomBundleMedium medium;

  /// The folder every record's history folder sits in.
  final String directory;

  /// The file extension of a retained version, dot included.
  final String extension;

  /// The stamp this save names its versions with ([tomHistoryStamp]).
  final String stamp;

  /// Paths under [directory] that are not record history — another layout's
  /// files that share the folder — and that [prune] leaves alone.
  final bool Function(String path)? exclude;

  const TomMediumHistoryStore({
    required this.medium,
    required this.stamp,
    this.directory = '.history',
    this.extension = '.yaml',
    this.exclude,
  });

  /// Whether [path] lies inside [directory].
  bool isHistoryPath(String path) => path.startsWith('$directory/');

  @override
  Future<String> retain(String recordId, String snapshot) async {
    var path = '$directory/$recordId/$stamp$extension';
    var counter = 1;
    while (await medium.exists(path)) {
      path = '$directory/$recordId/${stamp}_$counter$extension';
      counter++;
    }
    await medium.writeString(path, snapshot);
    return path;
  }

  @override
  Future<bool> holds(String recordId, String locator) async =>
      locator.startsWith('$directory/$recordId/') &&
      await medium.exists(locator);

  @override
  Future<String?> read(String recordId, String locator) async =>
      await holds(recordId, locator) ? medium.readString(locator) : null;

  @override
  Future<List<String>> versionsOf(String recordId) async =>
      (await medium.listFiles())
          .where((path) => path.startsWith('$directory/$recordId/'))
          .toList()
        ..sort();

  /// Walks [directory] itself rather than a list of live records, because a
  /// deleted record keeps its versions and has no live entry to be reached
  /// through — and a deletion is exactly when history stops growing and
  /// starts sitting there for ever.
  @override
  Future<Map<String, String>> prune({
    int depth = tomHistoryDepth,
    Map<String, String> protected = const {},
  }) async {
    if (depth < 0) return const {};
    final kept = protected.values.toSet();
    final byRecord = <String, List<String>>{};
    for (final path in await medium.listFiles()) {
      if (!isHistoryPath(path)) continue;
      if (exclude?.call(path) ?? false) continue;
      final rest = path.substring(directory.length + 1);
      final slash = rest.indexOf('/');
      if (slash <= 0) continue;
      byRecord.putIfAbsent(rest.substring(0, slash), () => []).add(path);
    }
    for (final paths in byRecord.values) {
      paths.sort();
      final surplus = paths.length - depth;
      if (surplus <= 0) continue;
      for (final path in paths.take(surplus)) {
        if (kept.contains(path)) continue;
        await medium.delete(path);
      }
    }
    return const {};
  }
}

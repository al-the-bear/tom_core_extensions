/// The guard that keeps this package `dart format`-clean.
///
/// The sweep, its checks and the reasons for them live once, in
/// `tool/package_format_guard.dart`, shared by every package under
/// `tom_ai/core`. This file only describes the package: the fewest files a
/// correct walk of it finds, the directories the walk must reach, and whether
/// it commits generated output. When it fails, run `dart format .` here.
library;

import 'package:test/test.dart';

import '../../../core/tool/package_format_guard.dart';

void main() {
  group('the package is formatted', () {
    final sweep = PackageFormatSweep(
      minimumFiles: 100,
      landmarks: const ['lib', 'example', 'test'],
      hasGeneratedOutput: false,
    );

    test(
      'every file it authors survives `dart format` unchanged',
      () async => expect(await sweep.unformatted(), isNull),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('the sweep is reading the files it claims to check', () {
      expect(sweep.coverageProblems(), isEmpty);
    });

    test('it excludes generated output rather than silently missing it', () {
      expect(sweep.exclusionProblems(), isEmpty);
    });
  });
}

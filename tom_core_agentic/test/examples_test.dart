/// Runs every shipped example, under exactly the command its own header
/// documents.
///
/// **The defect this exists for.** These examples verify themselves with
/// `assert` — every check in every file — and `dart run` leaves assertions
/// *disabled*, which is what its `--enable-asserts` flag is for. Under a
/// flagless run every one of them compiles out, so the example prints a
/// plausible transcript and exits 0 whether or not anything it claims is true.
/// The headers do name the flag; nothing checked that they still do, and
/// nothing ran the examples at all, so a header edited to drop it — or an
/// example that stopped working — would have been invisible.
///
/// Two properties, because either alone is satisfiable by a broken package: the
/// examples must pass, and the command a reader is told to use must be the one
/// under which they were made to pass. A sweep that runs them with a flag the
/// header does not mention proves nothing about what a reader will see.
///
/// `tom_core_server` answers the same question the other way — its examples
/// state expectations through a helper that *throws*, so its documented command
/// needs no flag. Both are sound; what is not sound is documenting one and
/// verifying the other.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The flag without which an `assert` in an example is not evaluated.
const String _assertsFlag = '--enable-asserts';

/// Every example program this package ships, sorted for a stable report.
///
/// Derived by walking `example/` rather than from a list, so an example added
/// later is run the day it appears rather than the day someone remembers to
/// widen this.
List<File> _examples() {
  final files = Directory('example')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('_example.dart'))
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

void main() {
  final examples = _examples();

  group('every example is run under the command it documents', () {
    test('the sweep found the examples it claims to check', () {
      // One assertion over a directory walk runs nothing when the walk finds
      // nothing, and reports a clean package it never opened. Stated as a floor
      // rather than an exact count, because the count is supposed to grow.
      expect(
        examples.length,
        greaterThanOrEqualTo(4),
        reason: 'the walk of example/ found ${examples.length} programs',
      );
    });

    for (final example in examples) {
      final path = example.path;

      test('$path documents $_assertsFlag', () {
        // The header is the one instruction a reader is certain to follow. An
        // example that checks itself with `assert` and documents a flagless
        // `dart run` is telling the reader to run it with its checks removed.
        expect(
          example.readAsStringSync(),
          contains('dart run $_assertsFlag $path'),
          reason:
              '$path checks itself with assert, so its header must name the '
              'exact command that evaluates those asserts',
        );
      });

      test('$path runs green under it', () async {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          _assertsFlag,
          path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: 'example failed: ${result.stdout}${result.stderr}',
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test(
        '$path refuses to run without it',
        () async {
          // The other half. The run above keeps the example honest; it does
          // nothing for a reader who runs it from memory without the flag, and
          // under a flagless run every assert compiles out, so the example would
          // print its transcript and exit 0 having verified nothing. It must
          // refuse instead, loudly and with the fix in the message.
          final result = await Process.run(Platform.resolvedExecutable, [
            'run',
            path,
          ]);
          expect(
            result.exitCode,
            2,
            reason:
                '$path ran without $_assertsFlag and did not refuse: '
                '${result.stdout}${result.stderr}',
          );
          expect(result.stderr, contains(_assertsFlag));
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}

/// The executable the transport suites spawn where a Node runtime would go.
///
/// It only has to exist, start, and behave predictably, so a Dart CLI serves —
/// but it has to *be* a Dart CLI. This package's suites run under `dart test`,
/// where the runner is that CLI; under another runner (`flutter_tester`) the
/// transports would fail at once with "no Node.js runtime", a diagnosis about
/// the wrong thing, so a wrong runner fails here naming itself instead.
library;

import 'dart:io';

/// Resolved on first use, so a wrong runner fails the test that needed it
/// rather than failing the file at load.
final String standInExecutable = _dartCli();

String _dartCli() {
  final executable = Platform.resolvedExecutable;
  final name = executable.split(Platform.pathSeparator).last;
  if (name == 'dart' || name == 'dart.exe') return executable;
  throw StateError(
    'run this suite with `dart test`: the stand-in for the Node runtime the '
    'AI transports spawn is the Dart CLI, and this runner is "$name"',
  );
}

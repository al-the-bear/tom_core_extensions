/// Finding a Node ≥ 20 to run the shipped server with.
///
/// Shared because two suites need it for opposite reasons: the live suite runs
/// the server out of the **source** tree, and the packaging suite runs it out
/// of a **bundled payload**. Both need the same answer to the same question,
/// and a second copy of this search would be a second place for the nvm
/// fallback to be forgotten.
library;

import 'dart:io';

import '../transport/standalone_transport.dart';

/// Overrides the search with an explicit interpreter.
const agentSdkNodeEnvVar = 'AGENT_SDK_NODE';

/// A Node ≥ [requiredNodeMajorVersion], or null when the machine has none.
///
/// `node` on `PATH` is often an older default, so an nvm install is consulted
/// before giving up: the point is to run the real server on every machine that
/// *can* run it, not to make a developer re-shim their shell first.
String? findNodeForTests() {
  final candidates = <String>[
    if (Platform.environment[agentSdkNodeEnvVar] case final n?
        when n.isNotEmpty)
      n,
    'node',
    ..._nvmCandidates(),
  ];

  for (final candidate in candidates) {
    if (_majorVersionOf(candidate) case final major?
        when major >= requiredNodeMajorVersion) {
      return candidate;
    }
  }
  return null;
}

/// Every nvm-installed interpreter that clears the floor, newest first.
List<String> _nvmCandidates() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return const [];
  final nvm = Directory('$home/.nvm/versions/node');
  if (!nvm.existsSync()) return const [];

  final versions =
      nvm
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .where(
            (v) =>
                (int.tryParse(v.replaceFirst('v', '').split('.').first) ?? 0) >=
                requiredNodeMajorVersion,
          )
          .toList()
        ..sort();
  return versions.reversed.map((v) => '${nvm.path}/$v/bin/node').toList();
}

/// The major version [executable] reports, or null when it cannot be run.
int? _majorVersionOf(String executable) {
  final ProcessResult result;
  try {
    result = Process.runSync(executable, const ['--version']);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) return null;
  return int.tryParse(
    (result.stdout as String).trim().replaceFirst('v', '').split('.').first,
  );
}

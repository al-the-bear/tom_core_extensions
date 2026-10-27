// Persistence for the timed/scheduled-request set.
//
// Timed requests (interval or scheduled prompts) are editor configuration held
// in the spec workspace as a YAML file. Mirrors [ChatVariableStore]: written
// synchronously on every change, degrading rather than throwing when the file
// is damaged — see `agent_sidecar.dart`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'timed_request.dart';

/// Loads/saves the timed-request set (`List<TimedRequest>`) as YAML.
final class TimedRequestStore {
  TimedRequestStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the timed-requests file. Honors `TOM_SPECS_TIMED_FILE`; falls
  /// back to `<cwd>/.tom/timed_requests.yaml`.
  factory TimedRequestStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_TIMED_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'timed_requests.yaml');
    return TimedRequestStore(File(path));
  }

  /// Loads the persisted requests, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  List<TimedRequest> load() => decodeAgentYamlList(
    readAgentYamlFile(file),
    key: 'requests',
    identity: 'id',
    fromYaml: TimedRequest.fromYaml,
  );

  /// Persists [requests], creating the parent directory if needed.
  void save(List<TimedRequest> requests) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'requests': [for (final request in requests) request.toYaml()],
    });
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }
}

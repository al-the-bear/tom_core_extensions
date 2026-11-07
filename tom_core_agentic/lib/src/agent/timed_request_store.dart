// Persistence for the timed/scheduled-request set.
//
// Timed requests (interval or scheduled prompts) are editor configuration held
// in the spec workspace as a YAML file. Mirrors [ChatVariableStore]: written
// on every change, degrading rather than throwing when the file
// is damaged — see `agent_sidecar.dart`.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'timed_request.dart';

/// Loads/saves the timed-request set (`List<TimedRequest>`) as YAML.
final class TimedRequestStore extends AgentSidecarStore {
  TimedRequestStore({required super.fileSystem, required super.uri});

  /// Resolves the timed-requests file. Honors `TOM_SPECS_TIMED_FILE`; falls
  /// back to `.tom/timed_requests.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory TimedRequestStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => TimedRequestStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_TIMED_FILE',
      defaultPath: '.tom/timed_requests.yaml',
    ),
  );

  /// Loads the persisted requests, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<TimedRequest>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'requests',
    identity: 'id',
    fromYaml: TimedRequest.fromYaml,
  );

  /// Persists [requests], making its folder when it is missing.
  Future<void> save(List<TimedRequest> requests) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'requests': [for (final request in requests) request.toYaml()],
    });
    return writeText(yaml);
  }
}

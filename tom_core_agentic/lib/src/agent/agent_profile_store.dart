// Persistence for the Anthropic agent-profile set.
//
// Profiles are editor configuration held in the spec workspace as a YAML file
// so the user's personas survive launches. Mirrors [ChatVariableStore]: a small
// YAML file written on every change, degrading rather than
// throwing when the file is damaged — see `agent_sidecar.dart`.
//
// Held **out of** the document `*.docspecs.yaml` pass — profiles are editor
// configuration, not specification content.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_profile.dart';
import 'agent_sidecar.dart';
import 'agent_yaml.dart';

/// Loads/saves the agent-profile set (`List<AgentProfile>`) as YAML.
final class AgentProfileStore extends AgentSidecarStore {
  AgentProfileStore({required super.fileSystem, required super.uri});

  /// Resolves the profiles file. Honors `TOM_SPECS_PROFILES_FILE`; falls back
  /// to `.tom/agent_profiles.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory AgentProfileStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => AgentProfileStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_PROFILES_FILE',
      defaultPath: '.tom/agent_profiles.yaml',
    ),
  );

  /// Loads the persisted profiles, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<AgentProfile>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'profiles',
    identity: 'id',
    fromYaml: AgentProfile.fromYaml,
  );

  /// Persists [profiles], making its folder when it is missing.
  Future<void> save(List<AgentProfile> profiles) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'profiles': [for (final profile in profiles) profile.toYaml()],
    });
    return writeText(yaml);
  }
}

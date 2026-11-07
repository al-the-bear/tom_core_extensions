// Persistence for the singleton [AgentSettings].
//
// Unlike the list stores, this holds exactly one value. Mirrors
// [ChatVariableStore]'s error handling: a missing/malformed file yields the
// defaults rather than throwing.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_settings.dart';
import 'agent_sidecar.dart';
import 'agent_yaml.dart';

/// Loads/saves the singleton [AgentSettings] as YAML.
final class AgentSettingsStore extends AgentSidecarStore {
  AgentSettingsStore({required super.fileSystem, required super.uri});

  /// Resolves the agent-settings file. Honors `TOM_SPECS_AGENT_SETTINGS_FILE`;
  /// falls back to `.tom/agent_settings.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory AgentSettingsStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => AgentSettingsStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_AGENT_SETTINGS_FILE',
      defaultPath: '.tom/agent_settings.yaml',
    ),
  );

  /// Loads the persisted settings, or the defaults when the file is missing,
  /// unreadable, malformed or shaped unlike [AgentSettings].
  Future<AgentSettings> load() async => decodeAgentYamlValue(
    await readRoot(),
    key: 'settings',
    fromYaml: AgentSettings.fromYaml,
    orElse: const AgentSettings(),
  );

  /// Persists [settings], making its folder when it is missing.
  Future<void> save(AgentSettings settings) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'settings': settings.toYaml(),
    });
    return writeText(yaml);
  }
}

// Persistence for the singleton [AgentSettings].
//
// Unlike the list stores, this holds exactly one value. Mirrors
// [ChatVariableStore]'s error handling: a missing/malformed file yields the
// defaults rather than throwing.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_settings.dart';
import 'agent_sidecar.dart';
import 'agent_yaml.dart';

/// Loads/saves the singleton [AgentSettings] as YAML.
final class AgentSettingsStore {
  AgentSettingsStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the agent-settings file. Honors `TOM_SPECS_AGENT_SETTINGS_FILE`;
  /// falls back to `<cwd>/.tom/agent_settings.yaml`.
  factory AgentSettingsStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_AGENT_SETTINGS_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'agent_settings.yaml');
    return AgentSettingsStore(File(path));
  }

  /// Loads the persisted settings, or the defaults when the file is missing,
  /// unreadable, malformed or shaped unlike [AgentSettings].
  AgentSettings load() => decodeAgentYamlValue(
    readAgentYamlFile(file),
    key: 'settings',
    fromYaml: AgentSettings.fromYaml,
    orElse: const AgentSettings(),
  );

  /// Persists [settings], creating the parent directory if needed.
  void save(AgentSettings settings) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'settings': settings.toYaml(),
    });
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }
}

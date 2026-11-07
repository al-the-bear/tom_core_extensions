// Persistence for the saved queue-template set.
//
// Queue templates (named, ordered prompt sets that seed the queue) are editor
// configuration held in the spec workspace as a YAML file. Mirrors
// [ChatVariableStore]: written on every change, degrading rather
// than throwing when the file is damaged — see `agent_sidecar.dart`.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'queue_template.dart';

/// Loads/saves the queue-template set (`List<QueueTemplate>`) as YAML.
final class QueueTemplateStore extends AgentSidecarStore {
  QueueTemplateStore({required super.fileSystem, required super.uri});

  /// Resolves the queue-templates file. Honors `TOM_SPECS_QUEUE_TEMPLATES_FILE`;
  /// falls back to `.tom/queue_templates.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory QueueTemplateStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => QueueTemplateStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_QUEUE_TEMPLATES_FILE',
      defaultPath: '.tom/queue_templates.yaml',
    ),
  );

  /// Loads the persisted templates, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<QueueTemplate>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'templates',
    identity: 'id',
    fromYaml: QueueTemplate.fromYaml,
  );

  /// Persists [templates], making its folder when it is missing.
  Future<void> save(List<QueueTemplate> templates) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'templates': [for (final template in templates) template.toYaml()],
    });
    return writeText(yaml);
  }
}

// Persistence for the reusable prompt-template set.
//
// Prompt templates (user-message seeds + reusable prompt bodies) are editor
// configuration held in the spec workspace as a YAML file. Mirrors
// [ChatVariableStore]: written on every change, degrading rather
// than throwing when the file is damaged — see `agent_sidecar.dart`.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'prompt_template.dart';

/// Loads/saves the prompt-template set (`List<PromptTemplate>`) as YAML.
final class PromptTemplateStore extends AgentSidecarStore {
  PromptTemplateStore({required super.fileSystem, required super.uri});

  /// Resolves the prompt-templates file. Honors `TOM_SPECS_PROMPT_TEMPLATES_FILE`;
  /// falls back to `.tom/prompt_templates.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory PromptTemplateStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => PromptTemplateStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_PROMPT_TEMPLATES_FILE',
      defaultPath: '.tom/prompt_templates.yaml',
    ),
  );

  /// Loads the persisted templates, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<PromptTemplate>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'templates',
    identity: 'id',
    fromYaml: PromptTemplate.fromYaml,
  );

  /// Persists [templates], making its folder when it is missing.
  Future<void> save(List<PromptTemplate> templates) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'templates': [for (final template in templates) template.toYaml()],
    });
    return writeText(yaml);
  }
}

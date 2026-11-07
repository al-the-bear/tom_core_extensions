// Persistence for the chat-variable set.
//
// Custom chat variables are held in the spec workspace as a YAML file so the
// user's bindings survive launches. Mirrors [PromptQueueStore]: a small YAML
// file written on every change, degrading rather than throwing
// when the file is damaged — see `agent_sidecar.dart`. Built-in variables are
// supplied by the composer at resolution time and are never written here.
//
// Held **out of** the document `*.docspecs.yaml` pass — chat variables are
// editor configuration, not specification content.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'chat_variable.dart';

/// Loads/saves the custom chat-variable set (`List<ChatVariable>`) as YAML.
final class ChatVariableStore extends AgentSidecarStore {
  ChatVariableStore({required super.fileSystem, required super.uri});

  /// Resolves the chat-variables file. Honors `TOM_SPECS_CHATVARS_FILE`; falls
  /// back to `.tom/chat_variables.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory ChatVariableStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => ChatVariableStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_CHATVARS_FILE',
      defaultPath: '.tom/chat_variables.yaml',
    ),
  );

  /// Loads the persisted variables, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<ChatVariable>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'variables',
    identity: 'name',
    fromYaml: ChatVariable.fromYaml,
  );

  /// Persists [variables], making its folder when it is missing. Built-in
  /// variables are dropped — only user-authored variables are written.
  Future<void> save(List<ChatVariable> variables) {
    final custom = variables.where((v) => !v.builtIn);
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'variables': [for (final variable in custom) variable.toYaml()],
    });
    return writeText(yaml);
  }
}

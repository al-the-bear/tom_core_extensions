// Persistence for the chat-variable set.
//
// Custom chat variables are held in the spec workspace as a YAML file so the
// user's bindings survive launches. Mirrors [PromptQueueStore]: a small YAML
// file written synchronously on every change, degrading rather than throwing
// when the file is damaged — see `agent_sidecar.dart`. Built-in variables are
// supplied by the composer at resolution time and are never written here.
//
// Held **out of** the document `*.docspecs.yaml` pass — chat variables are
// editor configuration, not specification content.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'chat_variable.dart';

/// Loads/saves the custom chat-variable set (`List<ChatVariable>`) as YAML.
final class ChatVariableStore {
  ChatVariableStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the chat-variables file. Honors `TOM_SPECS_CHATVARS_FILE`; falls
  /// back to `<cwd>/.tom/chat_variables.yaml`.
  factory ChatVariableStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_CHATVARS_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'chat_variables.yaml');
    return ChatVariableStore(File(path));
  }

  /// Loads the persisted variables, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  List<ChatVariable> load() => decodeAgentYamlList(
    readAgentYamlFile(file),
    key: 'variables',
    identity: 'name',
    fromYaml: ChatVariable.fromYaml,
  );

  /// Persists [variables], creating the parent directory if needed. Built-in
  /// variables are dropped — only user-authored variables are written.
  void save(List<ChatVariable> variables) {
    final custom = variables.where((v) => !v.builtIn);
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'variables': [for (final variable in custom) variable.toYaml()],
    });
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }
}

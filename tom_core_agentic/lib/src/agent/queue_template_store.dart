// Persistence for the saved queue-template set.
//
// Queue templates (named, ordered prompt sets that seed the queue) are editor
// configuration held in the spec workspace as a YAML file. Mirrors
// [ChatVariableStore]: written synchronously on every change, degrading rather
// than throwing when the file is damaged — see `agent_sidecar.dart`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'queue_template.dart';

/// Loads/saves the queue-template set (`List<QueueTemplate>`) as YAML.
final class QueueTemplateStore {
  QueueTemplateStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the queue-templates file. Honors `TOM_SPECS_QUEUE_TEMPLATES_FILE`;
  /// falls back to `<cwd>/.tom/queue_templates.yaml`.
  factory QueueTemplateStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_QUEUE_TEMPLATES_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'queue_templates.yaml');
    return QueueTemplateStore(File(path));
  }

  /// Loads the persisted templates, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  List<QueueTemplate> load() => decodeAgentYamlList(
    readAgentYamlFile(file),
    key: 'templates',
    identity: 'id',
    fromYaml: QueueTemplate.fromYaml,
  );

  /// Persists [templates], creating the parent directory if needed.
  void save(List<QueueTemplate> templates) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'templates': [for (final template in templates) template.toYaml()],
    });
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }
}

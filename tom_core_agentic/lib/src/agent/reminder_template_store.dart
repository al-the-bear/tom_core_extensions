// Persistence for the reminder-template set.
//
// Reminder templates are the bodies a queue item or a timed request nudges
// with, and both of those are persisted: `QueuedPrompt.reminderTemplateId` and
// `TimedRequest.reminderTemplateId` each hold an id. An id nothing can resolve
// is not a reference, which is why this store exists rather than the templates
// living only in memory — a saved queue restored on the next launch has to be
// able to find the template it names.
//
// The tenth sidecar, and the same shape as the other nine: a small YAML file
// written synchronously on every change, degrading rather than throwing when
// the file is damaged — `agent_sidecar.dart` holds the shared rule (parse
// damage costs the file, shape damage costs one entry).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'reminder_template.dart';

/// Loads/saves the reminder-template set (`List<ReminderTemplate>`) as YAML.
final class ReminderTemplateStore {
  ReminderTemplateStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the reminder-templates file. Honors
  /// `TOM_SPECS_REMINDER_TEMPLATES_FILE`; falls back to
  /// `<cwd>/.tom/reminder_templates.yaml`.
  factory ReminderTemplateStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_REMINDER_TEMPLATES_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'reminder_templates.yaml');
    return ReminderTemplateStore(File(path));
  }

  /// Loads the persisted templates, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  List<ReminderTemplate> load() => decodeAgentYamlList(
    readAgentYamlFile(file),
    key: 'templates',
    identity: 'id',
    fromYaml: ReminderTemplate.fromYaml,
  );

  /// Persists [templates], creating the parent directory if needed.
  void save(List<ReminderTemplate> templates) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'templates': [for (final template in templates) template.toYaml()],
    });
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }
}

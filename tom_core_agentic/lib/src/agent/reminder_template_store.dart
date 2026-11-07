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
// written on every change, degrading rather than throwing when
// the file is damaged — `agent_sidecar.dart` holds the shared rule (parse
// damage costs the file, shape damage costs one entry).
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'reminder_template.dart';

/// Loads/saves the reminder-template set (`List<ReminderTemplate>`) as YAML.
final class ReminderTemplateStore extends AgentSidecarStore {
  ReminderTemplateStore({required super.fileSystem, required super.uri});

  /// Resolves the reminder-templates file. Honors
  /// `TOM_SPECS_REMINDER_TEMPLATES_FILE`; falls back to
  /// `.tom/reminder_templates.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory ReminderTemplateStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => ReminderTemplateStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_REMINDER_TEMPLATES_FILE',
      defaultPath: '.tom/reminder_templates.yaml',
    ),
  );

  /// Loads the persisted templates, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<ReminderTemplate>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'templates',
    identity: 'id',
    fromYaml: ReminderTemplate.fromYaml,
  );

  /// Persists [templates], making its folder when it is missing.
  Future<void> save(List<ReminderTemplate> templates) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'templates': [for (final template in templates) template.toYaml()],
    });
    return writeText(yaml);
  }
}

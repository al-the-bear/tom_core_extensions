// ReminderTemplate — a reusable "are you still there?" nudge body.
//
// Ported from the VS Code extension's `ReminderTemplate`
// (`tom_vscode_extension/src/managers/reminderSystem.ts`) for the TomSpecs
// editor. The reminder runtime uses fixed `{{token}}`
// chain-replaces rather than the canonical placeholder resolver, so the
// body is stored verbatim here; the editor renders / fills it elsewhere.
library;

import 'agent_yaml.dart';

/// A reusable reminder body identified by [id].
final class ReminderTemplate {
  const ReminderTemplate({
    required this.id,
    required this.name,
    required this.prompt,
    this.isDefault = false,
  });

  /// Stable identifier referenced by queue / timed entries.
  final String id;

  /// Human-readable label shown in editors.
  final String name;

  /// Template body using `{{token}}` mustache syntax (see the extension's
  /// `REMINDER_PLACEHOLDER_HELP` for the supported token set).
  final String prompt;

  /// Whether this is the fallback template when none is selected.
  final bool isDefault;

  factory ReminderTemplate.fromYaml(Map<String, dynamic> yaml) =>
      ReminderTemplate(
        id: yaml['id'] as String,
        name: yamlValue<String>(yaml, 'name') ?? '',
        prompt: yamlValue<String>(yaml, 'prompt') ?? '',
        isDefault: yamlValue<bool>(yaml, 'isDefault') ?? false,
      );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'name': name,
    'prompt': prompt,
    'isDefault': isDefault,
  };
}

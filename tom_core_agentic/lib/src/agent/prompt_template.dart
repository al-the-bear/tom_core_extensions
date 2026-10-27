// PromptTemplate — a reusable, placeholder-bearing prompt body.
//
// Ported from the VS Code extension's prompt-template store for the TomSpecs
// editor. A template's [body] is authored with the canonical placeholder
// forms (`${name}`, `{{name}}`, `${env:NAME}`) and resolved through the same
// composer the chat composer uses, giving the prompt-templates editor a
// live preview. The body is stored verbatim; resolution happens at use time so
// late-bound built-ins (`date`/`time`) reflect the moment of send.
library;

import 'agent_yaml.dart';

/// A reusable prompt body identified by [id].
final class PromptTemplate {
  const PromptTemplate({
    required this.id,
    required this.name,
    this.body = '',
    this.isUserMessage = false,
  });

  /// Stable identifier referenced by the editor / queue.
  final String id;

  /// Human-readable label shown in the prompt-templates editor.
  final String name;

  /// Template body using the canonical placeholder forms; resolved at use time.
  final String body;

  /// Whether this template seeds the composer's user-message field (vs. a
  /// reusable insertable snippet).
  final bool isUserMessage;

  factory PromptTemplate.fromYaml(Map<String, dynamic> yaml) => PromptTemplate(
    id: yaml['id'] as String,
    name: yamlValue<String>(yaml, 'name') ?? '',
    body: yamlValue<String>(yaml, 'body') ?? '',
    isUserMessage: yamlValue<bool>(yaml, 'isUserMessage') ?? false,
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'name': name,
    'body': body,
    'isUserMessage': isUserMessage,
  };
}

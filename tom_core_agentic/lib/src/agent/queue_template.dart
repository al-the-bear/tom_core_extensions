// QueueTemplate — a saved set of prompts that can be loaded into the queue.
//
// Ported from the VS Code extension's queue-template store for the TomSpecs
// editor. A queue template names an ordered list of prompt
// bodies; applying it appends those prompts (each still placeholder-bearing,
// resolved at send time) to the live prompt queue. The queue-templates editor
// saves/loads these as `*.template.queue.yaml`.
library;

import 'agent_yaml.dart';

/// A named, ordered set of prompt bodies identified by [id].
final class QueueTemplate {
  const QueueTemplate({
    required this.id,
    required this.name,
    this.prompts = const <String>[],
  });

  /// Stable identifier referenced by the queue-templates editor.
  final String id;

  /// Human-readable label.
  final String name;

  /// The ordered prompt bodies applied to the queue, head first. Each is
  /// authored with the canonical placeholder forms and resolved at send time.
  final List<String> prompts;

  factory QueueTemplate.fromYaml(Map<String, dynamic> yaml) => QueueTemplate(
    id: yaml['id'] as String,
    name: yamlValue<String>(yaml, 'name') ?? '',
    prompts: yamlStringList(yaml, 'prompts') ?? const <String>[],
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'name': name,
    'prompts': List<String>.from(prompts),
  };
}

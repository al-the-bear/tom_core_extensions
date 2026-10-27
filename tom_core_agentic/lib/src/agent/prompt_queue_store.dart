// Persistence for the prompt queue.
//
// The TomSpecs editor's prompt queue is held in the spec workspace as a YAML
// file so staged/pending prompts survive launches. This store mirrors the
// editor's other sidecars (`SpecSessionStore`, `BridgeChoiceStore`): a small
// YAML file written synchronously on every change, degrading rather than
// throwing when the file is damaged — `agent_sidecar.dart` holds the shared
// rule (parse damage costs the file, shape damage costs one entry).
//
// Held **out of** the document `*.docspecs.yaml` pass — the queue is editor
// UI state, not specification content.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'prompt_queue.dart';

/// Loads/saves the editor prompt queue (`List<QueuedPrompt>`) as YAML.
final class PromptQueueStore {
  PromptQueueStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the queue file. Honors `TOM_SPECS_QUEUE_FILE`; falls back to
  /// `<cwd>/.tom/prompt_queue.yaml`.
  factory PromptQueueStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_QUEUE_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'prompt_queue.yaml');
    return PromptQueueStore(File(path));
  }

  /// Loads the persisted queue, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  List<QueuedPrompt> load() => decodeAgentYamlList(
    readAgentYamlFile(file),
    key: 'items',
    identity: 'id',
    fromYaml: QueuedPrompt.fromYaml,
  );

  /// Persists [queue], creating the parent directory if needed.
  void save(List<QueuedPrompt> queue) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'items': [for (final item in queue) item.toYaml()],
    });
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }
}

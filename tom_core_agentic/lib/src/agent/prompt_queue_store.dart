// Persistence for the prompt queue.
//
// The TomSpecs editor's prompt queue is held in the spec workspace as a YAML
// file so staged/pending prompts survive launches. This store mirrors the
// editor's other sidecars (`SpecSessionStore`, `BridgeChoiceStore`): a small
// YAML file written on every change, degrading rather than
// throwing when the file is damaged — `agent_sidecar.dart` holds the shared
// rule (parse damage costs the file, shape damage costs one entry).
//
// Held **out of** the document `*.docspecs.yaml` pass — the queue is editor
// UI state, not specification content.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'prompt_queue.dart';

/// Loads/saves the editor prompt queue (`List<QueuedPrompt>`) as YAML.
final class PromptQueueStore extends AgentSidecarStore {
  PromptQueueStore({required super.fileSystem, required super.uri});

  /// Resolves the queue file. Honors `TOM_SPECS_QUEUE_FILE`; falls back to
  /// `.tom/prompt_queue.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory PromptQueueStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => PromptQueueStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_QUEUE_FILE',
      defaultPath: '.tom/prompt_queue.yaml',
    ),
  );

  /// Loads the persisted queue, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<QueuedPrompt>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'items',
    identity: 'id',
    fromYaml: QueuedPrompt.fromYaml,
  );

  /// Persists [queue], making its folder when it is missing.
  Future<void> save(List<QueuedPrompt> queue) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'items': [for (final item in queue) item.toYaml()],
    });
    return writeText(yaml);
  }
}

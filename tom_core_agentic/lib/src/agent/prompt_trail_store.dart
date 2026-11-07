// Persistence for the prompt trail.
//
// The trail's request/answer pairs are held in the spec workspace as a YAML
// file so the exchange history survives launches (mirroring
// `_ai/trail/anthropic/{quest}/`). Like the other editor sidecars it writes
// on every change and degrades rather than throwing when the
// file is damaged — see `agent_sidecar.dart`.
library;

import 'package:tom_file_system/tom_file_system.dart';

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'chat_message.dart';

/// Loads/saves the editor prompt trail (`List<TrailPair>`) as YAML.
final class PromptTrailStore extends AgentSidecarStore {
  PromptTrailStore({required super.fileSystem, required super.uri});

  /// Resolves the trail file. Honors `TOM_SPECS_TRAIL_FILE`; falls back to
  /// `.tom/prompt_trail.yaml` in the workspace.
  /// [environment] is the process environment (the host passes it); the
  /// variable names a path relative to the workspace, or an absolute one.
  factory PromptTrailStore.resolveDefault(
    TomFileSystem fileSystem, {
    Map<String, String> environment = const {},
  }) => PromptTrailStore(
    fileSystem: fileSystem,
    uri: AgentSidecarStore.locate(
      fileSystem,
      environment: environment,
      variable: 'TOM_SPECS_TRAIL_FILE',
      defaultPath: '.tom/prompt_trail.yaml',
    ),
  );

  /// Loads the persisted trail, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  Future<List<TrailPair>> load() async => decodeAgentYamlList(
    await readRoot(),
    key: 'pairs',
    identity: 'id',
    fromYaml: TrailPair.fromYaml,
  );

  /// Persists [trail], making its folder when it is missing.
  Future<void> save(List<TrailPair> trail) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'pairs': [for (final pair in trail) pair.toYaml()],
    });
    return writeText(yaml);
  }
}

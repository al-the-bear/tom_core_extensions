// Persistence for the prompt trail.
//
// The trail's request/answer pairs are held in the spec workspace as a YAML
// file so the exchange history survives launches (mirroring
// `_ai/trail/anthropic/{quest}/`). Like the other editor sidecars it writes
// synchronously on every change and degrades rather than throwing when the
// file is damaged — see `agent_sidecar.dart`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_sidecar.dart';
import 'agent_yaml.dart';
import 'chat_message.dart';

/// Loads/saves the editor prompt trail (`List<TrailPair>`) as YAML.
final class PromptTrailStore {
  PromptTrailStore(this.file);

  /// The backing YAML file.
  final File file;

  /// Resolves the trail file. Honors `TOM_SPECS_TRAIL_FILE`; falls back to
  /// `<cwd>/.tom/prompt_trail.yaml`.
  factory PromptTrailStore.resolveDefault() {
    final override = Platform.environment['TOM_SPECS_TRAIL_FILE'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join(Directory.current.path, '.tom', 'prompt_trail.yaml');
    return PromptTrailStore(File(path));
  }

  /// Loads the persisted trail, or an empty list when the file is
  /// missing, unreadable or malformed. Entries the file cannot supply
  /// are skipped individually — see [decodeAgentYamlList].
  List<TrailPair> load() => decodeAgentYamlList(
    readAgentYamlFile(file),
    key: 'pairs',
    identity: 'id',
    fromYaml: TrailPair.fromYaml,
  );

  /// Persists [trail], creating the parent directory if needed.
  void save(List<TrailPair> trail) {
    final yaml = encodeAgentYaml(<String, dynamic>{
      'version': 1,
      'pairs': [for (final pair in trail) pair.toYaml()],
    });
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }
}

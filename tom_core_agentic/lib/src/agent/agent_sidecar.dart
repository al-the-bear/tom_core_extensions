// Shared read + decode for the editor's YAML sidecar stores.
//
// The ten sidecars — queue, profiles, chat variables, prompt and queue
// templates, timed requests, trail, agent settings, bridge choice, session id
// — all make one promise: a damaged file costs the user a reset, never a
// crash. Each of them used to re-implement that promise, and ten copies
// drifted exactly as ten copies do: one shipped with no `try` at all, and all
// ten mistook "parses as YAML" for "is shaped like the model".
//
// The promise lives here now, so "all ten degrade the same way" is a property
// of one function rather than a claim about ten separate bodies.
library;

import 'dart:io';

import 'agent_yaml.dart';

/// Reads and parses the sidecar at [file], or `null` when it is missing,
/// empty, unreadable or malformed.
///
/// The four cases collapse into one result on purpose: to a caller about to
/// fall back on its defaults, a file it cannot use and a file that is not
/// there are the same file.
Map<String, dynamic>? readAgentYamlFile(File file) {
  try {
    if (!file.existsSync()) return null;
    final content = file.readAsStringSync();
    if (content.trim().isEmpty) return null;
    return decodeAgentYaml(content);
  } on FileSystemException {
    return null;
  } on FormatException {
    // Covers YAML syntax damage as well: a `YamlException` is a
    // `FormatException`, which is why two catches answer three damage shapes.
    return null;
  }
}

/// Builds the models in the list under [key] of [root], skipping the entries
/// the file cannot supply.
///
/// An entry is skipped when it is not a mapping, when its [identity] field is
/// not a non-empty string, or when [fromYaml] cannot read it.
///
/// **Skipping rather than defaulting** the identity is deliberate: an entry
/// with no id cannot afterwards be selected, edited or deleted, so
/// materialising one under a synthetic id would turn a recoverable data error
/// into a permanent orphan.
///
/// **Skipping per entry rather than failing the load** is the other half, and
/// the more valuable one. The stores used to discard the whole file the
/// moment anything in it was unreadable, so one bad row cost the user every
/// good row beside it.
///
/// The [identity] requirement is what separates a store's top-level list from
/// the nested lists inside an entry, which [decodeAgentYamlEntries] handles
/// without one.
List<T> decodeAgentYamlList<T>(
  Map<String, dynamic>? root, {
  required String key,
  required String identity,
  required T Function(Map<String, dynamic>) fromYaml,
}) => decodeAgentYamlEntries(root?[key], fromYaml, identity: identity) ?? <T>[];

/// Builds the single model under [key] of [root], or [orElse] when the file
/// cannot supply it. The singleton counterpart of [decodeAgentYamlList] —
/// with nothing to skip *to*, an unusable value falls back rather than
/// dropping out.
T decodeAgentYamlValue<T>(
  Map<String, dynamic>? root, {
  required String key,
  required T Function(Map<String, dynamic>) fromYaml,
  required T orElse,
}) {
  final value = root?[key];
  if (value is! Map) return orElse;
  try {
    return fromYaml(value.cast<String, dynamic>());
  } on TypeError {
    return orElse;
  }
}

// YAML codec for the editor-facing agent data models.
//
// Every agent model in this folder serialises to / from a plain
// `Map<String, dynamic>` (its `toYaml()` / `fromYaml()` pair). These two
// free functions move that map across the YAML text boundary so the
// TomSpecs editor can persist queues, profiles, templates, timed requests
// and chat-variable stores as `*.yaml` files in the spec workspace.
//
// `encodeAgentYaml` emits via `package:yaml_edit` (stable key order, block
// style); `decodeAgentYaml` parses via `package:yaml` and deep-converts the
// `YamlMap` / `YamlList` views into plain `Map` / `List` so the models'
// `fromYaml` factories never have to know about the YAML view types.
library;

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// Serialises [data] to a YAML document string.
String encodeAgentYaml(Map<String, dynamic> data) {
  final editor = YamlEditor('{}');
  editor.update(<Object?>[], data);
  return editor.toString();
}

/// Parses a YAML document [yaml] into a plain `Map<String, dynamic>`.
///
/// Throws [FormatException] when the document's root is not a mapping.
Map<String, dynamic> decodeAgentYaml(String yaml) {
  final root = deepPlainYaml(loadYaml(yaml));
  if (root is! Map<String, dynamic>) {
    throw const FormatException('expected a YAML mapping at the document root');
  }
  return root;
}

/// Recursively converts a parsed YAML tree ([YamlMap] / [YamlList] / scalar)
/// into plain Dart collections. Map keys are coerced to `String`.
Object? deepPlainYaml(Object? node) {
  if (node is Map) {
    return <String, dynamic>{
      for (final entry in node.entries)
        entry.key.toString(): deepPlainYaml(entry.value),
    };
  }
  if (node is List) {
    return <dynamic>[for (final element in node) deepPlainYaml(element)];
  }
  return node;
}

/// Reads [key] from [yaml] when it holds a [T], and `null` when it does not —
/// whether the key is absent or present with the wrong type.
///
/// This is the leaf counterpart to [decodeAgentYamlEntries], and it exists for
/// the same reason: a persisted file is untrusted input. A cast
/// (`yaml['name'] as String?`) answers only the absent case; a hand-edit that
/// leaves `name: 7` behind throws instead, which costs the reader the whole
/// entry. Type-testing collapses the two into one answer — the field is
/// unusable, so it reads as unset — and a field that already carries a default
/// is worth exactly that default, not the entry around it.
///
/// Deliberately *not* for identity fields. An entry whose id cannot be read
/// cannot be addressed, updated or deleted, so there is nothing to salvage;
/// those stay unguarded casts so [decodeAgentYamlEntries] drops the entry.
T? yamlValue<T>(Map<String, dynamic> yaml, String key) {
  final value = yaml[key];
  return value is T ? value : null;
}

/// Reads [key] as a list of strings, keeping the elements that are strings, or
/// `null` when [key] does not hold a list.
///
/// Damage costs the *element* here, matching how [decodeAgentYamlEntries]
/// treats a list of mappings.
List<String>? yamlStringList(Map<String, dynamic> yaml, String key) {
  final node = yaml[key];
  if (node is! List) return null;
  return node.whereType<String>().toList();
}

/// Reads [key] as a string and maps it through [fromValue], or `null` when
/// [key] holds no string.
///
/// Keeps "absent" distinct from "present but unrecognised": an absent key is
/// `null`, while a string the enum does not know falls back inside [fromValue].
/// Callers that want the fallback for both cases can call [fromValue] on
/// [yamlValue] directly.
T? yamlEnum<T>(
  Map<String, dynamic> yaml,
  String key,
  T Function(String?) fromValue,
) {
  final value = yamlValue<String>(yaml, key);
  return value == null ? null : fromValue(value);
}

/// Builds models from the YAML list [node], skipping the elements it cannot
/// build, or returns `null` when [node] is not a list at all.
///
/// A persisted file is untrusted input: it can be hand-edited, half-written by
/// a crash, or left behind by an older schema. Every element is therefore
/// treated as a claim to be checked rather than a value to be cast. An element
/// is skipped when it is not a mapping, when [identity] is given and that field
/// is not a non-empty string, or when [fromYaml] cannot read it.
///
/// Returning `null` for a non-list keeps "the field was absent" and "the field
/// was unusable" the same answer, which is what every caller here wants: both
/// leave an optional list unset.
List<T>? decodeAgentYamlEntries<T>(
  Object? node,
  T Function(Map<String, dynamic>) fromYaml, {
  String? identity,
}) {
  if (node is! List) return null;
  final models = <T>[];
  for (final element in node) {
    if (element is! Map) continue;
    if (identity != null) {
      final id = element[identity];
      if (id is! String || id.isEmpty) continue;
    }
    try {
      models.add(fromYaml(element.cast<String, dynamic>()));
    } on TypeError {
      // The last resort for shape damage below the identity: a field the model
      // reads through a cast, holding the wrong type. Fields that carry a
      // default read through [yamlValue] and never reach here — what does is a
      // field the entry cannot be built without, and losing the entry is the
      // only answer left. Catching an `Error` is justified by how narrow this
      // is: it wraps a single call whose only input is untrusted file content,
      // so a failed cast inside it is a fault in the file, not a bug in this
      // package. It is also what keeps the guarantee true for fields added
      // later, which enumerating today's casts one by one would not.
      continue;
    }
  }
  return models;
}

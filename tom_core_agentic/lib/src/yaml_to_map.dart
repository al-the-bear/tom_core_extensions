import 'package:yaml/yaml.dart';

/// Builds the domain-specific exception [loadYamlAsMap] throws when parsing
/// or type-checking fails.
///
/// Every caller supplies its own factory so the thrown error *type* stays
/// domain-specific (e.g. a loader's `SubstrateConfigException`, or
/// `FormatException` at an untrusted-input boundary) while the conversion
/// logic is shared. The factory receives the fully-formed,
/// engineer-readable message and wraps it in the caller's error type. The
/// default is [FormatException.new].
typedef YamlMapErrorFactory = Object Function(String message);

/// Parses [source] as a single YAML document and returns it as a **plain**
/// `Map<String, Object?>` — never a `YamlMap`, `YamlList`, or `YamlScalar`.
///
/// This is the one canonical YAML→Map entry point for the brain's config
/// layer. `package:yaml`'s [loadYaml] yields a tree
/// of `YamlMap`/`YamlList` nodes that are read-only and leak their node types
/// through every typed access. Routing every load through this helper
/// converts that tree, once, at the parse boundary into the mutable
/// `Map`/`List`/`String`/`num`/`bool`/`null` primitives the rest of the
/// system reads through [MapFieldReader].
///
/// Conversion rules, applied recursively:
/// - a `YamlMap` becomes a `Map<String, Object?>`; its keys must be strings
///   (a non-string key — YAML permits integer keys — is a located error);
/// - a `YamlList` becomes a `List<Object?>`;
/// - a scalar (`String`/`int`/`double`/`bool`/`null`) passes through unwrapped.
///
/// The document root must be a map. A non-map document (a top-level list, a
/// bare scalar, or an empty/`null` document) throws via [errorFactory] with a
/// message rooted at [rootPath] (default `'root'`), e.g.
/// `root must be a map (got YamlList).`
///
/// ```dart
/// final map = loadYamlAsMap(content, rootPath: 'substrate');
/// const reader = MapFieldReader(SubstrateConfigException.new);
/// final id = reader.requireString(map, 'id', 'substrate.id');
/// ```
///
/// ## Expansion bound (untrusted input)
///
/// `package:yaml` resolves an alias (`*anchor`) by sharing the *same* node
/// object, so a "billion-laughs" document — each anchor referencing the prior
/// one a handful of times — stays small on the wire but materialises into an
/// exponentially larger tree the moment [_toPlain] deep-copies every alias into
/// fresh collections. To keep an untrusted YAML boundary from amplifying into
/// an out-of-memory crash, conversion debits a node budget: [maxNodes] caps the
/// number of map/list/scalar nodes the *materialised* tree may contain. When a
/// document would exceed it, conversion stops and throws via [errorFactory]
/// with a located, deterministic message rather than running to exhaustion. The
/// default (1,000,000) is far above any hand-authored config and only ever
/// trips on a pathological alias bomb.
Map<String, Object?> loadYamlAsMap(
  String source, {
  YamlMapErrorFactory errorFactory = FormatException.new,
  String rootPath = 'root',
  int maxNodes = 1000000,
}) {
  final doc = loadYaml(source);
  final budget = _NodeBudget(maxNodes, errorFactory);
  final plain = _toPlain(doc, rootPath, errorFactory, budget);
  if (plain is! Map<String, Object?>) {
    throw errorFactory('$rootPath must be a map (got ${_typeName(doc)}).');
  }
  return plain;
}

/// Mutable counter that bounds the number of materialised nodes, throwing via
/// the caller's [YamlMapErrorFactory] when the budget is exhausted. Guards
/// against alias-amplification ("billion-laughs") documents.
class _NodeBudget {
  final int max;
  final YamlMapErrorFactory err;
  int _count = 0;

  _NodeBudget(this.max, this.err);

  /// Charges one materialised node, throwing once [max] is exceeded.
  void charge(String path) {
    if (++_count > max) {
      throw err(
        '$path exceeds the maximum of $max materialised YAML nodes; '
        'input rejected to prevent alias-expansion amplification.',
      );
    }
  }
}

/// Recursively converts a `package:yaml` node into plain Dart collections,
/// charging [budget] one unit per materialised node so an alias bomb is
/// rejected before it can amplify (see [loadYamlAsMap]'s expansion bound).
Object? _toPlain(
  Object? node,
  String path,
  YamlMapErrorFactory err,
  _NodeBudget budget,
) {
  budget.charge(path);
  if (node is YamlMap) {
    final out = <String, Object?>{};
    for (final key in node.keys) {
      if (key is! String) {
        throw err(
          '$path has a non-string key `$key` '
          '(got ${_typeName(key)}); config maps must be string-keyed.',
        );
      }
      out[key] = _toPlain(node[key], '$path.$key', err, budget);
    }
    return out;
  }
  if (node is YamlList) {
    final out = <Object?>[];
    for (var i = 0; i < node.length; i++) {
      out.add(_toPlain(node[i], '$path[$i]', err, budget));
    }
    return out;
  }
  // A YamlScalar can appear when a node is reached without going through a
  // YamlMap/YamlList `[]` access (which already unwraps scalars). Unwrap it.
  if (node is YamlScalar) return node.value;
  // Already a plain scalar (String/num/bool/null).
  return node;
}

String _typeName(Object? value) =>
    value == null ? 'Null' : '${value.runtimeType}';

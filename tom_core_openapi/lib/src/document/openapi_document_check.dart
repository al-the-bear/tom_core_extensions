/// The consistency rules an OpenAPI document must meet that its meta-schema
/// cannot express.
///
/// The OpenAPI 3.1 schema checks each object's shape in isolation. It cannot
/// see that two operations claim one `operationId`, that a `$ref` names a
/// component nobody defined, or that a path variable has no parameter — and
/// each of those breaks a client generator rather than a validator. These run
/// without Python, so the generator applies them to everything it writes.
library;

/// Checks a decoded OpenAPI document for cross-reference faults.
abstract final class TomOpenApiDocumentCheck {
  /// Every fault in [document], one sentence each; empty when it is sound.
  ///
  /// Checked: `operationId`s are unique; every local `$ref` resolves; every
  /// `{variable}` in a path has a path parameter, and every path parameter
  /// names a variable of its path; no operation declares one parameter (name
  /// and location) twice.
  static List<String> problems(Map<String, Object?> document) {
    final problems = <String>[];
    final operationIds = <String, String>{};
    final paths = document['paths'];
    if (paths is Map) {
      for (final pathEntry in paths.entries) {
        final path = pathEntry.key as String;
        final variables = {
          for (final m in RegExp(r'\{([^{}]+)\}').allMatches(path)) m[1]!,
        };
        final operations = pathEntry.value;
        if (operations is! Map) continue;
        for (final operationEntry in operations.entries) {
          final operation = operationEntry.value;
          if (operation is! Map) continue;
          final where = '${operationEntry.key.toUpperCase()} $path';
          final id = operation['operationId'];
          if (id is String) {
            final earlier = operationIds[id];
            if (earlier != null) {
              problems.add('operationId "$id" is used by $earlier and $where');
            } else {
              operationIds[id] = where;
            }
          }
          final seen = <String>{};
          for (final p in (operation['parameters'] as List?) ?? const []) {
            if (p is! Map) continue;
            final key = '${p['in']} ${p['name']}';
            if (!seen.add(key)) {
              problems.add('$where declares the $key parameter twice');
            }
          }
          final declared = <String>{
            for (final p in (operation['parameters'] as List?) ?? const [])
              if (p is Map && p['in'] == 'path') p['name'] as String,
          };
          for (final missing in variables.difference(declared)) {
            problems.add('$where has no path parameter for {$missing}');
          }
          for (final extra in declared.difference(variables)) {
            problems.add(
              '$where declares path parameter "$extra" its path '
              'does not contain',
            );
          }
        }
      }
    }
    final schemas =
        ((document['components'] as Map?)?['schemas'] as Map?) ?? const {};
    void visit(Object? node, String at) {
      if (node is Map) {
        final ref = node[r'$ref'];
        if (ref is String && ref.startsWith('#/components/schemas/')) {
          final name = ref.substring('#/components/schemas/'.length);
          if (!schemas.containsKey(name)) {
            problems.add('$at refers to the undefined schema "$name"');
          }
        }
        for (final entry in node.entries) {
          visit(entry.value, '$at/${entry.key}');
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          visit(node[i], '$at/$i');
        }
      }
    }

    visit(document, '#');
    return problems;
  }
}

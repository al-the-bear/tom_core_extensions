import 'placeholders/placeholders.dart';
import 'yaml_to_map.dart';

/// Builds the domain-specific exception a [YamlConfigReader] throws when
/// a typed access or `${ENV}` expansion fails.
///
/// Every loader supplies its own factory so error *types* stay
/// domain-specific (e.g. `SubstrateConfigException`,
/// `MemoryConfigException`) while the parsing and substitution logic is
/// shared. The factory receives the fully-formed, engineer-readable
/// message and wraps it in the loader's exception class.
typedef YamlConfigErrorFactory = Object Function(String message);

/// Type-safe accessors over a **plain** config map, plus an explicit
/// `${NAME}` environment-variable expander.
///
/// The map is the plain `Map<Object?, Object?>` produced by [loadYamlAsMap]
/// at the parse boundary — never a `package:yaml` `YamlMap`. This reader has
/// no `package:yaml` import: the node types stay out of the read path
/// entirely. Nested maps and lists it returns are
/// likewise plain `Map<Object?, Object?>` / `List<Object?>`, so a loader can
/// descend through the whole document without ever meeting a `YamlMap`.
///
/// This is the consolidation of the field-helper blocks that several
/// brain loaders grew independently (`SubstrateConfigLoader`,
/// `MemoryConfigLoader`). They were behaviourally identical line-for-line
/// apart from the exception class they raised; the [errorFactory] seam
/// preserves that one intended difference and removes the duplication.
///
/// Construction is per parse: a loader builds one reader with the env
/// map for that call and its own error factory, then routes every typed
/// read through it:
///
/// ```dart
/// final doc = loadYamlAsMap(content, rootPath: 'substrate');
/// final reader = YamlConfigReader(
///   env: env,
///   errorFactory: SubstrateConfigException.new,
/// );
/// final id = reader.requireString(doc, 'id', 'substrate.providers[0].id');
/// final url = reader.expandEnv(rawUrl, 'substrate.providers[0].baseUrl');
/// ```
///
/// **Path argument.** Every accessor takes a `path` — the dotted
/// location of the value in the document (e.g. `substrate.embedding.dims`).
/// It appears verbatim in error messages so a failure points the reader
/// straight at the offending line. [optionalMap] is the one exception:
/// it reports by `key` rather than `path`, matching the original
/// loaders' message shape.
final class YamlConfigReader {
  /// Environment used by [expandEnv] to resolve `${NAME}` tokens.
  final Map<String, String> env;

  /// Wraps a message in the loader's domain exception type.
  final YamlConfigErrorFactory errorFactory;

  const YamlConfigReader({required this.env, required this.errorFactory});

  Never _fail(String message) => throw errorFactory(message);

  // ---------------------------------------------------------------
  // Typed field accessors.
  // ---------------------------------------------------------------

  /// Returns the string at [key]; throws if missing or non-string.
  String requireString(Map<Object?, Object?> node, String key, String path) {
    final v = node[key];
    if (v == null) {
      _fail('Missing required field: $path');
    }
    if (v is! String) {
      _fail('$path must be a string (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the string at [key], or `null` when absent; throws if
  /// present but non-string.
  String? optionalString(Map<Object?, Object?> node, String key, String path) {
    final v = node[key];
    if (v == null) return null;
    if (v is! String) {
      _fail('$path must be a string (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the int at [key]; throws if missing or non-int.
  int requireInt(Map<Object?, Object?> node, String key, String path) {
    final v = node[key];
    if (v == null) {
      _fail('Missing required field: $path');
    }
    if (v is! int) {
      _fail('$path must be an integer (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the int at [key], or `null` when absent; throws if present
  /// but non-int.
  int? optionalInt(Map<Object?, Object?> node, String key, String path) {
    final v = node[key];
    if (v == null) return null;
    if (v is! int) {
      _fail('$path must be an integer (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the number at [key] as a double; throws if missing or
  /// non-numeric.
  double requireDouble(Map<Object?, Object?> node, String key, String path) {
    final v = node[key];
    if (v == null) {
      _fail('Missing required field: $path');
    }
    if (v is num) return v.toDouble();
    _fail('$path must be a number (got ${v.runtimeType}).');
  }

  /// Returns the number at [key] as a double, or `null` when absent;
  /// throws if present but non-numeric.
  double? optionalDouble(Map<Object?, Object?> node, String key, String path) {
    final v = node[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    _fail('$path must be a number (got ${v.runtimeType}).');
  }

  /// Returns the bool at [key], or `null` when absent; throws if present
  /// but non-bool.
  bool? optionalBool(Map<Object?, Object?> node, String key, String path) {
    final v = node[key];
    if (v == null) return null;
    if (v is! bool) {
      _fail('$path must be a boolean (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the map at [key]; throws if missing or non-map.
  Map<Object?, Object?> requireMap(
    Map<Object?, Object?> node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) {
      _fail('Missing required field: $path');
    }
    if (v is! Map<Object?, Object?>) {
      _fail('$path must be a map (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the map at [key], or `null` when absent; throws if present
  /// but non-map.
  ///
  /// Reports by [key] rather than a dotted path, matching the original
  /// loader message (`Field \`webSearch\` must be a map …`).
  Map<Object?, Object?>? optionalMap(Map<Object?, Object?> node, String key) {
    final v = node[key];
    if (v == null) return null;
    if (v is! Map<Object?, Object?>) {
      _fail('Field `$key` must be a map (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the list at [key]; throws if missing or non-list.
  List<Object?> requireList(
    Map<Object?, Object?> node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) {
      _fail('Missing required field: $path');
    }
    if (v is! List<Object?>) {
      _fail('$path must be a list (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Returns the list at [key], or `null` when absent; throws if present
  /// but non-list.
  List<Object?>? optionalList(
    Map<Object?, Object?> node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) return null;
    if (v is! List<Object?>) {
      _fail('$path must be a list (got ${v.runtimeType}).');
    }
    return v;
  }

  /// Parses [raw] as a [Uri]; throws if it is not a valid URI.
  Uri parseUri(String raw, String path) {
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      _fail('$path must be a valid URI (got "$raw").');
    }
    return uri;
  }

  // ---------------------------------------------------------------
  // `${env:NAME}` substitution (the shared placeholder resolver).
  // ---------------------------------------------------------------

  /// Expands `${env:NAME}` tokens in [input] against [env].
  ///
  /// Routes through the single shared [PlaceholderResolver] (env-only,
  /// synchronous: no bindings, no `${{ … }}` backing), so the whole config
  /// layer and the engine resolve placeholders through one mechanism. The
  /// environment is reachable **only** via the `${env:NAME}` form; a bare
  /// `${NAME}` is treated as an (unbound) simple placeholder and — in the
  /// default strict mode — fails. A `${{ … }}` expression form is rejected
  /// on this synchronous path.
  ///
  /// Returns [input] unchanged when it has no placeholder; throws via
  /// [errorFactory] — each message carrying [path] — when a token names an
  /// undefined variable, is an unbound bare placeholder, fails to converge,
  /// or uses the unsupported expression form.
  String expandEnv(String input, String path) {
    final resolver = PlaceholderResolver(environment: env);
    try {
      return resolver.resolveSync(input);
    } on PlaceholderUnresolvedException catch (e) {
      final ref = e.reference;
      throw errorFactory(
        ref.startsWith('env:')
            ? '$path references undefined env var `\${$ref}`.'
            : '$path references unbound placeholder `\${$ref}` '
                  '(reach the environment with `\${env:$ref}`).',
      );
    } on PlaceholderRecursionException catch (e) {
      throw errorFactory('$path: ${e.message}');
    } on PlaceholderExpressionException catch (e) {
      throw errorFactory('$path: ${e.message}');
    }
  }
}

/// Turns Dart types into OpenAPI 3.1 schema objects, collecting every
/// reflected class it meets as a named component.
///
/// The schemas describe what the wire **actually carries**, which is decided by
/// the kernel's serializer (`TomReflectionInfo.getValues`), not by the Dart
/// declaration alone. So the builder follows the serializer's rules rather than
/// the type system's:
///
///  * a plain `@tomReflector` DTO contributes its own non-static, non-private,
///    non-final fields — exactly the ones `getValues` walks — and a field is
///    `required` when its type is non-nullable and nothing can withhold it;
///  * a `TomClass` renders its observable members, so its schema is read from
///    the `TomObject` fields (`TomString`, `TomNDateTime`, `TomList<…>`, …), the
///    `N` variants being the nullable ones;
///  * a type that renders itself (`toJson()`, a `jsonEncode` getter,
///    `TomJsonSerializable`) has a shape no declaration states, and is described
///    as an object and marked `x-tom-opaque` rather than guessed at;
///  * a `DateTime` field travels as a UTC ISO-8601 string, but an observable
///    `TomDateTime` member as the same text behind an `@!@` prefix
///    ([TomOpenApiSchemaBuilder.tomDateTime]); a zoned value as its own string
///    form.
library;

import 'package:tom_core_server/tom_core_server.dart';

/// A Dart type as the builder reasons about it: a [name], its type
/// [arguments], whether it admits `null`, and — when it came from a declaration
/// — its [mirror].
class TomOpenApiDartType {
  /// The simple name, without type arguments (`List`, `Workspace`).
  final String name;

  /// The type arguments, outermost first.
  final List<TomOpenApiDartType> arguments;

  /// Whether the type admits `null`.
  final bool nullable;

  /// The class mirror, when the type was read from a declaration.
  final ClassMirror? mirror;

  /// A type with the given parts.
  const TomOpenApiDartType(
    this.name, {
    this.arguments = const [],
    this.nullable = false,
    this.mirror,
  });

  /// Parses a type as Dart prints it — `List<Workspace>`,
  /// `Map<String, Object?>`, `Future<void>`.
  ///
  /// The registry's `TomApiEndpoint.responseType` is a [Type], and a [Type]
  /// keeps every type argument where a reflected return type keeps only the
  /// first level; parsing its printed form is how the full shape is recovered.
  factory TomOpenApiDartType.parse(String text) {
    var source = text.trim();
    var nullable = false;
    if (source.endsWith('?')) {
      nullable = true;
      source = source.substring(0, source.length - 1).trim();
    }
    final open = source.indexOf('<');
    if (open < 0 || !source.endsWith('>')) {
      return TomOpenApiDartType(source, nullable: nullable);
    }
    final name = source.substring(0, open).trim();
    final inner = source.substring(open + 1, source.length - 1);
    final arguments = <TomOpenApiDartType>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < inner.length; i++) {
      final character = inner[i];
      if (character == '<') depth++;
      if (character == '>') depth--;
      if (character == ',' && depth == 0) {
        arguments.add(TomOpenApiDartType.parse(inner.substring(start, i)));
        start = i + 1;
      }
    }
    arguments.add(TomOpenApiDartType.parse(inner.substring(start)));
    return TomOpenApiDartType(name, arguments: arguments, nullable: nullable);
  }

  /// Reads a type from a reflected declaration.
  ///
  /// Nullability and the first level of type arguments come from the mirror;
  /// deeper arguments are not carried by the reflection data.
  factory TomOpenApiDartType.fromMirror(TypeMirror mirror) {
    List<TypeMirror> arguments;
    try {
      arguments = mirror.typeArguments;
    } on Object {
      arguments = const [];
    }
    bool nullable;
    try {
      nullable = mirror.isNullable;
    } on Object {
      nullable = false;
    }
    return TomOpenApiDartType(
      mirror.simpleName,
      arguments: [for (final a in arguments) TomOpenApiDartType.fromMirror(a)],
      nullable: nullable,
      mirror: mirror is ClassMirror ? mirror : null,
    );
  }

  /// Reads the type of a field or parameter.
  ///
  /// The shape comes from the declaration's reflected [Type], which keeps
  /// every type argument; only the top-level nullability, which the [Type]
  /// erases, comes from the mirror. The mirror's own type arguments are not
  /// used: the generated reflection data can attach the wrong class to an
  /// argument (a `List<String>` field whose argument mirror names another
  /// class), where the [Type] is always right.
  factory TomOpenApiDartType.fromDeclaration(VariableMirror declaration) {
    bool nullable;
    try {
      nullable = declaration.type.isNullable;
    } on Object {
      nullable = false;
    }
    String text;
    try {
      text = '${declaration.reflectedType}';
    } on Object {
      return TomOpenApiDartType.fromMirror(declaration.type);
    }
    final parsed = TomOpenApiDartType.parse(text);
    final mirror = declaration.type;
    return TomOpenApiDartType(
      parsed.name,
      arguments: parsed.arguments,
      nullable: nullable || parsed.nullable,
      mirror: mirror is ClassMirror && mirror.simpleName == parsed.name
          ? mirror
          : null,
    );
  }

  /// This type without its `Future` / `FutureOr` wrapper.
  TomOpenApiDartType get awaited =>
      (name == 'Future' || name == 'FutureOr') && arguments.isNotEmpty
      ? arguments.first.awaited
      : this;

  /// Whether this is a type with no value on the wire.
  bool get isVoid => name == 'void' || name == 'Null' || name == 'Never';

  @override
  String toString() =>
      '$name${arguments.isEmpty ? '' : '<${arguments.join(', ')}>'}'
      '${nullable ? '?' : ''}';
}

/// Builds schema objects and the `components.schemas` they reference.
class TomOpenApiSchemaBuilder {
  /// The named component schemas built so far, by component name.
  final Map<String, Map<String, Object?>> components = {};

  /// The class each component name was built from, to refuse two classes that
  /// would share one name.
  final Map<String, ClassMirror> _componentOwners = {};

  /// The primitive Dart types and their schemas.
  static const Map<String, Map<String, Object?>> primitives = {
    'String': {'type': 'string'},
    'int': {'type': 'integer', 'format': 'int64'},
    'double': {'type': 'number', 'format': 'double'},
    'num': {'type': 'number'},
    'bool': {'type': 'boolean'},
    'DateTime': {'type': 'string', 'format': 'date-time'},
    'TomZonedDateTime': {'type': 'string', 'x-tom-type': 'TomZonedDateTime'},
    'TomZonedDate': {'type': 'string', 'x-tom-type': 'TomZonedDate'},
    'TomZonedTime': {'type': 'string', 'x-tom-type': 'TomZonedTime'},
    'Uri': {'type': 'string', 'format': 'uri'},
    'Duration': {'type': 'integer', 'x-tom-type': 'Duration'},
  };

  /// The wire form of an observable `TomDateTime` member: the ISO-8601 text
  /// behind the `@!@` prefix `TomClass` writes, so that its reader can tell a
  /// date from a string. Not `format: date-time`, which the prefix is not;
  /// `x-tom-type` lets a client generator that knows the convention decode it.
  static const Map<String, Object?> tomDateTime = {
    'type': 'string',
    'pattern': '^@!@',
    'description':
        'An ISO-8601 date-time behind the "@!@" prefix, the wire form of an '
        'observable TomDateTime member.',
    'x-tom-type': 'TomDateTime',
  };

  /// The observable member types of a `TomClass` and the value types they
  /// carry; the `N` variants admit `null`.
  static const Map<String, (String, bool)> observables = {
    'TomString': ('String', false),
    'TomNString': ('String', true),
    'TomInt': ('int', false),
    'TomNInt': ('int', true),
    'TomDouble': ('double', false),
    'TomNDouble': ('double', true),
    'TomBool': ('bool', false),
    'TomNBool': ('bool', true),
    'TomDateTime': ('DateTime', false),
    'TomNDateTime': ('DateTime', true),
    'TomOZonedDateTime': ('TomZonedDateTime', false),
    'TomNOZonedDateTime': ('TomZonedDateTime', true),
    'TomOZonedDate': ('TomZonedDate', false),
    'TomNOZonedDate': ('TomZonedDate', true),
    'TomOZonedTime': ('TomZonedTime', false),
    'TomNOZonedTime': ('TomZonedTime', true),
  };

  static const _collections = {'List', 'Set', 'Iterable'};
  static const _anything = {'Object', 'dynamic'};

  /// The schema of [type], registering any class it reaches as a component.
  Map<String, Object?> schemaOf(TomOpenApiDartType type) {
    final schema = _schemaOfNonNull(type);
    return type.nullable ? nullableOf(schema) : schema;
  }

  /// [schema] widened to admit `null`.
  ///
  /// OpenAPI 3.1 is JSON Schema 2020-12, so `nullable: true` is gone; a typed
  /// schema gains `"null"` in its type list, and a reference is wrapped in
  /// `anyOf`.
  static Map<String, Object?> nullableOf(Map<String, Object?> schema) {
    final type = schema['type'];
    if (type is String) {
      return {
        ...schema,
        'type': [type, 'null'],
      };
    }
    if (type is List) {
      return type.contains('null')
          ? schema
          : {
              ...schema,
              'type': [...type, 'null'],
            };
    }
    if (schema.isEmpty) return schema;
    return {
      'anyOf': [
        schema,
        {'type': 'null'},
      ],
    };
  }

  Map<String, Object?> _schemaOfNonNull(TomOpenApiDartType type) {
    final name = type.name;
    final primitive = primitives[name];
    if (primitive != null) return Map.of(primitive);
    if (_anything.contains(name) || type.isVoid) return {};
    if (_collections.contains(name)) {
      return {
        'type': 'array',
        'items': type.arguments.isEmpty ? {} : schemaOf(type.arguments.first),
      };
    }
    if (name == 'Map') {
      return {
        'type': 'object',
        'additionalProperties': type.arguments.length < 2
            ? <String, Object?>{}
            : schemaOf(type.arguments[1]),
      };
    }
    final observable = observables[name];
    if (observable != null) {
      final value = observable.$1 == 'DateTime'
          ? Map.of(tomDateTime)
          : schemaOf(TomOpenApiDartType(observable.$1));
      return observable.$2 ? nullableOf(value) : value;
    }
    if (name == 'TomList') {
      return {
        'type': 'array',
        'items': type.arguments.isEmpty ? {} : schemaOf(type.arguments.first),
      };
    }
    if (name == 'TomMap') {
      return {
        'type': 'object',
        'additionalProperties': type.arguments.length < 2
            ? <String, Object?>{}
            : schemaOf(type.arguments[1]),
      };
    }
    if (name == 'TomObservableEnum') return {'type': 'string'};
    final mirror = type.mirror ?? resolveClass(name);
    if (mirror.isEnum) return {'type': 'string'};
    return {r'$ref': '#/components/schemas/${_component(mirror)}'};
  }

  /// The reflected class named [name], refusing a name that is not reflected
  /// or that two reflected classes share.
  static ClassMirror resolveClass(String name) {
    final matches = [
      for (final candidate in tomReflector.annotatedClasses)
        if (candidate.simpleName == name) candidate,
    ];
    if (matches.isEmpty) {
      throw TomOpenApiException(
        'openapi.schema.type_not_reflected',
        'The type "$name" appears on the wire but is not reflected, so its '
            'shape cannot be described; annotate it with @tomReflector and '
            'regenerate the reflection seed.',
        parameters: {'type': name},
      );
    }
    if (matches.length > 1) {
      throw TomOpenApiException(
        'openapi.schema.ambiguous_type',
        'Two reflected classes are named "$name", so a component of that name '
            'would describe one of them silently; rename one.',
        parameters: {'type': name},
      );
    }
    return matches.single;
  }

  /// Registers [mirror] as a component and returns its name.
  String _component(ClassMirror mirror) {
    final name = mirror.simpleName;
    final owner = _componentOwners[name];
    if (owner != null) {
      if (owner != mirror && owner.qualifiedName != mirror.qualifiedName) {
        throw TomOpenApiException(
          'openapi.schema.ambiguous_type',
          'Two classes named "$name" appear on the wire; a component name must '
              'identify one shape.',
          parameters: {'type': name},
        );
      }
      return name;
    }
    _componentOwners[name] = mirror;
    // Registered before it is built, so a class that refers to itself — a
    // tree node holding its children — ends in a reference, not a loop.
    components[name] = const {};
    components[name] = _classSchema(mirror);
    return name;
  }

  Map<String, Object?> _classSchema(ClassMirror mirror) {
    final tomClass = _isTomClass(mirror);
    if (!tomClass && _rendersItself(mirror)) {
      return {
        'type': 'object',
        'description':
            '${mirror.simpleName} renders itself; its members are not '
            'declared.',
        'x-tom-opaque': true,
      };
    }
    final properties = <String, Object?>{};
    final required = <String>[];
    if (tomClass) {
      for (final (name, variable) in _tomClassMembers(mirror)) {
        final type = TomOpenApiDartType.fromDeclaration(variable);
        final observable = observables[type.name];
        properties[name] = schemaOf(type);
        if (observable == null || !observable.$2) required.add(name);
      }
    } else {
      for (final entry in mirror.declarations.entries) {
        final variable = entry.value;
        if (variable is! VariableMirror ||
            variable.isStatic ||
            variable.isPrivate ||
            variable.isFinal) {
          continue;
        }
        final type = TomOpenApiDartType.fromDeclaration(variable);
        properties[entry.key] = schemaOf(type);
        final withheld = variable.metadata.any((m) => m is TomProtectedField);
        if (!type.nullable && !withheld) required.add(entry.key);
      }
    }
    return {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    };
  }

  /// The observable members of a `TomClass`, own and inherited, in
  /// declaration order — what `TomClass.getValues` renders.
  static List<(String, VariableMirror)> _tomClassMembers(ClassMirror mirror) {
    final chain = <ClassMirror>[];
    ClassMirror? current = mirror;
    while (current != null && current.simpleName != 'TomClass') {
      chain.insert(0, current);
      current = _superclassOf(current);
    }
    return [
      for (final cls in chain)
        for (final entry in cls.declarations.entries)
          if (entry.value case final VariableMirror variable
              when !variable.isStatic &&
                  !variable.isPrivate &&
                  _isObservableType(variable.type))
            (entry.key, variable),
    ];
  }

  static bool _isObservableType(TypeMirror type) {
    final name = type.simpleName;
    if (observables.containsKey(name) ||
        name == 'TomList' ||
        name == 'TomMap' ||
        name == 'TomObservableEnum') {
      return true;
    }
    return type is ClassMirror && _isTomClass(type);
  }

  static bool _isTomClass(ClassMirror mirror) {
    ClassMirror? current = _superclassOf(mirror);
    while (current != null) {
      if (current.simpleName == 'TomClass') return true;
      current = _superclassOf(current);
    }
    return false;
  }

  static ClassMirror? _superclassOf(ClassMirror mirror) {
    try {
      return mirror.superclass;
    } on Object {
      return null;
    }
  }

  static bool _rendersItself(ClassMirror mirror) {
    if (mirror.declarations['toJson'] is MethodMirror) return true;
    if (mirror.declarations['jsonEncode'] is MethodMirror) return true;
    try {
      return mirror.superinterfaces.any(
        (i) => i.simpleName == 'TomJsonSerializable',
      );
    } on Object {
      return false;
    }
  }
}

/// A failure to describe a server as an OpenAPI document.
class TomOpenApiException extends TomException {
  /// A failure keyed `openapi.<area>.<condition>`.
  TomOpenApiException(super.key, super.defaultUserMessage, {super.parameters});
}

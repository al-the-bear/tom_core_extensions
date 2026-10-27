/// A tool's declared arguments, and the validation that runs before any tool
/// body does.
library;

import 'errors.dart';

/// The value kinds a declared argument may take.
///
/// Deliberately the JSON type system: the same schema is rendered as MCP's
/// `inputSchema` and as a provider's native tool declaration, and a kind with
/// no JSON spelling could not be rendered.
enum AgentToolValueType {
  string('string'),
  integer('integer'),
  boolean('boolean'),
  object('object'),
  array('array');

  const AgentToolValueType(this.jsonName);

  final String jsonName;

  bool accepts(Object value) => switch (this) {
    AgentToolValueType.string => value is String,
    // In Dart `true is! int`, but the guard states the intent.
    AgentToolValueType.integer => value is int && value is! bool,
    AgentToolValueType.boolean => value is bool,
    AgentToolValueType.object => value is Map,
    AgentToolValueType.array => value is List,
  };
}

/// One declared argument of a tool.
final class AgentToolArgument {
  final String name;
  final AgentToolValueType type;
  final bool required;
  final String description;

  /// When non-null, the only values this argument accepts.
  final List<String>? allowed;

  const AgentToolArgument(
    this.name,
    this.type, {
    this.required = false,
    this.description = '',
    this.allowed,
  });

  Map<String, Object?> toJsonSchema() => {
    'type': type.jsonName,
    if (description.isNotEmpty) 'description': description,
    'enum': ?allowed,
  };
}

/// A tool's declared argument set.
final class AgentToolSchema {
  final List<AgentToolArgument> arguments;

  const AgentToolSchema(this.arguments);

  static const empty = AgentToolSchema([]);

  /// [raw], checked and narrowed to the declared keys.
  ///
  /// An **unknown key is refused** rather than ignored. A silently dropped
  /// argument is the failure this exists to prevent: a caller that misspells
  /// an argument gets a refusal naming the word it typed, not a tool that ran
  /// against something else.
  ///
  /// A `null` value reads as absence, because a caller assembling a map from
  /// optional fields writes nulls and means "not stated".
  Map<String, Object?> validate(Map<String, Object?> raw) {
    final declared = {for (final a in arguments) a.name: a};
    for (final key in raw.keys) {
      if (!declared.containsKey(key)) {
        throw AgentToolException(
          AgentToolErrorCode.invalidArgument,
          'Unknown argument "$key". Declared: ${declared.keys.join(', ')}.',
          argument: key,
        );
      }
    }
    final out = <String, Object?>{};
    for (final argument in arguments) {
      final value = raw[argument.name];
      if (value == null) {
        if (argument.required) {
          throw AgentToolException(
            AgentToolErrorCode.invalidArgument,
            'Argument "${argument.name}" is required.',
            argument: argument.name,
          );
        }
        continue;
      }
      if (!argument.type.accepts(value)) {
        throw AgentToolException(
          AgentToolErrorCode.invalidArgument,
          'Argument "${argument.name}" must be a '
          '${argument.type.jsonName}, found ${value.runtimeType}.',
          argument: argument.name,
        );
      }
      final allowed = argument.allowed;
      if (allowed != null && !allowed.contains(value)) {
        throw AgentToolException(
          AgentToolErrorCode.invalidArgument,
          'Argument "${argument.name}" must be one of ${allowed.join(', ')}.',
          argument: argument.name,
        );
      }
      out[argument.name] = value;
    }
    return out;
  }

  /// The JSON-Schema object every presentation renders.
  Map<String, Object?> toJsonSchema() => {
    'type': 'object',
    'properties': {
      for (final argument in arguments) argument.name: argument.toJsonSchema(),
    },
    'required': [
      for (final argument in arguments)
        if (argument.required) argument.name,
    ],
    'additionalProperties': false,
  };
}

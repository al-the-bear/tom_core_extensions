/// Generates an OpenAPI 3.1 document from a server's endpoint annotations.
///
/// The endpoints are found exactly as the router finds them — the framework's
/// own API contracts registered, every `@tomService` and
/// `@TomApiImplementation` class scanned, each annotated method resolved to its
/// `TomEndpoint` — so the document lists what the server mounts, framework
/// endpoints included, and nothing it does not. It needs the server's
/// reflection seed and its API registrations, and no instance, configuration or
/// database: a build step can run it.
library;

import 'dart:convert';

import 'package:tom_core_server/tom_core_server.dart';

import 'openapi_document_check.dart';
import 'openapi_schema_builder.dart';

/// The `info` block of a generated document.
class TomOpenApiInfo {
  /// The API's title.
  final String title;

  /// The API's version — the server's, not the OpenAPI version.
  final String version;

  /// A longer description, or `null`.
  final String? description;

  /// An `info` block.
  const TomOpenApiInfo({
    required this.title,
    required this.version,
    this.description,
  });
}

/// Builds the OpenAPI document of the endpoints the reflector knows.
///
/// ```dart
/// registerMyApis();
/// initializeReflection();
/// final document = TomOpenApiDocumentGenerator(
///   info: const TomOpenApiInfo(title: 'My server', version: '1.0.0'),
/// ).generate();
/// ```
class TomOpenApiDocumentGenerator {
  /// The OpenAPI version written into every document.
  static const String openApiVersion = '3.1.0';

  /// The security scheme every authenticated operation names.
  static const String bearerScheme = 'bearerAuth';

  /// The security scheme a service account's API key satisfies — the
  /// alternative to [bearerScheme] on every authenticated operation.
  static const String apiKeyScheme = 'apiKeyAuth';

  /// The component describing the framework's error envelope.
  static const String errorSchema = 'TomError';

  /// The document's `info` block.
  final TomOpenApiInfo info;

  /// The base URLs a client may call, in order of preference.
  final List<String> servers;

  /// Path prefixes left out of the document, for a client that should not see
  /// part of the surface (`/scim`, say).
  final List<String> excludePathPrefixes;

  /// The service classes to describe, or `null` for every one the router
  /// would mount (`@tomService` and `@TomApiImplementation` classes).
  ///
  /// Naming them is for a document of part of a server, or for a class set no
  /// reflection root could carry without breaking the router built from it.
  final List<ClassMirror>? services;

  /// A generator for [info].
  TomOpenApiDocumentGenerator({
    required this.info,
    this.servers = const [],
    this.excludePathPrefixes = const [],
    this.services,
  });

  /// The parameter types the pipeline supplies from the request itself, which
  /// therefore are not part of what a caller sends.
  static const Set<String> contextTypes = {
    'TomPrincipal',
    'TomClientJwtToken',
    'TomExecutionContext',
    'TomRequestLogInfo',
  };

  /// The primitive parameter types the pipeline binds from a path variable or
  /// a query parameter.
  static const Set<String> primitiveParameterTypes = {
    'String',
    'int',
    'double',
    'num',
    'bool',
  };

  static const _methodOrder = [
    TomHttpMethod.get,
    TomHttpMethod.put,
    TomHttpMethod.post,
    TomHttpMethod.delete,
    TomHttpMethod.head,
    TomHttpMethod.patch,
    TomHttpMethod.trace,
  ];

  static const _bodyMethods = {
    TomHttpMethod.post,
    TomHttpMethod.put,
    TomHttpMethod.patch,
    TomHttpMethod.delete,
  };

  /// Builds the document. Throws [TomOpenApiException] when an endpoint cannot
  /// be described, or when the result fails [TomOpenApiDocumentCheck].
  Map<String, Object?> generate() {
    final routing = TomEndpointRouting();
    routing.registerFrameworkApis();
    final scan = routing.scanClasses();
    final schemas = TomOpenApiSchemaBuilder();
    final paths = <String, Map<String, Object?>>{};
    final tags = <String, Map<String, Object?>>{};

    for (final service
        in services ??
            [...scan.serviceInterfaces, ...scan.apiImplementations]) {
      for (final metadata in routing.getClassMethodMetadata(service)) {
        if (metadata.webSocket != null) continue;
        final path = openApiPath(metadata.endpoint.uri);
        if (excludePathPrefixes.any(path.startsWith)) continue;
        final tag = metadata.api?.id ?? service.simpleName;
        tags.putIfAbsent(
          tag,
          () => {
            'name': tag,
            if ((metadata.api?.description ?? metadata.api?.name) != null)
              'description': metadata.api?.description ?? metadata.api?.name,
          },
        );
        final methods = metadata.endpoint.methods
            .where((m) => m != TomHttpMethod.options)
            .toList();
        for (final method in methods) {
          final operations = paths.putIfAbsent(path, () => {});
          final key = operationKey(method);
          if (operations.containsKey(key)) {
            throw TomOpenApiException(
              'openapi.document.duplicate_route',
              '${key.toUpperCase()} $path is declared twice — by '
                  '${service.simpleName}.${metadata.methodMirror.simpleName} '
                  'and by an earlier endpoint.',
              parameters: {'path': path, 'method': key},
            );
          }
          operations[key] = _operation(
            service,
            metadata,
            method,
            path,
            tag,
            schemas,
            multipleMethods: methods.length > 1,
          );
        }
      }
    }

    schemas.components[errorSchema] = _errorEnvelope;
    final document = <String, Object?>{
      'openapi': openApiVersion,
      'info': {
        'title': info.title,
        'version': info.version,
        if (info.description != null) 'description': info.description,
      },
      if (servers.isNotEmpty)
        'servers': [
          for (final url in servers) {'url': url},
        ],
      'tags': [for (final name in tags.keys.toList()..sort()) tags[name]],
      'paths': {
        for (final path in paths.keys.toList()..sort())
          path: _ordered(paths[path]!),
      },
      'components': {
        'schemas': {
          for (final name in schemas.components.keys.toList()..sort())
            name: schemas.components[name],
        },
        'securitySchemes': {
          bearerScheme: {
            'type': 'http',
            'scheme': 'bearer',
            'bearerFormat': 'JWT',
          },
          apiKeyScheme: {
            'type': 'apiKey',
            'in': 'header',
            'name': 'X-API-Key',
            'description':
                "A service account's API key, `tomk.<keyId>.<secret>`; read "
                'only when no Authorization header is sent.',
          },
        },
      },
    };
    final problems = TomOpenApiDocumentCheck.problems(document);
    if (problems.isNotEmpty) {
      throw TomOpenApiException(
        'openapi.document.inconsistent',
        'The generated document is inconsistent:\n  ${problems.join('\n  ')}',
        parameters: {'problems': problems},
      );
    }
    return document;
  }

  /// [generate], encoded with two-space indentation and a final newline — the
  /// form written to disk, stable for a byte comparison.
  String generateJson() =>
      '${const JsonEncoder.withIndent('  ').convert(generate())}\n';

  /// A Tom route template as an OpenAPI path: `<name>` captures (the
  /// `shelf_router` spelling) become `{name}`, and an empty route is `/`.
  static String openApiPath(String uri) {
    final path = uri.replaceAllMapped(
      RegExp(r'<([^<>]+)>'),
      (m) => '{${m[1]}}',
    );
    return path.isEmpty ? '/' : path;
  }

  /// What [method] answers with, without its `Future`.
  ///
  /// Read from the method's reflected return [Type] when the reflection data
  /// carries one, because a `Type` keeps every type argument —
  /// `Future<List<Note>>` — where the return-type mirror keeps only the
  /// first level, and cannot resolve `Future<void>` at all.
  static TomOpenApiDartType returnTypeOf(MethodMirror method) {
    try {
      if (method.hasReflectedReturnType) {
        return TomOpenApiDartType.parse(
          '${method.reflectedReturnType}',
        ).awaited;
      }
    } on Object {
      // Fall through to the mirror.
    }
    return TomOpenApiDartType.fromMirror(method.returnType).awaited;
  }

  /// The key an operation for [method] has in a path item — the method name
  /// in lower case, as OpenAPI spells it.
  static String operationKey(TomHttpMethod method) => method.name.toLowerCase();

  /// The path variables of [path], in order.
  static List<String> captures(String path) => [
    for (final m in RegExp(r'\{([^{}]+)\}').allMatches(path)) m[1]!,
  ];

  Map<String, Object?> _operation(
    ClassMirror service,
    TomMethodMetadata metadata,
    TomHttpMethod method,
    String path,
    String tag,
    TomOpenApiSchemaBuilder schemas, {
    required bool multipleMethods,
  }) {
    final endpoint = metadata.endpoint;
    final apiEndpoint = metadata.apiEndpoint;
    final methodName = metadata.methodMirror.simpleName;
    var operationId =
        apiEndpoint?.id ??
        '${_lowerFirst(service.simpleName)}'
            '${_upperFirst(methodName)}';
    if (multipleMethods) operationId += _upperFirst(operationKey(method));

    final pathVariables = captures(path);
    final parameters = <Map<String, Object?>>[];
    final bound = <String>{};
    ClassMirror? dto;
    final fileParts = <String>[];
    var rawRequest = false;
    var freeForm = false;

    for (final parameter in metadata.methodMirror.parameters) {
      final type = TomOpenApiDartType.fromDeclaration(parameter);
      if (contextTypes.contains(type.name)) continue;
      if (type.name == 'Request') {
        rawRequest = true;
        continue;
      }
      if (type.name == 'TomMultipartForm') {
        freeForm = true;
        continue;
      }
      if (type.name == 'TomFormFile') {
        fileParts.add(parameter.simpleName);
        continue;
      }
      if (primitiveParameterTypes.contains(type.name)) {
        final inPath = pathVariables.contains(parameter.simpleName);
        bound.add(parameter.simpleName);
        parameters.add({
          'name': parameter.simpleName,
          'in': inPath ? 'path' : 'query',
          'required': inPath || !parameter.isOptional,
          'schema': schemas.schemaOf(type),
        });
        continue;
      }
      dto = type.mirror ?? TomOpenApiSchemaBuilder.resolveClass(type.name);
    }

    final dtoFields = dto == null ? null : _fields(dto, schemas);
    final mapping = endpoint.urlParameterMapping;
    final covered = <String>{};
    for (final variable in pathVariables) {
      if (bound.contains(variable)) continue;
      final field = mapping[variable] ?? variable;
      covered.add(field);
      parameters.add({
        'name': variable,
        'in': 'path',
        'required': true,
        'schema': _withoutNull(dtoFields?[field]) ?? {'type': 'string'},
      });
    }
    for (final entry in mapping.entries) {
      // A query parameter a primitive method parameter already binds is one
      // parameter, not two: the pipeline reads it once, by name.
      if (pathVariables.contains(entry.key) ||
          covered.contains(entry.value) ||
          bound.contains(entry.key)) {
        continue;
      }
      covered.add(entry.value);
      parameters.add({
        'name': entry.key,
        'in': 'query',
        'required': false,
        'schema': dtoFields?[entry.value] ?? {'type': 'string'},
      });
    }

    final requestBody = _requestBody(
      endpoint,
      method,
      dto,
      dtoFields,
      covered,
      fileParts,
      freeForm: freeForm,
      rawRequest: rawRequest,
      schemas: schemas,
    );

    final secured = _security(metadata.access, apiEndpoint);
    final description = apiEndpoint?.description;
    return {
      'tags': [tag],
      'operationId': operationId,
      'description': ?description,
      if (parameters.isNotEmpty) 'parameters': parameters,
      'requestBody': ?requestBody,
      'responses': _responses(metadata, schemas),
      'security': secured,
      'x-tom-access': ?_accessNote(metadata.access),
    };
  }

  Map<String, Object?>? _requestBody(
    TomEndpoint endpoint,
    TomHttpMethod method,
    ClassMirror? dto,
    Map<String, Map<String, Object?>>? dtoFields,
    Set<String> covered,
    List<String> fileParts, {
    required bool freeForm,
    required bool rawRequest,
    required TomOpenApiSchemaBuilder schemas,
  }) {
    if (!_bodyMethods.contains(method)) return null;
    final consumes = _mediaType(endpoint.consumes);
    final multipart =
        fileParts.isNotEmpty ||
        freeForm ||
        endpoint.consumes == TomMimeType.multipartFormData ||
        endpoint.consumes == TomMimeType.urlEncoded;
    if (multipart) {
      final fields = <String, Object?>{
        for (final entry in (dtoFields ?? const {}).entries)
          if (endpoint.formFields.isEmpty ||
              endpoint.formFields.contains(entry.key))
            entry.key: entry.value,
        for (final part in fileParts)
          part: {
            'type': 'string',
            'contentMediaType': 'application/octet-stream',
          },
      };
      return {
        'required': true,
        'content': {
          'multipart/form-data': {
            'schema': {
              'type': 'object',
              'properties': fields,
              if (fileParts.isNotEmpty) 'required': fileParts,
              if (freeForm) 'additionalProperties': true,
            },
          },
        },
      };
    }
    if (dto != null) {
      final remaining = dtoFields!.keys.where((f) => !covered.contains(f));
      if (remaining.isEmpty) return null;
      return {
        'required': true,
        'content': {
          consumes: {
            'schema': schemas.schemaOf(TomOpenApiDartType(dto.simpleName)),
          },
        },
      };
    }
    if (rawRequest && consumes != null) {
      return {
        'required': false,
        'content': {consumes: <String, Object?>{}},
      };
    }
    return null;
  }

  Map<String, Object?> _responses(
    TomMethodMetadata metadata,
    TomOpenApiSchemaBuilder schemas,
  ) {
    final declared = metadata.apiEndpoint?.responseType;
    final type = declared != null
        ? TomOpenApiDartType.parse('$declared')
        : returnTypeOf(metadata.methodMirror);
    final produces = _mediaType(metadata.endpoint.produces);
    final Map<String, Object?> success;
    if (type.name == 'TomRedirect') {
      return {
        '302': {
          'description': 'A redirect; the target is in the Location header.',
          'headers': {
            'Location': {
              'schema': {'type': 'string', 'format': 'uri'},
            },
          },
        },
        ..._errorResponses,
      };
    } else if (type.isVoid || produces == null) {
      success = {'description': 'Done; the response carries no body.'};
    } else if (type.name == 'Response') {
      success = {
        'description': 'The response the handler builds itself.',
        'content': {produces: <String, Object?>{}},
      };
    } else {
      success = {
        'description': 'The result.',
        'content': {
          produces: {'schema': schemas.schemaOf(type)},
        },
      };
    }
    return {'200': success, ..._errorResponses};
  }

  /// The error responses of every operation.
  ///
  /// `429` is stated for every operation because rate limits are deployment
  /// configuration the build cannot see: any operation may be limited, and a
  /// caller should be ready to wait the `Retry-After` it is given.
  ///
  /// `404` is stated for every operation because it is how the framework
  /// refuses a caller: a denial is a bare `404 Not found`, indistinguishable
  /// from a route that does not exist, so that a refusal does not confirm what
  /// it refuses (`TomEndpointHandler.accessDeniedResponse`). Every other
  /// failure is `default`: which status it carries is the server's error
  /// handler's decision, and so is its body — usually the framework envelope,
  /// which the schema names, but a handler may write its own.
  static const Map<String, Object?> _errorResponses = {
    '429': {
      'description':
          'Too many requests: a rate limit the deployment configured refused '
          'this one. Retry after the number of seconds Retry-After names.',
      'headers': {
        'Retry-After': {
          'description': 'Seconds to wait before the next request.',
          'schema': {'type': 'integer', 'minimum': 1},
        },
      },
      'content': _errorContent,
    },
    '404': {
      'description':
          'Not found — also the answer to a caller the endpoint refuses, '
          'which is deliberately indistinguishable from a missing route.',
      'content': {
        'text/plain': {
          'schema': {'type': 'string'},
        },
      },
    },
    'default': {
      'description':
          'A failure. The body is the framework error envelope unless the '
          "server's error handler writes its own.",
      'content': _errorContent,
    },
  };

  static const Map<String, Object?> _errorContent = {
    'application/json': {
      'schema': {
        'anyOf': [
          {r'$ref': '#/components/schemas/$errorSchema'},
          {'type': 'object'},
        ],
      },
    },
  };

  /// The operation's security requirement: none for a public endpoint, and
  /// for everything else a bearer token **or** an API key — two alternative
  /// requirements, as OpenAPI spells "either".
  ///
  /// An endpoint that declares no access rule falls under the server's global
  /// protection default, which requires an authenticated principal.
  static List<Map<String, Object?>> _security(
    TomAccessControl? access,
    TomApiEndpoint? apiEndpoint,
  ) {
    if (access is TomPublicAccess) return const [];
    if (access == null && apiEndpoint?.includeBearerAuthentication == false) {
      return const [];
    }
    return const [
      {bearerScheme: <String>[]},
      {apiKeyScheme: <String>[]},
    ];
  }

  /// What beyond authentication an operation requires, as the `x-tom-access`
  /// extension, or `null` for public and plainly authenticated operations.
  static Map<String, Object?>? _accessNote(TomAccessControl? access) {
    if (access == null ||
        access is TomPublicAccess ||
        access is TomAuthenticatedAccess) {
      return null;
    }
    if (access is TomRoleAccess) {
      return {'rule': 'roles', 'roles': access.roles};
    }
    return {'rule': access.runtimeType.toString()};
  }

  Map<String, Map<String, Object?>> _fields(
    ClassMirror dto,
    TomOpenApiSchemaBuilder schemas,
  ) {
    final name = schemas.schemaOf(TomOpenApiDartType(dto.simpleName));
    final ref = name[r'$ref'] as String?;
    final component = ref == null
        ? null
        : schemas.components[ref.substring(ref.lastIndexOf('/') + 1)];
    final properties = component?['properties'] as Map<String, Object?>?;
    return {
      for (final entry in (properties ?? const {}).entries)
        entry.key: entry.value as Map<String, Object?>,
    };
  }

  static Map<String, Object?>? _withoutNull(Map<String, Object?>? schema) {
    if (schema == null) return null;
    final type = schema['type'];
    if (type is List) {
      final rest = type.where((t) => t != 'null').toList();
      return {...schema, 'type': rest.length == 1 ? rest.single : rest};
    }
    return schema;
  }

  static String? _mediaType(TomMimeType type) =>
      type == TomMimeType.none ? null : '${type.primaryType}/${type.subType}';

  Map<String, Object?> _ordered(Map<String, Object?> operations) => {
    for (final method in _methodOrder)
      if (operations.containsKey(operationKey(method)))
        operationKey(method): operations[operationKey(method)],
  };

  static String _lowerFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  static String _upperFirst(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// The framework's error envelope (`tomErrorEnvelope`): only `errorType` is
  /// always present; every other member appears when the error carries it.
  static const Map<String, Object?> _errorEnvelope = {
    'type': 'object',
    'description':
        'Every error response of a Tom server. A member is absent, never '
        'null, when the error does not carry it.',
    'properties': {
      'errorType': {'type': 'string'},
      'errorKey': {'type': 'string'},
      'uuid': {'type': 'string'},
      'autoLog': {'type': 'boolean'},
      'requestUuid': {
        'type': ['string', 'null'],
      },
      'clientThrow': {'type': 'boolean'},
      'loginFailure': {'type': 'string'},
    },
    'required': ['errorType'],
  };
}

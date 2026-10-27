/// @docImport 'src/cli/openapi_tool.dart';
/// @docImport 'src/client/dart_client_generator.dart';
/// @docImport 'src/document/openapi_document_generator.dart';
/// @docImport 'src/validation/openapi_validator.dart';
/// OpenAPI 3.1 for Tom servers.
///
/// Generates a server's OpenAPI document from its endpoint annotations and
/// reflected DTOs ([TomOpenApiDocumentGenerator]), validates documents against
/// the OpenAPI 3.1 meta-schema ([TomOpenApiValidator]), and generates a typed
/// Dart client that depends on `package:http` only
/// ([TomOpenApiDartClientGenerator]). [runTomOpenApiTool] is the
/// `tom_build_base` command-line tool over all three.
library;

export 'src/cli/openapi_tool.dart';
export 'src/client/dart_client_generator.dart';
export 'src/document/openapi_document_check.dart';
export 'src/document/openapi_document_generator.dart';
export 'src/document/openapi_schema_builder.dart';
export 'src/validation/openapi_validator.dart';

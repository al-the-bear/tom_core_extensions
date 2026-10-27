/// The `openapi` tool for the commands that read a document only:
/// `:dart-client` and `:validate`.
///
///     dart run tom_core_openapi:openapi :validate --input openapi/openapi.json
///     dart run tom_core_openapi:openapi :dart-client \
///         --input openapi/openapi.json --output lib/app_api.dart \
///         --client-name AppApi
///
/// `:document` needs a server's reflection seed and runs from that server's
/// own `tool/openapi.dart` instead.
library;

import 'package:tom_core_openapi/tom_core_openapi.dart';

Future<void> main(List<String> args) => runTomOpenApiTool(args);

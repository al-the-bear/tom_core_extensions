/// The `openapi` command-line tool, built on `tom_build_base`.
///
/// Three commands, named with `tom_build_base`'s `:command` syntax:
///
///  * `:document` writes a server's OpenAPI document from its endpoint
///    annotations. It reads the server's reflection seed, so it runs **inside
///    the server package** through a two-line `tool/openapi.dart` that calls
///    [runTomOpenApiTool] with the server's own preparation (API registration,
///    `initializeReflection`);
///  * `:dart-client` writes a typed Dart client from a document;
///  * `:validate` checks documents against the OpenAPI 3.1 meta-schema and the
///    cross-reference rules.
///
/// Each writing command takes `--check`, which compares instead of writing and
/// fails when the file on disk is not what generation produces — the command a
/// build or a test runs to keep a committed artefact honest.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_build_base/tom_build_base_v2.dart';

import '../client/dart_client_generator.dart';
import '../document/openapi_document_generator.dart';
import '../validation/openapi_validator.dart';

/// The tool's version.
const String tomOpenApiToolVersion = '0.1.0';

/// The document path the commands default to, relative to the package root.
const String defaultOpenApiDocumentPath = 'openapi/openapi.json';

const _checkOption = OptionDefinition.flag(
  name: 'check',
  description:
      'Compare with the file on disk instead of writing it; fail when it is '
      'stale',
);

/// The `:document` command.
const openApiDocumentCommand = CommandDefinition(
  name: 'document',
  description:
      "Write the server's OpenAPI 3.1 document from its endpoint annotations",
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: [
    OptionDefinition.option(
      name: 'output',
      description: 'The document to write',
      defaultValue: defaultOpenApiDocumentPath,
      valueName: 'file',
    ),
    OptionDefinition.option(
      name: 'title',
      description: "The API title (default: the package's name)",
      valueName: 'text',
    ),
    OptionDefinition.option(
      name: 'api-version',
      description: "The API version (default: the package's version)",
      valueName: 'version',
    ),
    OptionDefinition.option(
      name: 'description',
      description: 'A description of the API',
      valueName: 'text',
    ),
    OptionDefinition.multi(
      name: 'server',
      description: 'A base URL clients may call (repeatable)',
      valueName: 'url',
    ),
    OptionDefinition.multi(
      name: 'exclude',
      description: 'Leave out paths starting with this prefix (repeatable)',
      valueName: 'prefix',
    ),
    _checkOption,
  ],
  examples: [
    'dart run tool/openapi.dart :document',
    'dart run tool/openapi.dart :document --server http://localhost:8080',
    'dart run tool/openapi.dart :document --check',
  ],
);

/// The `:dart-client` command.
const openApiDartClientCommand = CommandDefinition(
  name: 'dart-client',
  description: 'Write a typed Dart client (package:http only) from a document',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: [
    OptionDefinition.option(
      name: 'input',
      description: 'The OpenAPI document to read',
      defaultValue: defaultOpenApiDocumentPath,
      valueName: 'file',
    ),
    OptionDefinition.option(
      name: 'output',
      description: 'The Dart library to write',
      mandatory: true,
      valueName: 'file',
    ),
    OptionDefinition.option(
      name: 'client-name',
      description: 'The name of the generated client class',
      mandatory: true,
      valueName: 'Name',
    ),
    _checkOption,
  ],
  examples: [
    'openapi :dart-client --input openapi/openapi.json '
        '--output lib/app_api.dart --client-name AppApi',
  ],
);

/// The `:validate` command.
const openApiValidateCommand = CommandDefinition(
  name: 'validate',
  description:
      'Validate documents against the OpenAPI 3.1 meta-schema and the '
      'cross-reference rules',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: [
    OptionDefinition.multi(
      name: 'input',
      description:
          'A document to validate (repeatable; default: '
          '$defaultOpenApiDocumentPath)',
      valueName: 'file',
    ),
  ],
  examples: [
    'openapi :validate',
    'openapi :validate --input a.json --input b.json',
  ],
);

/// The tool definition.
final tomOpenApiTool = ToolDefinition(
  name: 'openapi',
  description:
      'Generate, validate and consume OpenAPI 3.1 documents of Tom servers',
  version: tomOpenApiToolVersion,
  versionString: 'Tom OpenAPI $tomOpenApiToolVersion',
  mode: ToolMode.multiCommand,
  defaultCommand: 'validate',
  features: const NavigationFeatures(
    projectTraversal: false,
    gitTraversal: false,
    recursiveScan: false,
    interactiveMode: false,
    dryRun: false,
    jsonOutput: false,
    verbose: true,
  ),
  commands: const [
    openApiDocumentCommand,
    openApiDartClientCommand,
    openApiValidateCommand,
  ],
  helpFooter: '''
`:document` needs the server's reflection seed, so it runs from a small entry
point in the server package:

  // tool/openapi.dart
  import 'package:tom_core_openapi/tom_core_openapi.dart';
  import '../bin/server_start.reflection.dart';

  Future<void> main(List<String> args) => runTomOpenApiTool(args, prepare: () {
    registerMyApis();
    initializeReflection();
  });

`:dart-client` and `:validate` read a document only and run anywhere.
''',
);

/// Runs the tool with [args].
///
/// [prepare] makes the server's endpoints visible — registering its API
/// contracts and installing its reflection seed — and is called before
/// `:document` generates; the other commands do not need it.
///
/// [title], [description] and [servers] are the document's defaults, used
/// where the command line does not give `--title`, `--description` or
/// `--server`. Stating them here, in the server's `tool/openapi.dart`, is what
/// makes `:document --check` reproduce the committed document without anyone
/// remembering the arguments it was written with.
Future<void> runTomOpenApiTool(
  List<String> args, {
  void Function()? prepare,
  String? title,
  String? description,
  List<String> servers = const [],
}) async {
  final normalized = ToolRunner.normalizeArgs(args);
  await runWithConsoleMarkdown(() async {
    final runner = ToolRunner(
      tool: tomOpenApiTool,
      executors: createTomOpenApiExecutors(
        prepare: prepare,
        title: title,
        description: description,
        servers: servers,
      ),
    );
    await runner.runToCompletion(normalized);
  });
}

/// The executors of the three commands; see [runTomOpenApiTool] for the
/// parameters.
Map<String, CommandExecutor> createTomOpenApiExecutors({
  void Function()? prepare,
  String? title,
  String? description,
  List<String> servers = const [],
}) => {
  'document': _DocumentExecutor(prepare, title, description, servers),
  'dart-client': _DartClientExecutor(),
  'validate': _ValidateExecutor(),
};

Map<String, dynamic> _options(CliArgs args) => {
  ...args.extraOptions,
  for (final command in args.commandArgs.values) ...command.options,
};

List<String> _multi(Object? value) => switch (value) {
  null => const [],
  final String single => [single],
  final Iterable<Object?> many => [for (final v in many) '$v'],
  _ => ['$value'],
};

/// Writes [content] to [path], or with [check] compares and reports.
ToolResult _writeOrCheck(String path, String content, {required bool check}) {
  final file = File(path);
  if (check) {
    final current = file.existsSync() ? file.readAsStringSync() : null;
    if (current == content) {
      print('$path is current.');
      return const ToolResult.success();
    }
    return ToolResult.failure(
      current == null
          ? '$path does not exist; generate it.'
          : '$path is stale; regenerate it.',
    );
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  print('Wrote $path.');
  return const ToolResult.success();
}

/// The `name:` and `version:` of the pubspec in the working directory.
({String? name, String? version}) _pubspec() {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) return (name: null, version: null);
  final text = file.readAsStringSync();
  String? field(String key) =>
      RegExp('^$key:\\s*(\\S+)', multiLine: true).firstMatch(text)?.group(1);
  return (name: field('name'), version: field('version'));
}

/// Formats Dart [source] with `dart format`, through a scratch file in
/// `.dart_tool/` of the working directory.
Future<String> formatDartSource(String source) async {
  final root = Directory(p.join('.dart_tool', 'tom_core_openapi'))
    ..createSync(recursive: true);
  // A directory of its own per call: concurrent callers in one process share
  // a pid, so a name derived from it would collide.
  final scratch = root.createTempSync('format_');
  final file = File(p.join(scratch.path, 'source.dart'));
  try {
    file.writeAsStringSync(source);
    final dart =
        p.basenameWithoutExtension(Platform.resolvedExecutable) == 'dart'
        ? Platform.resolvedExecutable
        : 'dart';
    final result = await Process.run(dart, ['format', file.path]);
    if (result.exitCode != 0) {
      throw StateError('dart format failed: ${result.stderr}${result.stdout}');
    }
    return file.readAsStringSync();
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

class _DocumentExecutor extends CommandExecutor {
  _DocumentExecutor(this.prepare, this.title, this.description, this.servers);

  final void Function()? prepare;
  final String? title;
  final String? description;
  final List<String> servers;

  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) async =>
      ItemResult.failure(
        path: context.path,
        name: context.name,
        error: 'openapi document is a global command',
      );

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    final prepare = this.prepare;
    if (prepare == null) {
      return const ToolResult.failure(
        "document reads the server's reflection seed and must be run from the "
        "server package's tool/openapi.dart (see --help).",
      );
    }
    final options = _options(args);
    final pubspec = _pubspec();
    prepare();
    final generator = TomOpenApiDocumentGenerator(
      info: TomOpenApiInfo(
        title: (options['title'] as String?) ?? title ?? pubspec.name ?? 'API',
        version:
            (options['api-version'] as String?) ?? pubspec.version ?? '0.0.0',
        description: (options['description'] as String?) ?? description,
      ),
      servers: _multi(options['server']).isEmpty
          ? servers
          : _multi(options['server']),
      excludePathPrefixes: _multi(options['exclude']),
    );
    return _writeOrCheck(
      (options['output'] as String?) ?? defaultOpenApiDocumentPath,
      generator.generateJson(),
      check: options['check'] == true,
    );
  }
}

class _DartClientExecutor extends CommandExecutor {
  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) async =>
      ItemResult.failure(
        path: context.path,
        name: context.name,
        error: 'openapi dart-client is a global command',
      );

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    final options = _options(args);
    final input = (options['input'] as String?) ?? defaultOpenApiDocumentPath;
    final output = options['output'] as String?;
    final clientName = options['client-name'] as String?;
    if (output == null || clientName == null) {
      return const ToolResult.failure(
        'dart-client needs --output and --client-name.',
      );
    }
    final document =
        jsonDecode(File(input).readAsStringSync()) as Map<String, Object?>;
    final source = TomOpenApiDartClientGenerator(
      clientName: clientName,
      regenerateCommand:
          'dart run tom_core_openapi:openapi :dart-client --input $input '
          '--output $output --client-name $clientName',
    ).generate(document);
    return _writeOrCheck(
      output,
      await formatDartSource(source),
      check: options['check'] == true,
    );
  }
}

class _ValidateExecutor extends CommandExecutor {
  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) async =>
      ItemResult.failure(
        path: context.path,
        name: context.name,
        error: 'openapi validate is a global command',
      );

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    final inputs = _multi(_options(args)['input']);
    final validator = TomOpenApiValidator();
    var failed = false;
    for (final input
        in inputs.isEmpty ? [defaultOpenApiDocumentPath] : inputs) {
      final validation = await validator.validateFile(input);
      print(validation);
      failed = failed || !validation.isValid;
    }
    return failed
        ? const ToolResult.failure('validation failed or was not measured')
        : const ToolResult.success();
  }
}

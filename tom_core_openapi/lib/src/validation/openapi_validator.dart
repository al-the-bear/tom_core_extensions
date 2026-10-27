/// Validates OpenAPI documents: the cross-reference rules in Dart, the
/// official OpenAPI 3.1 meta-schema through Python.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../document/openapi_document_check.dart';

/// The outcome of validating one document.
class TomOpenApiValidation {
  /// The document that was validated.
  final String path;

  /// Whether the meta-schema validation ran. When it did not, [reason] says
  /// why, and the document is **not** valid: a check that did not run has not
  /// passed.
  final bool measured;

  /// The faults found, one sentence each.
  final List<String> errors;

  /// Why the meta-schema validation did not run, when [measured] is false.
  final String? reason;

  /// A validation outcome.
  const TomOpenApiValidation({
    required this.path,
    required this.measured,
    this.errors = const [],
    this.reason,
  });

  /// Whether the document was measured and found sound.
  bool get isValid => measured && errors.isEmpty;

  @override
  String toString() => isValid
      ? '$path: valid'
      : !measured
      ? '$path: NOT MEASURED — $reason'
      : '$path: ${errors.length} fault(s)\n  ${errors.join('\n  ')}';
}

/// Validates documents against the OpenAPI 3.1 meta-schema (the 2022-10-07
/// *schema-base* variant, which also checks every embedded schema object)
/// and against [TomOpenApiDocumentCheck].
///
/// The meta-schema validation runs `validate_openapi.py` beside this file with
/// Python's `jsonschema`; [python] names the interpreter (`python3`, or `py -3`
/// on Windows, overridable with the `TOM_PYTHON` environment variable).
class TomOpenApiValidator {
  /// The interpreter command and its leading arguments.
  final List<String> python;

  /// A validator using [python], or the platform default.
  TomOpenApiValidator({List<String>? python})
    : python = python ?? defaultPython();

  /// `TOM_PYTHON` split on spaces, else `py -3` on Windows and `python3`
  /// elsewhere.
  static List<String> defaultPython() {
    final configured = Platform.environment['TOM_PYTHON'];
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim().split(RegExp(r'\s+'));
    }
    return Platform.isWindows ? const ['py', '-3'] : const ['python3'];
  }

  /// Validates [document], held in memory, through a scratch copy under
  /// `.dart_tool/tom_core_openapi/` of the working directory.
  Future<TomOpenApiValidation> validateDocument(
    Map<String, Object?> document,
  ) async {
    final root = Directory(p.join('.dart_tool', 'tom_core_openapi'))
      ..createSync(recursive: true);
    final scratch = root.createTempSync('validate_');
    final file = File(p.join(scratch.path, 'document.json'));
    try {
      file.writeAsStringSync(jsonEncode(document));
      final validation = await validateFile(file.path);
      return TomOpenApiValidation(
        path: '(in memory)',
        measured: validation.measured,
        errors: validation.errors,
        reason: validation.reason,
      );
    } finally {
      scratch.deleteSync(recursive: true);
    }
  }

  /// Validates the document at [documentPath].
  Future<TomOpenApiValidation> validateFile(String documentPath) async {
    final Map<String, Object?> document;
    try {
      document =
          jsonDecode(await File(documentPath).readAsString())
              as Map<String, Object?>;
    } on Object catch (error) {
      return TomOpenApiValidation(
        path: documentPath,
        measured: true,
        errors: ['the file is not a JSON object: $error'],
      );
    }
    final structural = TomOpenApiDocumentCheck.problems(document);
    final directory = p.dirname(await _resource('validate_openapi.py'));
    final ProcessResult run;
    try {
      run = await Process.run(python.first, [
        ...python.skip(1),
        p.join(directory, 'validate_openapi.py'),
        p.join(directory, 'schemas'),
        documentPath,
      ]);
    } on ProcessException catch (error) {
      return TomOpenApiValidation(
        path: documentPath,
        measured: false,
        errors: structural,
        reason:
            'the interpreter "${python.join(' ')}" could not be started: '
            '${error.message}',
      );
    }
    final Object? report;
    try {
      report = jsonDecode('${run.stdout}'.trim());
    } on FormatException {
      return TomOpenApiValidation(
        path: documentPath,
        measured: false,
        errors: structural,
        reason: 'the validator answered no report: ${run.stderr}',
      );
    }
    if (report is Map && report['error'] != null) {
      return TomOpenApiValidation(
        path: documentPath,
        measured: false,
        errors: structural,
        reason: '${report['error']}',
      );
    }
    final documents = (report as Map)['documents'] as List;
    final schemaErrors = [
      for (final e in (documents.single as Map)['errors'] as List)
        '${(e as Map)['at']}: ${e['message']}',
    ];
    return TomOpenApiValidation(
      path: documentPath,
      measured: true,
      errors: [...structural, ...schemaErrors],
    );
  }

  /// The file path of a resource shipped in this library's directory.
  static Future<String> _resource(String name) async {
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:tom_core_openapi/src/validation/$name'),
    );
    if (uri == null) {
      throw StateError(
        'package:tom_core_openapi is not resolvable from this process, so '
        'the vendored meta-schema cannot be found',
      );
    }
    return uri.toFilePath();
  }
}

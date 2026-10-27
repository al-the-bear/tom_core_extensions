/// The command-line tool: the three commands, `--check`, and the refusal of
/// `:document` where no server's reflection is installed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

import 'fixtures/openapi_fixture.dart';
import 'fixtures/openapi_fixture.reflection.dart';

Future<ToolResult> _run(List<String> args, {void Function()? prepare}) =>
    ToolRunner(
      tool: tomOpenApiTool,
      executors: createTomOpenApiExecutors(
        prepare: prepare,
        title: 'Fixture',
        servers: const ['http://localhost:9999'],
      ),
      output: StringBuffer(),
    ).run(args);

void main() {
  final scratch = Directory(p.join('.dart_tool', 'tom_core_openapi', 'tool'));
  final document = p.join(scratch.path, 'openapi.json');
  final client = p.join(scratch.path, 'fixture_api.dart');

  setUpAll(() => scratch.createSync(recursive: true));
  tearDownAll(() => scratch.deleteSync(recursive: true));

  void prepare() {
    registerFixtureApis();
    initializeReflection();
  }

  test(':document without a server preparation is refused', () async {
    final result = await _run([':document', '--output', document]);
    expect(result.success, isFalse);
    expect(result.errorMessage, contains('tool/openapi.dart'));
  });

  test(':document writes the defaults, and --check then passes', () async {
    expect(
      (await _run([
        ':document',
        '--output',
        document,
      ], prepare: prepare)).success,
      isTrue,
    );
    final written = jsonDecode(File(document).readAsStringSync()) as Map;
    expect((written['info'] as Map)['title'], 'Fixture');
    expect(written['servers'], [
      {'url': 'http://localhost:9999'},
    ]);
    expect(
      (await _run([
        ':document',
        '--output',
        document,
        '--check',
      ], prepare: prepare)).success,
      isTrue,
    );
  });

  test(':document --check fails on a stale document', () async {
    await _run([':document', '--output', document], prepare: prepare);
    File(document).writeAsStringSync('{}\n');
    final result = await _run([
      ':document',
      '--output',
      document,
      '--check',
    ], prepare: prepare);
    expect(result.success, isFalse);
    expect(result.errorMessage, contains('stale'));
  });

  test(':dart-client writes a client and --check holds it', () async {
    await _run([':document', '--output', document], prepare: prepare);
    final arguments = [
      ':dart-client',
      '--input',
      document,
      '--output',
      client,
      '--client-name',
      'FixtureApi',
    ];
    expect((await _run(arguments)).success, isTrue);
    expect(File(client).readAsStringSync(), contains('class FixtureApi {'));
    expect((await _run([...arguments, '--check'])).success, isTrue);
    File(client).writeAsStringSync('// edited\n');
    expect((await _run([...arguments, '--check'])).success, isFalse);
  });

  test(
    ':validate passes a generated document and fails a broken one',
    () async {
      await _run([':document', '--output', document], prepare: prepare);
      expect((await _run([':validate', '--input', document])).success, isTrue);
      File(document).writeAsStringSync('{"openapi": "3.1.0"}');
      expect((await _run([':validate', '--input', document])).success, isFalse);
    },
  );
}

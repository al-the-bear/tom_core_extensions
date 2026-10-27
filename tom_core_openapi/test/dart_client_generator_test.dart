/// The generated Dart client, compiled and run.
///
/// The client generated from the fixture's document is written into a scratch
/// package under `.dart_tool/`, analyzed, and then driven by a small program
/// against an in-process HTTP server that records every request. So the test
/// reads both directions of the wire: what the client sends (method, path,
/// query, headers, body) and what it makes of what it receives.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_core_openapi/tom_core_openapi.dart';

import 'fixtures/openapi_fixture.dart';
import 'fixtures/openapi_fixture.reflection.dart';

/// The program the scratch package runs: one call per line of output.
const _probe = r'''
import 'dart:convert';

import 'package:fixture_client/fixture_api.dart';

Future<void> main(List<String> args) async {
  final api = FixtureApi(Uri.parse(args.single), bearerToken: 'tok');
  final out = <String, Object?>{};
  final note = await api.fixtureNoteServiceRead(id: 'n 1');
  out['read'] = {
    'id': note.id,
    'createdAt': note.createdAt.toUtc().toIso8601String(),
    'author': note.author?.name,
    'priority': note.priority,
  };
  final list = await api.fixtureNoteServiceList(author: 'ann', limit: 2);
  out['list'] = list.length;
  final created = await api.fixtureNoteServiceCreate(
    body: FixtureNote(
      id: '',
      text: 'hello',
      createdAt: DateTime.utc(2026, 1, 2),
      tags: ['a'],
      counts: {'x': 1},
      author: FixtureAuthor(name: 'ann'),
    ),
  );
  out['created'] = created.id;
  await api.fixtureNoteServiceDelete(id: '7');
  final observable = await api.fixtureNoteServiceObservable();
  out['observable'] = {
    'title': observable.title,
    'due': observable.due?.toUtc().toIso8601String(),
    'labels': observable.labels,
  };
  try {
    await api.fixtureListAll();
    out['refused'] = 'no';
  } on FixtureApiException catch (e) {
    out['refused'] = {
      'status': e.statusCode,
      'key': e.errorKey,
      'retryAfter': e.retryAfter?.inSeconds,
    };
  }
  final keyed = FixtureApi(Uri.parse(args.single), apiKey: 'tomk.k1.secret');
  out['keyed'] = (await keyed.fixtureNoteServiceList(author: 'key')).length;
  // A public operation sends no key either.
  await keyed.fixtureNoteServiceRead(id: 'n 1');
  keyed.close();
  print(jsonEncode(out));
  api.close();
}
''';

void main() {
  late Directory package;
  late String source;

  setUpAll(() async {
    registerFixtureApis();
    initializeReflection();
    final document = TomOpenApiDocumentGenerator(
      info: const TomOpenApiInfo(title: 'Fixture', version: '1.0.0'),
    ).generate();
    source = await formatDartSource(
      TomOpenApiDartClientGenerator(
        clientName: 'FixtureApi',
      ).generate(document),
    );
    package = Directory(p.join('.dart_tool', 'tom_core_openapi', 'client_test'))
      ..createSync(recursive: true);
    File(p.join(package.path, 'pubspec.yaml')).writeAsStringSync('''
name: fixture_client
publish_to: none
environment:
  sdk: ^3.10.0
dependencies:
  http: ^1.6.0
''');
    Directory(p.join(package.path, 'lib')).createSync(recursive: true);
    Directory(p.join(package.path, 'bin')).createSync(recursive: true);
    File(
      p.join(package.path, 'lib', 'fixture_api.dart'),
    ).writeAsStringSync(source);
    File(p.join(package.path, 'bin', 'probe.dart')).writeAsStringSync(_probe);
    final get = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
  });

  test('the generated library is headed as generated and needs only http', () {
    expect(source, startsWith('// GENERATED CODE — DO NOT EDIT.'));
    final imports = RegExp(
      r"^import '([^']+)'",
      multiLine: true,
    ).allMatches(source).map((m) => m[1]).toList();
    expect(imports, ['dart:convert', 'package:http/http.dart']);
  });

  test('it declares a model per object schema and none for an opaque one', () {
    expect(source, contains('class FixtureNote {'));
    expect(source, contains('class FixtureObservable {'));
    expect(source, isNot(contains('class FixtureRendered')));
  });

  test('it analyzes clean', () async {
    final analyze = await Process.run(Platform.resolvedExecutable, [
      'analyze',
      '--fatal-infos',
      'lib',
    ], workingDirectory: package.path);
    expect(analyze.exitCode, 0, reason: '${analyze.stdout}${analyze.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'it sends what the document says and decodes what it receives',
    () async {
      final requests = <Map<String, Object?>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final note = {
        'id': 'n 1',
        'text': 't',
        'priority': null,
        'createdAt': '2026-01-02T03:04:05.000Z',
        'tags': ['a'],
        'counts': {'x': 1},
        'author': null,
        'secret': '',
      };
      unawaited(
        server.forEach((request) async {
          final body = await utf8.decodeStream(request);
          requests.add({
            'method': request.method,
            'path': request.uri.path,
            'query': request.uri.queryParameters,
            'auth': request.headers.value('authorization'),
            if (request.headers.value('x-api-key') != null)
              'apiKey': request.headers.value('x-api-key'),
            'body': body.isEmpty ? null : jsonDecode(body),
          });
          final path = request.uri.path;
          Object? answer;
          var status = 200;
          if (path == '/fixture/notes/n%201') {
            answer = note;
          } else if (path == '/fixture/notes' && request.method == 'GET') {
            answer = [note, note];
          } else if (path == '/fixture/notes') {
            answer = {...note, 'id': 'new'};
          } else if (path == '/fixture/observable') {
            answer = {
              'title': 'T',
              'due': '@!@2026-01-02T03:04:05.000Z',
              'labels': ['l'],
            };
          } else if (path == '/fixture-api/all') {
            status = 429;
            request.response.headers.set('retry-after', '17');
            answer = {'errorType': 'X', 'errorKey': 'rate_limit.exceeded'};
          }
          request.response
            ..statusCode = status
            ..headers.contentType = ContentType.json;
          if (answer != null) request.response.write(jsonEncode(answer));
          await request.response.close();
        }),
      );
      try {
        final run = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/probe.dart',
          'http://127.0.0.1:${server.port}',
        ], workingDirectory: package.path);
        expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
        final out = jsonDecode('${run.stdout}'.trim().split('\n').last) as Map;

        expect(out['read'], {
          'id': 'n 1',
          'createdAt': '2026-01-02T03:04:05.000Z',
          'author': null,
          'priority': null,
        });
        expect(out['list'], 2);
        expect(out['created'], 'new');
        expect(out['observable'], {
          'title': 'T',
          'due': '2026-01-02T03:04:05.000Z',
          'labels': ['l'],
        });
        expect(out['refused'], {
          'status': 429,
          'key': 'rate_limit.exceeded',
          'retryAfter': 17,
        });
        expect(out['keyed'], 2);
        // With no bearer token, a secured operation carries the API key, and
        // a public one carries nothing.
        final keyedList = requests.firstWhere(
          (r) => (r['query'] as Map)['author'] == 'key',
        );
        expect(keyedList['apiKey'], 'tomk.k1.secret');
        expect(keyedList['auth'], isNull);
        expect(requests.last['apiKey'], isNull);

        expect(requests[0], {
          'method': 'GET',
          // The path variable is percent-encoded into its one segment.
          'path': '/fixture/notes/n%201',
          'query': <String, String>{},
          // A public operation never carries the token.
          'auth': null,
          'body': null,
        });
        expect(requests[1]['query'], {'author': 'ann', 'limit': '2'});
        expect(requests[1]['auth'], 'Bearer tok');
        expect(requests[2]['method'], 'POST');
        expect(requests[2]['body'], {
          'id': '',
          'text': 'hello',
          'createdAt': '2026-01-02T00:00:00.000Z',
          'tags': ['a'],
          'counts': {'x': 1},
          'author': {'name': 'ann'},
        });
        expect(requests[3], {
          'method': 'DELETE',
          'path': '/fixture/notes/7',
          'query': <String, String>{},
          'auth': 'Bearer tok',
          'body': null,
        });
      } finally {
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

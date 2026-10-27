/// The entry point stays platform-neutral, executed rather than asserted.
///
/// Two guards, because they catch disjoint failures:
///
/// 1. A walk of the import closure inside this package: no library reachable
///    from `tom_core_sync.dart` imports `dart:io`, a browser API, Flutter,
///    a container format or a network stack. `dart compile js` *accepts*
///    `dart:io` (the SDK ships a throwing stub), so only a walk catches it
///    before a web build does.
/// 2. A real dart2js compile of a program using the package, which catches
///    codegen-level problems the VM never sees.
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/scratch.dart';

final _directive = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''');

/// The external URIs reachable from [entry] inside this package.
Set<String> reached(String entry, {Set<String>? visited}) {
  final seen = visited ?? <String>{};
  final external = <String>{};
  final queue = [File(entry).absolute.path];
  while (queue.isNotEmpty) {
    final path = queue.removeLast();
    if (!seen.add(path)) continue;
    final file = File(path);
    if (!file.existsSync()) continue;
    for (final line in file.readAsLinesSync()) {
      final uri = _directive.firstMatch(line)?.group(1);
      if (uri == null) continue;
      if (uri.startsWith('package:tom_core_sync/')) {
        queue.add(
          '${Directory.current.absolute.path}/lib/'
          '${uri.substring('package:tom_core_sync/'.length)}',
        );
      } else if (uri.contains(':')) {
        external.add(uri);
      } else {
        queue.add(File('${file.parent.path}/$uri').absolute.path);
      }
    }
  }
  return external;
}

void main() {
  test('SYNC-WEB-1: nothing reachable from tom_core_sync.dart is '
      'platform-, format- or network-bound', () {
    final visited = <String>{};
    final uris = reached('lib/tom_core_sync.dart', visited: visited);
    expect(
      visited.length,
      greaterThan(8),
      reason: 'the walk found almost nothing, so it proved nothing',
    );
    for (final banned in [
      'dart:io',
      'dart:ui',
      'package:web/',
      'package:flutter/',
      'package:kdbx/',
      'package:tom_kdbx/',
      'package:tom_github_api/',
      'package:http/',
      'package:tom_core_storage/io.dart',
      'package:tom_core_storage/github.dart',
      'package:tom_core_storage/web.dart',
      'package:tom_core_storage/cipher.dart',
    ]) {
      expect(uris.where((u) => u.startsWith(banned)), isEmpty, reason: banned);
    }
  });

  test('SYNC-WEB-2: a program over the package compiles under dart2js', () async {
    final dart = Platform.resolvedExecutable;
    expect(
      dart.endsWith('dart') || dart.endsWith('dart.exe'),
      isTrue,
      reason:
          'run this suite with `dart test`; under another runner there is no '
          'Dart CLI to compile with',
    );
    final tmp = scratchDirectory('web_safe').createTempSync('sync-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final entry = File('${tmp.path}/main.dart')
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:typed_data';

import 'package:tom_core_storage/tom_core_storage.dart';
import 'package:tom_core_sync/tom_core_sync.dart';

class Codec implements TomRecordCodec<String> {
  @override
  String idOf(String record) => record;
  @override
  DateTime? modifiedOf(String record) => null;
  @override
  Uint8List canonicalBytes(String record) => utf8.encode(record);
}

Future<void> main() async {
  final merged = tomMergeKeyed(
    base: const {'a': 'a'},
    ours: const {'a': 'b'},
    theirs: const {'a': 'c'},
    codec: Codec(),
    tie: TomMergeTie.canonicalOrder,
  );
  final history = TomMediumHistoryStore(
    medium: TomMemoryBundleMedium(),
    stamp: tomHistoryStamp(DateTime.utc(2026)),
  );
  await history.retain('a', merged.merged['a']!);
  final scheduler = TomSyncScheduler(policy: const TomFixedSyncPolicy());
  print([merged.conflicts.length, await history.versionsOf('a'), scheduler]);
  await scheduler.dispose();
}
''');
    final result = await Process.run(dart, [
      'compile',
      'js',
      '--no-source-maps',
      '--packages=${Directory.current.absolute.path}/.dart_tool/package_config.json',
      '-o',
      '${tmp.path}/out.js',
      entry.path,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'dart2js rejected it:\n${result.stdout}\n${result.stderr}',
    );
  });
}

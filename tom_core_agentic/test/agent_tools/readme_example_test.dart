/// What the README example prints, asserted — the expectations are written
/// here, so the test states a claim of its own rather than agreeing with the
/// example's comments by construction.
library;

import 'dart:async';

import 'package:test/test.dart';

import '../../example/agent_tools/readme.dart' as example;

Future<List<String>> _printed(FutureOr<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    () async => body(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.addAll(line.split('\n')),
    ),
  );
  return lines;
}

void main() {
  test('the example declares the tool, answers a read, refuses the vault as '
      'absent, lists one tool over MCP, and audits both calls', () async {
    expect(await _printed(example.main), [
      'read_note',
      '{"text":"Buy milk"}',
      '{"code":"E_NOT_FOUND","message":"No such note."}',
      '1',
      'read_note n1 applied',
      'read_note vault denied',
    ]);
  });
}

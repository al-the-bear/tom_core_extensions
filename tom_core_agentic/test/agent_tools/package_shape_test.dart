/// What `agent_tools.dart` is, read from its source: a library any Dart
/// program can link, with no I/O of its own and nowhere to put content in its
/// audit trail. It shares a package with the Agent SDK transports, which spawn
/// processes, so the claim is about the barrel's import closure, not the
/// package.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Every library `lib/agent_tools.dart` reaches by a relative import, keyed by
/// path, with its source.
Map<String, String> _closure() {
  final sources = <String, String>{};
  final pending = ['lib/agent_tools.dart'];
  while (pending.isNotEmpty) {
    final path = pending.removeLast();
    if (sources.containsKey(path)) continue;
    final source = File(path).readAsStringSync();
    sources[path] = source;
    for (final m in RegExp(
      r"^(?:import|export) '([^']+)'",
      multiLine: true,
    ).allMatches(source)) {
      final uri = m.group(1)!;
      if (uri.contains(':')) continue;
      pending.add(File(path).parent.uri.resolve(uri).toFilePath());
    }
  }
  return {
    for (final e in sources.entries)
      Directory.current.uri
              .resolve(e.key)
              .toFilePath()
              .replaceFirst(Directory.current.uri.toFilePath(), ''):
          e.value,
  };
}

void main() {
  final sources = _closure();

  test('the barrel reaches only lib/src/agent_tools/', () {
    expect(sources.length, greaterThan(5));
    for (final path in sources.keys) {
      expect(
        path == 'lib/agent_tools.dart' ||
            path.startsWith('lib/src/agent_tools/'),
        isTrue,
        reason: path,
      );
    }
  });

  test('the barrel reaches no dart:io, no Flutter and no package but meta and '
      'tom_llm, so a browser build links it', () {
    for (final entry in sources.entries) {
      final imports = RegExp(
        r"^(?:import|export) '([^']+)'",
        multiLine: true,
      ).allMatches(entry.value).map((m) => m.group(1)!);
      for (final uri in imports) {
        expect(
          uri.startsWith('dart:') &&
              !{'dart:async', 'dart:convert', 'dart:math'}.contains(uri),
          isFalse,
          reason: '${entry.key} imports $uri',
        );
        if (uri.startsWith('package:')) {
          expect(
            uri,
            anyOf(startsWith('package:meta/'), startsWith('package:tom_llm/')),
            reason: '${entry.key} imports $uri',
          );
        }
      }
    }
  });

  test('an invocation has no public constructor: consent exists only through '
      'its two factories', () {
    final source = sources.entries
        .firstWhere((e) => e.key == 'lib/src/agent_tools/invocation.dart')
        .value;
    expect(source, contains('const AgentInvocation._({'));
    expect(
      RegExp(
        r'^\s*(?:const\s+)?AgentInvocation\s*\(',
        multiLine: true,
      ).hasMatch(source),
      isFalse,
    );
    final factories = RegExp(
      r'factory\s+AgentInvocation\.(\w+)\s*\(\{([^}]*)\}\)',
    ).allMatches(source).map((m) => (m.group(1)!, m.group(2)!)).toList();
    expect([for (final f in factories) f.$1], ['mint', 'withExecution']);
    for (final (name, params) in factories) {
      expect(
        params,
        isNot(
          contains(
            RegExp(
              r'origin|token|credential|allowExecution',
              caseSensitive: false,
            ),
          ),
        ),
        reason: name,
      );
    }
  });
}

// Pins which parts of the package are reachable from `dart:io`.
//
// The package README makes a checkable claim about which barrel exports a
// `dart:io`-forbidding consumer may use. That claim was previously written
// as prose ("the package's only `dart:io` import"), was true on the day it
// was written, and went stale one commit later when a second importer
// landed -- after which it stayed wrong for months across four documents.
//
// Nothing in the toolchain would have caught that. `dart compile js` does
// not reject `dart:io`: it compiles, stubs the library, and throws
// `UnsupportedError` only when a stubbed member is actually reached at
// runtime. So neither the analyzer nor a web build fails when a module
// silently acquires a `dart:io` dependency. This test is the mechanism
// that does.
//
// Adding a `dart:io` import to a currently-clean module is therefore a
// deliberate act: it fails here, and the fix is to update both this file
// and the README table in the same change.

import 'dart:io';

import 'package:test/test.dart';

/// Files that import `dart:io` directly.
///
/// Four of the five coupled exports below are coupled *by purpose* --
/// `path_scope_io.dart` is the `dart:io` half of `PathScope`, the `agent/`
/// stores are file-backed, and `agent_sdk_session.dart` spawns a
/// subprocess. Only `placeholder_resolver.dart` is incidental.
const expectedDirectImporters = <String>{
  'src/agent/agent_profile_store.dart',
  'src/agent/agent_send.dart',
  'src/agent/agent_settings_store.dart',
  'src/agent/agent_sidecar.dart',
  'src/agent/bridge_connection.dart',
  'src/agent/chat_variable_store.dart',
  'src/agent/prompt_queue_store.dart',
  'src/agent/prompt_template_store.dart',
  'src/agent/prompt_trail_store.dart',
  'src/agent/queue_template_store.dart',
  'src/agent/reminder_template_store.dart',
  'src/agent/timed_request_store.dart',
  'src/llm/agent_sdk_session.dart',
  'src/path_scope_io.dart',
  'src/placeholders/placeholder_resolver.dart',
};

/// Barrel exports that reach `dart:io`, directly or transitively.
///
/// `yaml_config_reader.dart` is here only because it uses
/// `PlaceholderResolver` for `${…}` expansion -- removing that one import
/// would drop two entries from this set, not one.
const expectedCoupledExports = <String>{
  'src/agent/agent.dart',
  'src/llm/llm.dart',
  'src/path_scope_io.dart',
  'src/placeholders/placeholders.dart',
  'src/yaml_config_reader.dart',
};

final _directive = RegExp(r"^\s*(?:import|export|part)\s+'([^']+)'");

/// Resolves a directive target to a path relative to `lib/`, or `null` when
/// it leaves the package (`dart:*`, or another package).
String? _resolve(String from, String target) {
  if (target.startsWith('dart:')) return null;
  if (target.startsWith('package:tom_core_agentic/')) {
    return target.substring('package:tom_core_agentic/'.length);
  }
  if (target.startsWith('package:')) return null;
  final dir = from.contains('/')
      ? from.substring(0, from.lastIndexOf('/'))
      : '';
  final joined = dir.isEmpty ? target : '$dir/$target';
  // Normalise `a/b/../c` -> `a/c`.
  final parts = <String>[];
  for (final segment in joined.split('/')) {
    if (segment == '.' || segment.isEmpty) continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return parts.join('/');
}

/// Whether [rel] (relative to `lib/`) belongs to the main library rather than
/// to `agent_sdk.dart`'s or `agent_tools.dart`'s.
bool _inMainLibrary(String rel) =>
    !rel.startsWith('src/agent_sdk/') &&
    !rel.startsWith('src/agent_tools/') &&
    !rel.startsWith('agent_sdk') &&
    rel != 'agent_tools.dart';

void main() {
  final libDir = Directory('lib');

  // rel-path -> targets it depends on (rel-path), plus the direct set.
  final graph = <String, Set<String>>{};
  final direct = <String>{};

  setUpAll(() {
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.substring('lib/'.length);
      // The Agent SDK and agent-tool libraries have barrels of their own and
      // their own claims: the Agent SDK transports spawn processes by
      // purpose, and agent_tools.dart's web safety is pinned by its own
      // shape test. This test is about the main barrel.
      if (!_inMainLibrary(rel)) continue;
      final edges = <String>{};
      for (final line in entity.readAsLinesSync()) {
        final match = _directive.firstMatch(line);
        if (match == null) continue;
        final target = match.group(1)!;
        if (target == 'dart:io') {
          direct.add(rel);
          continue;
        }
        final resolved = _resolve(rel, target);
        if (resolved != null) edges.add(resolved);
      }
      graph[rel] = edges;
    }
  });

  /// Every direct importer reachable from [start], following the graph.
  Set<String> reachesIo(String start) {
    final seen = <String>{};
    final found = <String>{};
    final stack = <String>[start];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      if (!seen.add(current)) continue;
      if (direct.contains(current)) found.add(current);
      stack.addAll(graph[current] ?? const <String>{});
    }
    return found;
  }

  group('dart:io coupling', () {
    test('the set of direct dart:io importers is the documented one', () {
      expect(
        direct,
        equals(expectedDirectImporters),
        reason:
            'A module gained or lost a `dart:io` import. Update this set and '
            'the `dart:io` coupling table in README.md together.',
      );
    });

    test('exactly the documented barrel exports reach dart:io', () {
      final barrel = File('lib/tom_core_agentic.dart').readAsLinesSync();
      final exports = <String>[];
      for (final line in barrel) {
        final match = RegExp(r"^export '([^']+)';").firstMatch(line);
        if (match != null) exports.add(match.group(1)!);
      }
      expect(exports, isNotEmpty, reason: 'barrel parse failed');

      final coupled = <String>{};
      for (final export in exports) {
        if (reachesIo(export).isNotEmpty) coupled.add(export);
      }

      expect(
        coupled,
        equals(expectedCoupledExports),
        reason:
            'The set of `dart:io`-coupled barrel exports changed. A consumer '
            'that only uses the clean subset relies on this; update README.md.',
      );
      // The README states both halves of the split, so pin both.
      expect(exports.length - coupled.length, equals(29));
    });

    test('the README states the measured figures', () {
      // The prose counts were the half nothing checked, and they went stale
      // exactly the way the sets did not: `expectedDirectImporters` gained
      // an entry when a tenth sidecar store landed, the README went on
      // saying "Fourteen files", and no gate reads a package README's
      // arithmetic. Derived here so the sentence cannot drift from the graph
      // it describes.
      final readme = File('README.md').readAsStringSync();
      final section = RegExp(
        r'## `dart:io` coupling\n(.*?)\n## ',
        dotAll: true,
      ).firstMatch(readme);
      expect(section, isNotNull, reason: 'README has no coupling section');
      final prose = section!.group(1)!;

      final barrel = File('lib/tom_core_agentic.dart').readAsLinesSync();
      final exports = <String>[];
      for (final line in barrel) {
        final match = RegExp(r"^export '([^']+)';").firstMatch(line);
        if (match != null) exports.add(match.group(1)!);
      }
      final coupled = exports.where((e) => reachesIo(e).isNotEmpty).toList();

      expect(
        prose,
        contains('${direct.length} files of the main library import `dart:io`'),
        reason:
            'the direct-importer count in README.md is not ${direct.length}',
      );
      expect(
        prose,
        contains('${coupled.length} of the ${exports.length} barrel'),
        reason:
            'the coupled/total export counts in README.md are not '
            '${coupled.length} of ${exports.length}',
      );
      expect(
        prose,
        contains(
          '**${exports.length - coupled.length} exports are '
          '`dart:io`-free**',
        ),
        reason:
            'the clean-export count in README.md is not '
            '${exports.length - coupled.length}',
      );

      // Each table row states how many importers that export reaches. A row
      // naming the wrong number sends a reader auditing the wrong subtree.
      for (final export in coupled) {
        final row = RegExp(
          '^\\| `${RegExp.escape(export)}` \\| (\\d+) \\|',
          multiLine: true,
        ).firstMatch(prose);
        expect(row, isNotNull, reason: 'README has no row for $export');
        expect(
          int.parse(row!.group(1)!),
          equals(reachesIo(export).length),
          reason:
              '$export reaches ${reachesIo(export).length} importers; '
              'the README row says ${row.group(1)}',
        );
      }
    });

    test('yaml_config_reader is coupled only through placeholders', () {
      // The README and the deferred note both claim that removing the one
      // incidental import buys back two exports. That is only true while
      // this is the sole path, so the claim is checked rather than trusted.
      expect(
        reachesIo('src/yaml_config_reader.dart'),
        equals({'src/placeholders/placeholder_resolver.dart'}),
      );
    });
  });
}

/// Holds every `doc/api/api_summary_<unit>.md` to the surface its unit exports.
///
/// An API summary is worth reading only while it is complete. An incomplete one
/// is worse than none, because a reader takes a symbol's absence for the symbol
/// not existing — and that costs most in the units big enough to need a mirror,
/// where the alternative is reading every file.
///
/// Everything below is **derived**: the set of summaries from `doc/api/`, and
/// each one's required symbols from `lib/src/<unit>/<unit>.dart`. No unit name
/// and no symbol name is written out here, so a summary added tomorrow is
/// covered tomorrow, and the test cannot go stale in the same direction as the
/// documents it guards.
///
/// A prose page under `doc/` is covered only where it *is* the mirror — the
/// `## Overview` table of a unit too small to earn a summary. The rest of the
/// page explains behaviour and is free to omit a symbol.
library;

import 'dart:io';
import 'package:test/test.dart';

/// A public top-level declaration.
final _declaration = RegExp(
  r'^(?:abstract\s+|base\s+|final\s+|sealed\s+|interface\s+|mixin\s+)*'
  r'(?:class|mixin|enum|extension|typedef)\s+(\w+)',
  multiLine: true,
);

/// A top-level function: a return type and a name at column 0, where the line
/// does not open a declaration of some other kind.
///
/// Anchoring at column 0 is what separates these from members — every class
/// body in this unit is indented — and the negative lookahead is what keeps
/// `class Foo {` from reading as a function returning `class`.
final _topLevelFunction = RegExp(
  r'^(?!(?:abstract|base|final|sealed|interface|mixin|class|enum|typedef'
  r'|extension|import|export|library|part|const|@)\b)'
  r'[A-Za-z][A-Za-z0-9_<>,? ]*\s+([a-z]\w*)\s*(?:<[^>()]*>)?\(',
  multiLine: true,
);

/// A public top-level constant.
final _topLevelConst = RegExp(
  r'^const\s+(?:[\w<>,\s?]+\s+)?(\w+)\s*=',
  multiLine: true,
);

/// A `static` member, including `static get` / `static const`.
final _staticMember = RegExp(
  r'^\s*static\s+(?:[\w<>,\s?]+\s+)?(?:get\s+|set\s+)?(\w+)\s*'
  r'(?:<[\w<>,\s?]*>\s*)?[({=;]',
  multiLine: true,
);

final _export = RegExp(r"^export\s+'([^']+)'", multiLine: true);

/// A `### Name` heading in the summary.
final _heading = RegExp(r'^###\s+(\w+)', multiLine: true);

/// An inline code span.
final _inlineCode = RegExp(r'`([^`\n]+)`');

/// The summaries under `doc/api/`, mapped from the unit each one names.
///
/// Discovered from the directory rather than listed, for the reason everything
/// else here is derived: a list is silent about the file nobody added to it.
Map<String, File> _summaries() {
  final dir = Directory('doc/api');
  if (!dir.existsSync()) return const {};
  final pattern = RegExp(r'^api_summary_(\w+)\.md$');
  final out = <String, File>{};
  for (final file in dir.listSync().whereType<File>()) {
    final match = pattern.firstMatch(file.uri.pathSegments.last);
    // `api_summary_index.md` matches the shape and names no unit — it is the
    // document *about* the set. Named rather than filtered by "has no barrel",
    // which would also swallow a summary whose unit was renamed.
    if (match != null && match.group(1) != 'index') out[match.group(1)!] = file;
  }
  return out;
}

/// The barrel's own source plus every library it re-exports.
///
/// The barrel is included because a unit may declare a symbol in it rather
/// than beneath it; omitting it would make the barrel a blind spot.
List<String> _exportedSources(String unit) {
  final dir = 'lib/src/$unit';
  final barrel = File('$dir/$unit.dart').readAsStringSync();
  final sources = <String>[barrel];
  for (final match in _export.allMatches(barrel)) {
    final library = File('$dir/${match.group(1)}');
    if (library.existsSync()) sources.add(library.readAsStringSync());
  }
  return sources;
}

Set<String> _publicNames(List<String> sources, RegExp pattern) => sources
    .expand(pattern.allMatches)
    .map((m) => m.group(1)!)
    .where((n) => !n.startsWith('_'))
    .toSet();

/// Whether [summary] names [symbol] as API, rather than merely containing the
/// letters somewhere.
///
/// A plain `contains` passes vacuously for every short name, and this unit has
/// several — `load`, `save`, `clear`, `scan`, `matches`. So a symbol counts
/// only inside an inline code span, as a whole word, which is how the document
/// writes every API name.
bool _names(String summary, String symbol) {
  final code = _inlineCode
      .allMatches(summary)
      .map((m) => m.group(1)!)
      .join(' ');
  return RegExp('(?<!\\w)${RegExp.escape(symbol)}(?!\\w)').hasMatch(code);
}

void main() {
  final summaries = _summaries();

  test('the walk of doc/api/ found the summaries it claims to check', () {
    // One assertion over a directory walk checks nothing when the walk finds
    // nothing, and reports a clean package it never opened. A floor rather
    // than an exact count, because the count is supposed to grow.
    expect(
      summaries.length,
      greaterThanOrEqualTo(1),
      reason: 'found ${summaries.length} summaries under doc/api/',
    );
  });

  for (final entry in summaries.entries) {
    final unit = entry.key;
    final summaryFile = entry.value;

    group('the $unit API summary mirrors what its barrel exports', () {
      final barrel = File('lib/src/$unit/$unit.dart');

      test('the unit exists and its barrel does', () {
        expect(
          barrel.existsSync(),
          isTrue,
          reason:
              '${summaryFile.path} claims to summarise lib/src/$unit/, whose '
              'barrel is not there',
        );
      });

      if (!barrel.existsSync()) return;

      final sources = _exportedSources(unit);
      final types = _publicNames(sources, _declaration);
      final functions = _publicNames(sources, _topLevelFunction);
      final constants = _publicNames(sources, _topLevelConst);
      final statics = _publicNames(sources, _staticMember);

      test('the scan finds a surface to compare against', () {
        // Without this, a barrel that stopped resolving — a renamed file, a
        // changed directory — would make every case below pass by having
        // nothing to disagree with. That is the failure mode that makes a
        // derived test worthless exactly when it is needed.
        // The surface, not the types: a unit may export constants alone, as
        // `mcp_auth` does, and is then no less a unit with something to mirror.
        expect(sources.length, greaterThan(1), reason: 'barrel parse broke');
        expect(
          {...types, ...functions, ...constants},
          isNotEmpty,
          reason: 'declaration scan broke',
        );
      });

      test('every exported type, function and constant has a section', () {
        final headed = _heading
            .allMatches(summaryFile.readAsStringSync())
            .map((m) => m.group(1)!)
            .toSet();
        final missing = {
          ...types,
          ...functions,
          ...constants,
        }.difference(headed).toList()..sort();
        expect(
          missing,
          isEmpty,
          reason:
              'lib/src/$unit exports these and the summary gives them no '
              '`### ` section: $missing',
        );
      });

      test('every public static is named', () {
        final summary = summaryFile.readAsStringSync();
        final missing = statics.where((s) => !_names(summary, s)).toList()
          ..sort();
        expect(
          missing,
          isEmpty,
          reason:
              'lib/src/$unit declares these public statics and the summary '
              'never names them: $missing',
        );
      });

      test('no section names a symbol the unit does not export', () {
        // The opposite question, and the one that misleads rather than merely
        // omits: a reader sent looking for a symbol that was renamed or
        // removed cannot tell that from a typo.
        final headed = _heading
            .allMatches(summaryFile.readAsStringSync())
            .map((m) => m.group(1)!)
            .toSet();
        final phantom = headed.difference({
          ...types,
          ...functions,
          ...constants,
        }).toList()..sort();
        expect(
          phantom,
          isEmpty,
          reason:
              'the summary sections these, which the barrel does not '
              'export: $phantom',
        );
      });
    });
  }

  _unitRules();
}

/// The `## Overview` section of a prose page, up to the next `## `.
final _overview = RegExp(r'\n## Overview\n(.*?)(?=\n## )', dotAll: true);

/// A link target in the index.
final _link = RegExp(r'\]\(([^)]+)\)');

/// Exported public members at or above which a unit earns its own summary.
///
/// Members, not types and not lines: what a reader has to hold in their head is
/// the set of things they can call, and a type with nine methods costs more
/// than three types with one each. Counting types put `placeholders` (6 types,
/// 35 members) beside `bearer_auth` (3 and 5) when it belongs beside
/// `isolate_streaming` (12 and 47). `doc/api/api_summary_index.md` states the
/// rule and tabulates the six units against it, and says that `tom_flutter_ui`
/// applies the same ten to exported types.
const _summaryThreshold = 10;

/// Comments and string literals, removed before any structural scan.
///
/// A brace inside a string or a comment would move the depth counter and put
/// every member after it at the wrong level, which is the one way a
/// brace-counting scan goes quietly wrong rather than loudly.
String _withoutCommentsAndStrings(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'^\s*///?.*$', multiLine: true), '')
    .replaceAll(RegExp(r"'(?:\\.|[^'\\\n])*'", multiLine: true), "''")
    .replaceAll(RegExp(r'"(?:\\.|[^"\\\n])*"', multiLine: true), "''");

/// A type declaration at column 0.
final _typeDeclaration = RegExp(
  r'^(?:(?:abstract|final|sealed|base|interface|mixin)\s+)*'
  r'(?:class|mixin|enum|extension)\s+(\w+)',
);

/// A member declaration, matched only at brace depth 1 inside a type body.
///
/// Depth is what separates a member from a local: a member sits at depth 1 and
/// everything inside a method body is deeper. A regex alone cannot tell them
/// apart — a first attempt at this counted `i`, `out`, `merged` and `residue`
/// as public API.
final _memberDeclaration = RegExp(
  r'^(?:@\w+\s+)*(?:external\s+|static\s+|covariant\s+|abstract\s+)*'
  r'(?:final\s+|const\s+|late\s+)*'
  r'(?:[\w<>,\?\s\.\[\]]+?\s+)??'
  r'(?:get\s+|set\s+|operator\s+)?'
  r'([a-zA-Z]\w*)\s*(?:<[^>()]*>\s*)?[(=;{]',
);

/// Reserved words a statement can open with, refused so that a slip in the
/// depth tracking cannot quietly turn a `return x;` into a member.
const _statementKeywords = {
  'return',
  'if',
  'for',
  'while',
  'switch',
  'throw',
  'assert',
  'yield',
  'await',
  'else',
  'case',
  'default',
  'try',
  'catch',
  'finally',
  'super',
  'this',
  'new',
  'const',
  'final',
  'var',
  'late',
  'static',
  'void',
  'break',
  'continue',
  'rethrow',
  'in',
  'is',
  'as',
};

/// Every public `Type.member` the unit's exported sources declare.
Set<String> _publicMembers(List<String> sources) {
  final found = <String>{};
  for (final source in sources) {
    var depth = 0;
    String? type;
    for (final raw in _withoutCommentsAndStrings(source).split('\n')) {
      final line = raw.trim();
      if (depth == 0) {
        final match = _typeDeclaration.firstMatch(line);
        if (match != null) type = match.group(1);
      }
      if (depth == 1 && type != null && !type.startsWith('_')) {
        final match = _memberDeclaration.firstMatch(line);
        final name = match?.group(1);
        if (name != null &&
            !name.startsWith('_') &&
            !_statementKeywords.contains(name)) {
          found.add('$type.$name');
        }
      }
      depth += '{'.allMatches(raw).length - '}'.allMatches(raw).length;
      if (depth <= 0) {
        depth = 0;
        type = null;
      }
    }
  }
  return found;
}

/// Every directory under `lib/src/` that has a barrel named after itself.
List<String> _units() {
  final dir = Directory('lib/src');
  final out = <String>[];
  for (final entry in dir.listSync().whereType<Directory>()) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (File('lib/src/$name/$name.dart').existsSync()) out.add(name);
  }
  out.sort();
  return out;
}

void _unitRules() {
  final units = _units();
  final summaries = _summaries();
  final index = File('doc/api/api_summary_index.md');

  test('the walk of lib/src found the units it claims to check', () {
    // The same anti-vacuity guard the summary walk carries, for the same
    // reason: a walk that finds nothing reports a clean package it never
    // opened. A floor, because the count is supposed to grow.
    expect(units.length, greaterThanOrEqualTo(4), reason: 'found $units');
  });

  for (final unit in units) {
    final unitSources = _exportedSources(unit);
    final types = _publicNames(unitSources, _declaration);
    final members = _publicMembers(unitSources);
    final hasSummary = summaries.containsKey(unit);
    final page = File('doc/$unit.md');

    group('the $unit unit is mirrored somewhere', () {
      test('it has a summary or a prose page', () {
        expect(
          hasSummary || page.existsSync(),
          isTrue,
          reason:
              'lib/src/$unit has neither doc/api/api_summary_$unit.md nor '
              'doc/$unit.md, so nothing mirrors its surface',
        );
      });

      test('the threshold decides which, and it is obeyed', () {
        // The half the summary walk cannot ask. It checks the summaries that
        // exist and is silent about the one nobody wrote — which is the
        // failure a unit drifts into by growing, not by being neglected.
        if (members.length >= _summaryThreshold) {
          expect(
            hasSummary,
            isTrue,
            reason:
                'lib/src/$unit exports ${members.length} public members, at '
                'or over the threshold of $_summaryThreshold, and has no '
                'doc/api/api_summary_$unit.md',
          );
        }
      });

      // A sub-threshold unit's page is held even when it has a summary too:
      // the summary is the repository gate's demand, the page is the one a
      // reader of a small unit is sent to.
      if (members.length >= _summaryThreshold || !page.existsSync()) return;

      test('its Overview table names every exported name', () {
        // Below the threshold the prose page's Overview IS the mirror, so it
        // is held to the whole surface — types, top-level functions and
        // constants alike. tool/check_doc_overview_types.py compares types
        // only and skips a unit that exports none, which is exactly `mcp_auth`
        // and exactly the surface most easily got wrong.
        final sources = _exportedSources(unit);
        final required = <String>{
          ...types,
          ..._publicNames(sources, _topLevelFunction),
          ..._publicNames(sources, _topLevelConst),
        };
        final section = _overview.firstMatch(page.readAsStringSync());
        expect(
          section,
          isNotNull,
          reason: 'doc/$unit.md has no `## Overview` section to mirror with',
        );
        final missing =
            required.where((s) => !_names(section!.group(1)!, s)).toList()
              ..sort();
        expect(
          missing,
          isEmpty,
          reason:
              'lib/src/$unit exports these and doc/$unit.md\'s Overview never '
              'names them: $missing',
        );
      });
    });
  }

  group('the index accounts for every unit', () {
    test('it exists', () {
      expect(index.existsSync(), isTrue, reason: '${index.path} is missing');
    });

    if (!index.existsSync()) return;
    final text = index.readAsStringSync();

    test('it says that tom_flutter_ui counts types for the same ten', () {
      // Both packages state "a summary at ten", and each counts a different
      // thing. A reader who has met one index reads the other's number as the
      // same number unless the index says otherwise, and so does a third
      // package adopting "the rule". tom_flutter_ui's suite holds the mirror
      // sentence in its own index.
      expect(
        text,
        contains('**`tom_flutter_ui` states the same threshold over types**'),
        reason:
            'the index must say that tom_flutter_ui applies ten to exported '
            'types, so the two numbers are never read as one',
      );
    });

    test('it links every summary under doc/api/', () {
      final linked = _link.allMatches(text).map((m) => m.group(1)!).toSet();
      final missing =
          summaries.keys
              .where((u) => !linked.contains('api_summary_$u.md'))
              .toList()
            ..sort();
      expect(
        missing,
        isEmpty,
        reason: 'doc/api/ holds summaries the index does not link: $missing',
      );
    });

    test('it names every unit, summarised or not', () {
      // The point of the index is the units it says nothing about, so the
      // sub-threshold ones are what it most has to name.
      final missing = units.where((u) => !_names(text, u)).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: 'lib/src holds units the index never names: $missing',
      );
    });

    test('its member and type counts are the measured ones', () {
      // The table argues from those numbers — that `placeholders` sits with
      // `isolate_streaming` on members and with `bearer_auth` on types — so a
      // figure nobody maintains would leave the rule resting on a stale
      // measurement. Both columns are derived here rather than trusted. A
      // source-line column stood beside them and was removed instead of
      // pinned: the argument does not rest on it, and a length nobody
      // maintains is worse than no length.
      final wrong = <String>[];
      for (final unit in units) {
        final sources = _exportedSources(unit);
        final members = _publicMembers(sources).length;
        final types = _publicNames(sources, _declaration).length;
        final row = RegExp(
          '^\\|\\s*`' +
              RegExp.escape(unit) +
              '`\\s*\\|\\s*(\\d+)\\s*\\|\\s*(\\d+)\\s*\\|',
          multiLine: true,
        ).firstMatch(text);
        if (row == null) {
          wrong.add('$unit: no row stating a member and a type count');
          continue;
        }
        if (int.parse(row.group(1)!) != members) {
          wrong.add('$unit: members ${row.group(1)}, measured $members');
        }
        if (int.parse(row.group(2)!) != types) {
          wrong.add('$unit: types ${row.group(2)}, measured $types');
        }
      }
      expect(wrong, isEmpty, reason: wrong.join('; '));
    });

    test('it links no summary that is not there', () {
      final dangling =
          _link
              .allMatches(text)
              .map((m) => m.group(1)!)
              .where((target) => target.startsWith('api_summary_'))
              .where((target) => !File('doc/api/$target').existsSync())
              .toList()
            ..sort();
      expect(dangling, isEmpty, reason: 'the index links: $dangling');
    });
  });
}

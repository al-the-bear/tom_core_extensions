/// Holds every `doc/api/api_summary_<name>.md` to the surface it mirrors, and
/// asks that every part of the package's public API has one.
///
/// An API summary is worth reading only while it is complete. An incomplete one
/// is worse than none, because a reader takes a symbol's absence for the symbol
/// not existing.
///
/// Everything below is **derived**: the set of summaries from `doc/api/`, and
/// each one's required symbols from what it mirrors — a unit's barrel
/// `lib/src/<unit>/<unit>.dart`, a public library `lib/<name>.dart` with its
/// `lib/<name>_*.dart` siblings, or the files the main barrel exports straight
/// from `lib/src/` (the `utilities` summary). No unit name and no symbol name
/// is written out here, so a summary added tomorrow is covered tomorrow, and
/// the test cannot go stale in the same direction as the documents it guards.
///
/// A prose page under `doc/` is covered only where it is a mirror too — the
/// `## Overview` table of a small unit. The rest of the page explains
/// behaviour and is free to omit a symbol.
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
  r'^const\s+(?:[\w<>,\s?()]+\s+)?(\w+)\s*=',
  multiLine: true,
);

/// A `static` member, including `static get` / `static const`.
final _staticMember = RegExp(
  r'^\s*static\s+(?:[\w<>,\s?]+\s+)?(?:get\s+|set\s+)?(\w+)\s*'
  r'(?:<[\w<>,\s?]*>\s*)?[({=;]',
  multiLine: true,
);

final _export = RegExp(r"^export\s+'([^']+)'", multiLine: true);

/// An export that hides names: `export 'x.dart' hide main, other;`.
final _exportHide = RegExp(
  r"^export\s+'[^']+'\s+hide\s+([\w\s,]+);",
  multiLine: true,
);

/// The names [sources] hide on their exports: declared in an exported file,
/// and still not part of the library's API (a script's `main`).
Set<String> _hidden(List<String> sources) => {
  for (final source in sources)
    for (final m in _exportHide.allMatches(source))
      ...m.group(1)!.split(',').map((n) => n.trim()).where((n) => n.isNotEmpty),
};

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
List<String> _exportedSources(String unit) =>
    _barrelSources(File('lib/src/$unit/$unit.dart'));

/// [barrel]'s source plus every library it re-exports by a relative path.
List<String> _barrelSources(File barrel, {bool Function(String)? where}) {
  final text = barrel.readAsStringSync();
  final sources = <String>[text];
  for (final match in _export.allMatches(text)) {
    final target = match.group(1)!;
    if (where != null && !where(target)) continue;
    final library = File('${barrel.parent.path}/$target');
    if (library.existsSync()) sources.add(library.readAsStringSync());
  }
  return sources;
}

/// The public libraries under `lib/` other than the package's main barrel,
/// grouped by the summary that mirrors them: `lib/<name>.dart` and its
/// `lib/<name>_*.dart` siblings (`agent_sdk`, `agent_sdk_testing`,
/// `agent_sdk_live_probe` are one summary).
Map<String, List<File>> _libraries() {
  final files = Directory('lib').listSync().whereType<File>().where(
    (f) => f.path.endsWith('.dart') && !f.path.endsWith('/$_mainBarrel.dart'),
  );
  final names = [
    for (final f in files) f.uri.pathSegments.last.replaceAll('.dart', ''),
  ]..sort();
  final out = <String, List<File>>{};
  for (final name in names) {
    final owner = names.firstWhere(
      (n) => name == n || name.startsWith('${n}_'),
    );
    out.putIfAbsent(owner, () => []).add(File('lib/$name.dart'));
  }
  return out;
}

/// The package's main barrel, `lib/tom_core_agentic.dart`.
const _mainBarrel = 'tom_core_agentic';

/// The summary of the files the main barrel exports straight from `lib/src/`,
/// outside any unit: the small helpers.
const _utilities = 'utilities';

/// The sources the summary named [name] mirrors: a unit's barrel, a public
/// library (with its siblings), or the main barrel's own `lib/src/` files.
/// Null when [name] is none of them.
List<String>? _summarySources(String name) {
  if (File('lib/src/$name/$name.dart').existsSync()) {
    return _exportedSources(name);
  }
  final library = _libraries()[name];
  if (library != null) return [for (final f in library) ..._barrelSources(f)];
  if (name == _utilities) {
    return _barrelSources(
      File('lib/$_mainBarrel.dart'),
      where: (target) => RegExp(r'^src/[^/]+\.dart$').hasMatch(target),
    );
  }
  return null;
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
      final found = _summarySources(unit);

      test('it summarises a unit, a public library or the utilities', () {
        expect(
          found,
          isNotNull,
          reason:
              '${summaryFile.path} names no unit (lib/src/$unit/$unit.dart), '
              'no public library (lib/$unit.dart) and is not the '
              '$_utilities summary',
        );
      });

      if (found == null) return;

      final sources = found;
      final hidden = _hidden(sources);
      final types = _publicNames(sources, _declaration).difference(hidden);
      final functions = _publicNames(
        sources,
        _topLevelFunction,
      ).difference(hidden);
      final constants = _publicNames(
        sources,
        _topLevelConst,
      ).difference(hidden);
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
              '$unit exports these and the summary gives them no '
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
              '$unit declares these public statics and the summary '
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

/// Exported public members below which a unit is small: its prose page's
/// `## Overview` table is held to its whole surface, beside its summary
/// (`bearer_auth`, `mcp_auth`).
const _smallUnit = 10;

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

      test('it has an API summary', () {
        // The half the summary walk cannot ask. It checks the summaries that
        // exist and is silent about the one nobody wrote — which is the
        // failure a new unit arrives with.
        expect(
          hasSummary,
          isTrue,
          reason: 'lib/src/$unit has no doc/api/api_summary_$unit.md',
        );
      });

      // A small unit's page is held too: the summary is the repository
      // gate's demand, the page is the one a reader of a small unit is sent
      // to, and its Overview table names the whole surface.
      if (members.length >= _smallUnit || !page.existsSync()) return;

      test('its Overview table names every exported name', () {
        // A small unit's prose page Overview mirrors its surface as well, so
        // it is held to all of it — types, top-level functions and
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

  group('every public library has an API summary', () {
    final libraries = _libraries();

    test('the walk of lib/ found the libraries it claims to check', () {
      expect(libraries, isNotEmpty, reason: 'found $libraries');
    });

    for (final name in [...libraries.keys, _utilities]) {
      test('$name has doc/api/api_summary_$name.md', () {
        expect(
          summaries.containsKey(name),
          isTrue,
          reason: name == _utilities
              ? 'the files lib/$_mainBarrel.dart exports straight from '
                    'lib/src/ have no doc/api/api_summary_$name.md'
              : '${libraries[name]!.map((f) => f.path).join(', ')} has no '
                    'doc/api/api_summary_$name.md',
        );
      });
    }
  });

  group('the index accounts for every unit', () {
    test('it exists', () {
      expect(index.existsSync(), isTrue, reason: '${index.path} is missing');
    });

    if (!index.existsSync()) return;
    final text = index.readAsStringSync();

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
      // A reader looks a unit up in the index; one it does not name reads as
      // one that does not exist.
      final missing = units.where((u) => !_names(text, u)).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: 'lib/src holds units the index never names: $missing',
      );
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

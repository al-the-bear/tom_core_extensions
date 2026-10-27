// Every public class in `lib/` says whether a consumer may extend it.
//
// A class with no modifier can be extended, implemented and mixed into from
// any library, and nothing in its declaration says whether that was meant or
// is just the modifier the file happened to be written with. So a public class
// either carries a modifier, or its dartdoc says in so many words that it is
// deliberately open — and why, so the reason can be checked.
//
// The second rule is the narrower one: a leaf of a `sealed` class is `final`.
// The sealed base already decides who may join the union, and an open leaf
// reopens it by the back door — a consumer extending a leaf adds a case every
// exhaustive `switch` over the base silently accepts as the leaf.

import 'dart:io';

import 'package:test/test.dart';

/// A top-level public class declaration and the dartdoc directly above it.
typedef _Declaration = ({String file, int line, String header, String dartdoc});

final _classHeader = RegExp(
  r'^((?:abstract |base |final |interface |sealed |mixin )*)class ([A-Z]\w*)'
  r'(?:<[^{]*?>)?(?: extends (\w+))?',
);

List<_Declaration> _declarations() {
  final found = <_Declaration>[];
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.endsWith('.versioner.dart'));
  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (!_classHeader.hasMatch(lines[i])) continue;
      final doc = <String>[];
      for (var j = i - 1; j >= 0; j--) {
        final line = lines[j].trim();
        if (line.startsWith('///')) {
          doc.insert(0, line);
        } else if (line.startsWith('//') || line.startsWith('@')) {
          continue;
        } else {
          break;
        }
      }
      found.add((
        file: file.path,
        line: i + 1,
        header: lines[i],
        dartdoc: doc.join(' '),
      ));
    }
  }
  return found;
}

void main() {
  final declarations = _declarations();

  test('CM-1: every public class carries a modifier or says it is open', () {
    // Anti-vacuity: the package has well over fifty public classes, so a scan
    // that finds a handful has stopped reading rather than found them clean.
    expect(declarations.length, greaterThan(50));

    final unexplained = [
      for (final d in declarations)
        if (_classHeader.firstMatch(d.header)!.group(1)!.isEmpty &&
            !d.dartdoc.contains('deliberately open'))
          '${d.file}:${d.line}  ${d.header.trim()}',
    ];
    expect(
      unexplained,
      isEmpty,
      reason:
          'a public class with no modifier must say in its dartdoc that it is '
          'deliberately open, and why; otherwise give it the modifier that '
          'states its restriction (usually `final`)',
    );
  });

  test('CM-2: every leaf of a sealed class in the package is final', () {
    final sealed = {
      for (final d in declarations)
        if (_classHeader.firstMatch(d.header)!.group(1)!.contains('sealed'))
          _classHeader.firstMatch(d.header)!.group(2)!,
    };
    // The package has one sealed event hierarchy (AgentSendEvent); losing
    // sight of it would empty this test.
    expect(sealed, contains('AgentSendEvent'));

    final leaves = [
      for (final d in declarations)
        if (sealed.contains(_classHeader.firstMatch(d.header)!.group(3))) d,
    ];
    expect(leaves, isNotEmpty);
    final open = [
      for (final d in leaves)
        if (!_classHeader.firstMatch(d.header)!.group(1)!.contains('final') &&
            !_classHeader.firstMatch(d.header)!.group(1)!.contains('sealed'))
          '${d.file}:${d.line}  ${d.header.trim()}',
    ];
    expect(open, isEmpty, reason: 'a sealed base needs final leaves');
  });
}

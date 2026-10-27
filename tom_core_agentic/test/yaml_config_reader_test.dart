import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Domain exception stand-in: proves the [YamlConfigReader.errorFactory]
/// seam keeps the thrown type loader-specific.
class _CfgException implements Exception {
  final String message;
  const _CfgException(this.message);
  @override
  String toString() => 'CfgException: $message';
}

YamlConfigReader _reader({Map<String, String> env = const {}}) =>
    YamlConfigReader(env: env, errorFactory: _CfgException.new);

/// The reader now operates on the **plain** map [loadYamlAsMap] produces at
/// the parse boundary — never a `package:yaml` `YamlMap`. Every test builds
/// its node through this helper.
Map<Object?, Object?> _map(String yaml) => loadYamlAsMap(yaml);

void main() {
  group('YamlConfigReader typed accessors', () {
    test('requireString returns the value', () {
      final r = _reader();
      expect(r.requireString(_map('a: hello'), 'a', 'root.a'), 'hello');
    });

    test('requireString throws domain exception when missing', () {
      final r = _reader();
      expect(
        () => r.requireString(_map('b: x'), 'a', 'root.a'),
        throwsA(
          isA<_CfgException>().having(
            (e) => e.message,
            'message',
            'Missing required field: root.a',
          ),
        ),
      );
    });

    test('requireString throws on type mismatch with path + runtimeType', () {
      final r = _reader();
      expect(
        () => r.requireString(_map('a: 7'), 'a', 'root.a'),
        throwsA(
          isA<_CfgException>().having(
            (e) => e.message,
            'message',
            contains('root.a must be a string (got'),
          ),
        ),
      );
    });

    test('optionalString returns null when absent', () {
      expect(_reader().optionalString(_map('b: x'), 'a', 'root.a'), isNull);
    });

    test('requireInt / optionalInt', () {
      final r = _reader();
      expect(r.requireInt(_map('a: 42'), 'a', 'root.a'), 42);
      expect(r.optionalInt(_map('b: x'), 'a', 'root.a'), isNull);
      expect(
        () => r.requireInt(_map('a: nope'), 'a', 'root.a'),
        throwsA(isA<_CfgException>()),
      );
    });

    test('requireDouble accepts int and double', () {
      final r = _reader();
      expect(r.requireDouble(_map('a: 3'), 'a', 'root.a'), 3.0);
      expect(r.requireDouble(_map('a: 2.5'), 'a', 'root.a'), 2.5);
    });

    test('optionalDouble returns null when absent, throws on non-number', () {
      final r = _reader();
      expect(r.optionalDouble(_map('b: x'), 'a', 'root.a'), isNull);
      expect(
        () => r.optionalDouble(_map('a: text'), 'a', 'root.a'),
        throwsA(isA<_CfgException>()),
      );
    });

    test('optionalBool', () {
      final r = _reader();
      expect(r.optionalBool(_map('a: true'), 'a', 'root.a'), isTrue);
      expect(r.optionalBool(_map('b: x'), 'a', 'root.a'), isNull);
      expect(
        () => r.optionalBool(_map('a: 1'), 'a', 'root.a'),
        throwsA(isA<_CfgException>()),
      );
    });

    test('requireMap / optionalMap return plain maps (not YamlMap)', () {
      final r = _reader();
      final m = r.requireMap(_map('a: {x: 1}'), 'a', 'root.a');
      expect(m, isA<Map<Object?, Object?>>());
      expect(m, isNot(isA<YamlMap>()));
      expect(m['x'], 1);
      expect(r.optionalMap(_map('b: 1'), 'a'), isNull);
      expect(
        () => r.optionalMap(_map('a: 1'), 'a'),
        throwsA(
          isA<_CfgException>().having(
            (e) => e.message,
            'message',
            contains('Field `a` must be a map'),
          ),
        ),
      );
    });

    test('requireList / optionalList return plain lists (not YamlList)', () {
      final r = _reader();
      final l = r.requireList(_map('a: [1, 2]'), 'a', 'root.a');
      expect(l, isA<List<Object?>>());
      expect(l, isNot(isA<YamlList>()));
      expect(l, <Object?>[1, 2]);
      expect(r.optionalList(_map('b: 1'), 'a', 'root.a'), isNull);
      expect(
        () => r.requireList(_map('a: 1'), 'a', 'root.a'),
        throwsA(isA<_CfgException>()),
      );
    });

    test('no YamlMap or YamlList is accepted or produced by the read path', () {
      final r = _reader();
      // The boundary loader yields a plain map: feeding the reader a YamlMap
      // is impossible through the sanctioned path, and every nested node it
      // returns is plain too.
      final doc = _map('outer:\n  inner:\n    leaf: [1, 2, {k: v}]');
      expect(doc, isNot(isA<YamlMap>()));
      final outer = r.requireMap(doc, 'outer', 'root.outer');
      expect(outer, isNot(isA<YamlMap>()));
      final inner = r.requireMap(outer, 'inner', 'root.outer.inner');
      expect(inner, isNot(isA<YamlMap>()));
      final leaf = r.requireList(inner, 'leaf', 'root.outer.inner.leaf');
      expect(leaf, isNot(isA<YamlList>()));
      // The map element inside the list is plain as well.
      expect(leaf[2], isA<Map<Object?, Object?>>());
      expect(leaf[2], isNot(isA<YamlMap>()));
    });

    test('parseUri', () {
      final r = _reader();
      expect(r.parseUri('https://x/y', 'root.url'), Uri.parse('https://x/y'));
      expect(
        () => r.parseUri('::::', 'root.url'),
        throwsA(isA<_CfgException>()),
      );
    });
  });

  group('YamlConfigReader.expandEnv', () {
    test('returns input unchanged when no token', () {
      expect(_reader().expandEnv('plain', 'root.x'), 'plain');
    });

    test('substitutes a defined env var via the env: prefix', () {
      final r = _reader(env: {'TOKEN': 'secret'});
      expect(r.expandEnv(r'Bearer ${env:TOKEN}', 'root.x'), 'Bearer secret');
    });

    test('substitutes multiple env vars', () {
      final r = _reader(env: {'A': '1', 'B': '2'});
      expect(r.expandEnv(r'${env:A}-${env:B}', 'root.x'), '1-2');
    });

    test('throws on undefined env var with path', () {
      expect(
        () => _reader().expandEnv(r'${env:MISSING}', 'root.x'),
        throwsA(
          isA<_CfgException>().having(
            (e) => e.message,
            'message',
            contains(r'root.x references undefined env var `${env:MISSING}`'),
          ),
        ),
      );
    });

    test('a bare \${name} (no env: prefix) is an unbound-placeholder error '
        'that points at the env: form', () {
      expect(
        () =>
            _reader(env: {'TOKEN': 'secret'}).expandEnv(r'${TOKEN}', 'root.x'),
        throwsA(
          isA<_CfgException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(r'root.x references unbound placeholder `${TOKEN}`'),
              contains(r'${env:TOKEN}'),
            ),
          ),
        ),
      );
    });

    test(
      'an unterminated \${ (no closing brace) is passed through verbatim',
      () {
        expect(_reader().expandEnv(r'${UNCLOSED', 'root.x'), r'${UNCLOSED');
      },
    );

    test('empty \${} is an unbound-placeholder error', () {
      expect(
        () => _reader().expandEnv(r'${}', 'root.x'),
        throwsA(
          isA<_CfgException>().having(
            (e) => e.message,
            'message',
            contains('unbound placeholder'),
          ),
        ),
      );
    });

    test('a bare \$ without brace is passed through verbatim', () {
      expect(_reader().expandEnv(r'cost $5', 'root.x'), r'cost $5');
    });
  });
}

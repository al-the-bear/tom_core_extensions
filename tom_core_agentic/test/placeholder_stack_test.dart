// Tests for `PlaceholderStack` — the scope-frame namespace the resolver's
// `${name}` / `${{ … }}` forms read. It sits in `tom_core_agentic` beside the
// resolver, because both spellings must read one set of bindings.
//
// The stack models nested call frames: a root frame, `push` to enter a
// child, `bind` to add/shadow a name, `pop` to leave. `flatten` collapses
// root→top into the single map the expression backing reads, with the
// innermost frame winning on a name collision.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('PlaceholderStack', () {
    test('binds, looks up, and reports depth from a single root frame', () {
      final stack = PlaceholderStack();
      expect(stack.depth, 1);
      stack.bind('x', 'root');
      expect(stack.has('x'), isTrue);
      expect(stack.lookup('x'), 'root');
      expect(stack.has('missing'), isFalse);
      expect(stack.lookup('missing'), isNull);
    });

    test('push adds a child frame; same-name binding shadows the parent', () {
      final stack = PlaceholderStack();
      stack.bind('x', 'outer');
      stack.push();
      expect(stack.depth, 2);
      stack.bind('x', 'inner');
      expect(stack.lookup('x'), 'inner');
    });

    test('pop discards the child and restores the parent binding', () {
      final stack = PlaceholderStack();
      stack.bind('x', 'outer');
      stack.push();
      stack.bind('x', 'inner');
      stack.pop();
      expect(stack.depth, 1);
      expect(stack.lookup('x'), 'outer');
    });

    test('pop on the root frame is refused', () {
      final stack = PlaceholderStack();
      expect(stack.pop, throwsStateError);
    });

    test('flatten merges root→top with the child winning on collisions', () {
      final stack = PlaceholderStack();
      stack.bind('a', 1);
      stack.bind('b', 1);
      stack.push();
      stack.bind('b', 2);
      stack.bind('c', 3);
      expect(stack.flatten(), <String, Object?>{'a': 1, 'b': 2, 'c': 3});
    });

    test('bindAll seeds several bindings into the current frame', () {
      final stack = PlaceholderStack();
      stack.bindAll(<String, Object?>{'a': 1, 'b': 'two'});
      expect(stack.lookup('a'), 1);
      expect(stack.lookup('b'), 'two');
    });
  });

  group('isSimpleIdentifier', () {
    test('accepts identifier-shaped names, rejects everything else', () {
      expect(isSimpleIdentifier('name'), isTrue);
      expect(isSimpleIdentifier('_private'), isTrue);
      expect(isSimpleIdentifier('a1_b2'), isTrue);
      expect(isSimpleIdentifier('1abc'), isFalse);
      expect(isSimpleIdentifier('a.b'), isFalse);
      expect(isSimpleIdentifier('a b'), isFalse);
      expect(isSimpleIdentifier(''), isFalse);
    });

    test('it does not constrain what bind accepts or the stack stores', () {
      // Reading the predicate as "the shape the simple ${name} fast path
      // accepts" is the plausible one and overstates it: nothing in this package
      // applies it. bind takes any string, and flatten hands every binding to
      // the backing unfiltered. The
      // filtering happens in the backing (D4rtExpressionContext), because the
      // constraint is d4rt's, not the stack's.
      final stack = PlaceholderStack();
      stack.bind('role.anchor', 'ANCHOR');
      stack.bind('a b', 'SPACED');
      expect(isSimpleIdentifier('role.anchor'), isFalse);
      expect(isSimpleIdentifier('a b'), isFalse);

      expect(stack.has('role.anchor'), isTrue);
      expect(stack.lookup('role.anchor'), 'ANCHOR');
      expect(
        stack.flatten().keys,
        containsAll(<String>['role.anchor', 'a b']),
        reason:
            'flatten must not filter — the backing decides what it can '
            'express',
      );
    });
  });
}

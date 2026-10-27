// Tests for the domain-free plan-step topological ordering helper.
//
// A planning loop orders a decomposed step set over its `depends-on` edges
// before persisting the plan: a dependency must come before the step that
// needs it, and a cyclic graph is rejected with the cycle named rather than
// silently dropped, so the caller can see which steps made it cyclic. The
// graph arithmetic that
// does this — Kahn's algorithm over a step-id → dependency-id adjacency — is
// domain-free: it knows nothing about plans, steps, or memory nodes, only
// about ids and the edges between them. So it lives here, consumed natively by
// the `PlanStepsInOrder` query that re-derives canonical order on read.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('orderPlanSteps — acyclic', () {
    test('a linear chain orders dependencies first', () {
      final result = orderPlanSteps(<String, Iterable<String>>{
        'c': <String>['b'],
        'b': <String>['a'],
        'a': <String>[],
      });
      expect(result.hasCycle, isFalse);
      expect(result.cyclic, isEmpty);
      expect(result.order, <String>['a', 'b', 'c']);
    });

    test('a diamond places the fork before both arms and the join last', () {
      // a → {b, c} → d
      final result = orderPlanSteps(<String, Iterable<String>>{
        'a': <String>[],
        'b': <String>['a'],
        'c': <String>['a'],
        'd': <String>['b', 'c'],
      });
      expect(result.hasCycle, isFalse);
      expect(result.order.first, 'a');
      expect(result.order.last, 'd');
      expect(result.order.indexOf('b'), greaterThan(result.order.indexOf('a')));
      expect(result.order.indexOf('c'), greaterThan(result.order.indexOf('a')));
      expect(result.order.indexOf('d'), greaterThan(result.order.indexOf('b')));
      expect(result.order.indexOf('d'), greaterThan(result.order.indexOf('c')));
    });

    test('independent steps keep their insertion order (deterministic)', () {
      final result = orderPlanSteps(<String, Iterable<String>>{
        'x': <String>[],
        'y': <String>[],
        'z': <String>[],
      });
      expect(result.order, <String>['x', 'y', 'z']);
    });

    test('a ready step is emitted in insertion order, not discovery order', () {
      // Both 'b' and 'c' become ready the moment 'a' is placed; the original
      // key order (b before c) must break the tie.
      final result = orderPlanSteps(<String, Iterable<String>>{
        'a': <String>[],
        'b': <String>['a'],
        'c': <String>['a'],
      });
      expect(result.order, <String>['a', 'b', 'c']);
    });

    test('an empty graph orders to nothing', () {
      final result = orderPlanSteps(const <String, Iterable<String>>{});
      expect(result.order, isEmpty);
      expect(result.cyclic, isEmpty);
      expect(result.hasCycle, isFalse);
    });

    test(
      'a dependency on an unknown (external) id is ignored for ordering',
      () {
        // 'a' depends on 'user', which is not a step in the graph — an external
        // owner. It must not block 'a' from being ordered.
        final result = orderPlanSteps(<String, Iterable<String>>{
          'a': <String>['user'],
          'b': <String>['a'],
        });
        expect(result.hasCycle, isFalse);
        expect(result.order, <String>['a', 'b']);
      },
    );

    test('duplicate dependency edges do not double-count', () {
      final result = orderPlanSteps(<String, Iterable<String>>{
        'a': <String>[],
        'b': <String>['a', 'a', 'a'],
      });
      expect(result.hasCycle, isFalse);
      expect(result.order, <String>['a', 'b']);
    });
  });

  group('orderPlanSteps — cyclic', () {
    test('a two-node cycle is reported and excluded from the order', () {
      final result = orderPlanSteps(<String, Iterable<String>>{
        'a': <String>['b'],
        'b': <String>['a'],
      });
      expect(result.hasCycle, isTrue);
      expect(result.cyclic, <String>['a', 'b']);
      expect(result.order, isEmpty);
    });

    test('a self-dependency is a cycle', () {
      final result = orderPlanSteps(<String, Iterable<String>>{
        'a': <String>['a'],
      });
      expect(result.hasCycle, isTrue);
      expect(result.cyclic, <String>['a']);
      expect(result.order, isEmpty);
    });

    test('the acyclic part is ordered; only the cycle is quarantined', () {
      // a is free; b↔c is a cycle; d depends on the cycle so it is trapped too.
      final result = orderPlanSteps(<String, Iterable<String>>{
        'a': <String>[],
        'b': <String>['c'],
        'c': <String>['b'],
        'd': <String>['c'],
      });
      expect(result.hasCycle, isTrue);
      expect(result.order, <String>['a']);
      expect(result.cyclic, <String>['b', 'c', 'd']);
    });

    test('cyclic ids are reported in insertion order', () {
      final result = orderPlanSteps(<String, Iterable<String>>{
        'z': <String>['y'],
        'y': <String>['z'],
      });
      expect(result.cyclic, <String>['z', 'y']);
    });
  });
}

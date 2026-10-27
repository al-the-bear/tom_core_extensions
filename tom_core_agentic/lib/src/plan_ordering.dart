// Domain-free topological ordering of a plan's steps over their dependencies.
//
// A planning loop orders a decomposed step set before persisting it: every
// `depends-on` edge must point backwards in the final sequence, and a cyclic
// graph is rejected with the offending steps named rather than silently
// dropped, because a cycle means the decomposition is wrong and the caller has
// to see which steps made it so. That is pure graph arithmetic — Kahn's
// algorithm over a
// step-id → dependency-id adjacency — and knows nothing about plans, memory
// nodes, or LLM roles, only about ids and the edges between them. So it lives
// here, exactly like `scoreProcedureCandidate`, reusable from any agent
// runtime.
//
// The owning layer is responsible for *building* the adjacency (reading the
// persisted `depends_on` edges off a plan's `PlanStep` nodes) and for *acting*
// on a reported cycle (rejecting the decomposition, naming the cycle in the
// estimator's retry context). This helper only orders and detects, so the
// ordering policy — what counts as a dependency, how a cycle is surfaced —
// stays one decision in one place. Its native consumer is the
// `PlanStepsInOrder` query, which re-derives canonical order on read.

/// The outcome of topologically ordering a plan's steps.
///
/// A well-formed plan graph is a DAG, so [cyclic] is empty and [order] holds
/// every step in dependency-first order. When the decomposer emits a cycle the
/// trapped steps cannot be placed: [order] holds the steps that *could* be
/// ordered (the acyclic remainder, still in valid topological order) and
/// [cyclic] names the rest so the loop can reject and retry with the cycle
/// identified.
final class PlanStepOrdering {
  /// Step ids in dependency-first order: for every edge `x depends-on y`, `y`
  /// precedes `x`. Holds only the steps not trapped in (or behind) a cycle.
  final List<String> order;

  /// Step ids that participate in a dependency cycle, or depend transitively on
  /// one, and so have no valid position. Empty when the graph is acyclic.
  /// Reported in the adjacency's insertion order for a stable message.
  final List<String> cyclic;

  const PlanStepOrdering({required this.order, required this.cyclic});

  /// Whether the graph contained at least one dependency cycle.
  bool get hasCycle => cyclic.isNotEmpty;
}

/// Topologically orders the steps described by [dependencies] (Kahn's
/// algorithm).
///
/// [dependencies] maps each step id to the ids it depends on — the steps that
/// must come before it. A dependency on an id that is not itself a key (an
/// external owner such as the user) is ignored for ordering; duplicate edges
/// are counted once; a self-dependency is a cycle.
///
/// The order is deterministic: whenever several steps are simultaneously ready
/// (all their dependencies already placed), they are emitted in [dependencies]'
/// insertion order. Steps trapped in a cycle are returned via
/// [PlanStepOrdering.cyclic] rather than thrown — naming the cycle is the
/// loop's data, not an exception.
PlanStepOrdering orderPlanSteps(Map<String, Iterable<String>> dependencies) {
  // Stable index over the steps for deterministic tie-breaking.
  final index = <String, int>{};
  for (final id in dependencies.keys) {
    index[id] = index.length;
  }

  // Reverse adjacency (dependency → dependents) and in-degree, counting each
  // distinct dependency edge once and only when it points at a known step.
  final dependents = <String, List<String>>{};
  final inDegree = <String, int>{for (final id in dependencies.keys) id: 0};
  for (final entry in dependencies.entries) {
    final step = entry.key;
    final seen = <String>{};
    for (final dep in entry.value) {
      if (!index.containsKey(dep)) continue; // external / dangling owner
      if (!seen.add(dep)) continue; // duplicate edge
      dependents.putIfAbsent(dep, () => <String>[]).add(step);
      inDegree[step] = inDegree[step]! + 1;
    }
  }

  // Kahn: repeatedly emit a ready step (in-degree 0), relaxing its dependents.
  final ready = <String>[
    for (final id in dependencies.keys)
      if (inDegree[id] == 0) id,
  ];
  final order = <String>[];
  while (ready.isNotEmpty) {
    // Lowest original index first → deterministic among simultaneously-ready.
    ready.sort((a, b) => index[a]!.compareTo(index[b]!));
    final step = ready.removeAt(0);
    order.add(step);
    for (final dependent in dependents[step] ?? const <String>[]) {
      final remaining = inDegree[dependent]! - 1;
      inDegree[dependent] = remaining;
      if (remaining == 0) ready.add(dependent);
    }
  }

  // Whatever never reached in-degree 0 is in or behind a cycle.
  final placed = order.toSet();
  final cyclic = <String>[
    for (final id in dependencies.keys)
      if (!placed.contains(id)) id,
  ];
  return PlanStepOrdering(order: order, cyclic: cyclic);
}

/// The permission scope of an invocation and the one guard every target of
/// every call passes, read or write, in a fixed gate order.
///
/// **One function, five gates, one order:**
///
/// 1. **exclusion**, unconditional, before any grant is consulted — a target
///    the application keeps out of the surface altogether (its predicate,
///    asked once per target and carried as [AgentGuardTarget.excluded]);
/// 2. the **write gate** — a write under a scope that does not allow one;
/// 3. the **kind gate** — a target kind outside [AgentScope.allowedKinds];
/// 4. the **id gate** — a target id outside [AgentScope.allowedIds];
/// 5. otherwise **allow**.
///
/// Reads face the same function: gate 2 cannot fire for them, and gates 1, 3
/// and 4 can. A denial names the gate that refused it ([AgentScopeGate]),
/// which is what the audit trail records beside the reason.
///
/// The order is the point: gate 1 is asked before any grant, so an excluded
/// target is refused as excluded under every scope — a read-only one, and one
/// whose id set names it.
library;

/// What an invocation may touch. Immutable once made; least privilege by
/// construction.
final class AgentScope {
  /// Null admits any id (still bounded by [allowedKinds] and [allowWrite]);
  /// otherwise exactly these ids.
  final Set<String>? allowedIds;

  /// The target kinds that may be touched; null admits every kind.
  final Set<String>? allowedKinds;

  /// False is a read-only scope: every write is refused at gate 2.
  final bool allowWrite;

  AgentScope({
    Set<String>? allowedIds,
    Set<String>? allowedKinds,
    this.allowWrite = true,
  }) : allowedIds = allowedIds == null ? null : Set.unmodifiable(allowedIds),
       allowedKinds = allowedKinds == null
           ? null
           : Set.unmodifiable(allowedKinds);

  /// Whether this scope admits every target of the given [kinds]: any id, and
  /// each of the kinds. An operation that reaches a whole resource rather than
  /// the targets it names is admitted only under such a scope.
  bool covers(Iterable<String> kinds) =>
      allowedIds == null &&
      (allowedKinds == null || allowedKinds!.containsAll(kinds));

  /// Whether [kind] is admitted at gate 3.
  bool admitsKind(String kind) => allowedKinds?.contains(kind) ?? true;

  @override
  String toString() =>
      'AgentScope(ids: ${allowedIds == null ? 'any' : allowedIds!.length}, '
      'kinds: ${allowedKinds == null ? 'any' : allowedKinds!.join(',')}, '
      'write: $allowWrite)';
}

/// The gate a guard denial names — its number, and the reason the audit trail
/// records.
enum AgentScopeGate {
  excluded(1, 'excluded'),
  write(2, 'read-only'),
  kind(3, 'type-out-of-scope'),
  id(4, 'id-out-of-scope');

  const AgentScopeGate(this.number, this.auditReason);

  /// 1–4, the position in the fixed order. Gate 5 is "allow" and is never a
  /// denial.
  final int number;

  final String auditReason;
}

/// What a guard is asked about: one target a call reads or writes, or one it
/// is about to create.
final class AgentGuardTarget {
  /// The target's id; null for a target being created, which has no id a
  /// scope could have named when it was made.
  final String? id;

  final String kind;

  /// Gate 1's fact: the application keeps this target out of the surface.
  final bool excluded;

  /// For a target being created: where it is placed. Gate 4 admits a new
  /// target through its parent, because the parent is the scope's grant.
  final String? parentId;

  const AgentGuardTarget({
    required String this.id,
    required this.kind,
    this.excluded = false,
  }) : parentId = null;

  const AgentGuardTarget.creating(
    this.kind, {
    this.parentId,
    this.excluded = false,
  }) : id = null;
}

/// The gate that denies [target] under [scope], or null when it is allowed
/// (gate 5). [write] says whether the call writes it.
AgentScopeGate? agentGuard(
  AgentScope scope,
  AgentGuardTarget target, {
  required bool write,
}) {
  if (target.excluded) return AgentScopeGate.excluded;
  if (write && !scope.allowWrite) return AgentScopeGate.write;
  if (!scope.admitsKind(target.kind)) return AgentScopeGate.kind;
  final ids = scope.allowedIds;
  if (ids != null) {
    final id = target.id;
    final parentId = target.parentId;
    final admitted = id != null
        ? ids.contains(id)
        : parentId != null && ids.contains(parentId);
    if (!admitted) return AgentScopeGate.id;
  }
  return null;
}

/// A tool, the context its calls run against, and the registry a presentation
/// renders.
///
/// **One registry, several presentations.** A presentation — a provider's
/// native tool declarations, the in-process MCP server, an interpreter's
/// bridge library — renders a registry and never extends it. All of them call
/// the same [AgentTool] objects through [AgentToolRegistry.invoke], which is
/// what keeps "not two definitions" structural rather than a convention.
///
/// **Derived, not listed twice.** A tool that runs a program declares
/// [AgentTool.needsExecution]; the set offered to a program is the registry
/// filtered by it ([AgentToolRegistry.where]). A later tool that executes
/// something is excluded from programs on the day it is added, by the
/// declaration it has to carry anyway — which is what keeps an
/// agent → program → agent call graph bounded.
library;

import 'dart:async';

import 'audit.dart';
import 'errors.dart';
import 'invocation.dart';
import 'schema.dart';
import 'scope.dart';

/// What a tool's body does, once its arguments have been validated.
typedef AgentToolInvoke<C extends AgentToolContext> =
    FutureOr<Object?> Function(C context, Map<String, Object?> arguments);

/// Whether the tool call running now writes its targets — the zone value
/// [AgentTool.call] sets from the tool's declaration.
const _callWritesKey = #agentToolCallWrites;

/// A named, declared operation on behalf of an agent.
final class AgentTool<C extends AgentToolContext> {
  /// Stable, snake_case.
  final String name;

  final String summary;

  final AgentToolSchema arguments;

  /// Prose description of the returned shape. Prose rather than a second
  /// schema because nothing validates a result — the caller is the model, and
  /// a schema nobody checks is a claim nobody keeps.
  final String result;

  /// Drives the guard's write gate: every target a write tool names is guarded
  /// as written, every target a read tool names as read. Declared once, here,
  /// and read by [AgentToolContext.guard] — not restated at each target.
  final bool isWrite;

  /// Drives the execution-consent gate, and the derived program tool set.
  final bool needsExecution;

  /// The body. Private, so the only way to run a tool is [call] — which is
  /// what makes the audit trail complete by construction.
  final AgentToolInvoke<C> _invoke;

  const AgentTool({
    required this.name,
    required this.summary,
    required this.result,
    required AgentToolInvoke<C> invoke,
    this.arguments = AgentToolSchema.empty,
    this.isWrite = false,
    this.needsExecution = false,
  }) : _invoke = invoke;

  /// Validates, then dispatches — in one place, so no presentation can skip a
  /// step — inside the audit recording of this call.
  ///
  /// The scope gates are **not** asked here. They are asked of each target the
  /// call resolves, through [AgentToolContext.guard], because the exclusion
  /// gate is a fact about the target: a write cannot be refused as read-only
  /// before anyone has looked at whether its target is excluded outright. The
  /// call's declaration — [isWrite] — travels with it in a zone, so every
  /// target is guarded as what the tool does to it.
  FutureOr<Object?> call(C context, Map<String, Object?> raw) =>
      AgentAuditRecording.run(
        name,
        context,
        raw,
        () => runZoned(
          () => _invoke(context, arguments.validate(raw)),
          zoneValues: {_callWritesKey: isWrite},
        ),
      );

  /// The tool as MCP's `tools/list` entry.
  Map<String, Object?> toJsonSchema() => {
    'name': name,
    'description': summary,
    'inputSchema': arguments.toJsonSchema(),
  };
}

/// What one invocation may reach, and how its calls are recorded.
///
/// An application extends it with what its tools need — the resources they
/// address and how a target becomes an [AgentGuardTarget] — and implements
/// the two transaction operations an agent run needs: [runAtomically] and
/// [dryRunCopy].
abstract class AgentToolContext {
  AgentToolContext({required this.invocation, required this.audit});

  /// The record this call belongs to — immutable, and the **only** place
  /// execution consent exists.
  final AgentInvocation invocation;

  /// Where every call made through this context is recorded.
  final AgentAuditLog audit;

  /// The invocation's scope, read by [guard].
  AgentScope get scope => invocation.scope;

  /// Whether a tool that runs a program may run one. Read from the
  /// invocation; a context cannot be told otherwise.
  bool get allowExecution => invocation.allowExecution;

  int _undoChain = 0;

  /// The next position in this invocation's undo chain — the `undoRef` of an
  /// applied mutation. One context serves one invocation, so the chain is the
  /// context's.
  int nextUndoRef() => _undoChain++;

  /// Whether the tool call running now writes its targets. Outside any call,
  /// true: the stricter answer.
  static bool get callWrites => Zone.current[_callWritesKey] as bool? ?? true;

  /// The guard's verdict on [target] for the call running now: the gate that
  /// refuses it, or null. The target is guarded as written when the running
  /// tool declares `isWrite`, as read otherwise.
  AgentScopeGate? guard(AgentGuardTarget target) =>
      agentGuard(scope, target, write: callWrites);

  /// The guard's verdict on [target] as a read, for reads that enumerate: an
  /// entry the guard would refuse is left out of their answer.
  bool shows(AgentGuardTarget target) =>
      agentGuard(scope, target, write: false) == null;

  /// The argument keys that name a call's target, first present wins — what
  /// the audit trail records as `targetId`.
  List<String> get auditTargetKeys => const ['id'];

  /// The argument key that names the resource a call addresses.
  String get auditLocatorKey => 'locator';

  /// Zone values installed for the length of one call, beside its recording —
  /// how an application wires the function its writes run through to
  /// [AgentAuditRecording.recordMutation].
  Map<Object?, Object?> callZoneValues(AgentAuditRecording recording) =>
      const {};

  /// The result keys that carry the id of something a call created — how a
  /// dry run replays a recorded call that later calls refer to by that id.
  List<String> get createdIdKeys => const ['id'];

  /// Runs [body] as **one** atomic unit over everything this invocation may
  /// write: if it throws, every write is rolled back; if it returns, each
  /// resource written holds one undo entry for the whole of it.
  Future<T> runAtomically<T>(String label, Future<T> Function() body);

  /// A context over **copies** of what this one reaches, for a dry run: the
  /// same invocation and the same rules, a scratch audit log, and nothing a
  /// call does reaching the real resources.
  AgentToolContext dryRunCopy();
}

/// A set of tools a presentation renders.
///
/// [where] can only remove, so a set derived from a registry never holds a
/// tool the registry does not. An application that wants its surface closed
/// constructs its registry once and derives every other set from it.
final class AgentToolRegistry<C extends AgentToolContext> {
  final List<AgentTool<C>> tools;

  AgentToolRegistry(List<AgentTool<C>> tools)
    : tools = List.unmodifiable(tools);

  List<String> get names => [for (final tool in tools) tool.name];

  AgentTool<C>? operator [](String name) {
    for (final tool in tools) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  /// [name]'s tool, or a refusal.
  ///
  /// A tool another set holds but this one does not is indistinguishable from
  /// a typo, and deliberately so: no error tells a caller which call would
  /// have worked.
  AgentTool<C> require(String name) =>
      this[name] ??
      (throw AgentToolException(
        AgentToolErrorCode.invalidArgument,
        'No tool named "$name".',
        argument: 'name',
      ));

  /// Calls the tool [name] names with [arguments] — **the** entry a
  /// presentation uses.
  ///
  /// A name this set does not hold is refused exactly as [require] refuses
  /// it, and that refusal is recorded too: a call naming a tool that does not
  /// exist is still a call, and the likeliest shape of an agent probing the
  /// surface.
  FutureOr<Object?> invoke(
    C context,
    String name,
    Map<String, Object?> arguments,
  ) {
    final tool = this[name];
    if (tool != null) return tool.call(context, arguments);
    return refuse(context, name, arguments, () => require(name));
  }

  /// Refuses a call to [name] with whatever [refusal] throws, **recording**
  /// the refusal as a call — for a presentation that must turn a call away
  /// without running any tool, and must not let it vanish from the trail.
  static FutureOr<Object?> refuse(
    AgentToolContext context,
    String name,
    Map<String, Object?> arguments,
    Object? Function() refusal,
  ) {
    // Bounded: the name is the caller's string, and the trail records
    // identifiers, not whatever a caller chose to send in their place.
    final recorded = name.length <= 64 ? name : '${name.substring(0, 64)}…';
    return AgentAuditRecording.run(recorded, context, arguments, refusal);
  }

  /// The subset of this set [test] keeps — the only way to derive another
  /// presentation's set, and one that can only remove.
  AgentToolRegistry<C> where(bool Function(AgentTool<C>) test) =>
      AgentToolRegistry([
        for (final tool in tools)
          if (test(tool)) tool,
      ]);
}

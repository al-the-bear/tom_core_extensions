# Tom Core Agentic API Reference: Agent Tools

The symbol-level mirror of the public library
`package:tom_core_agentic/agent_tools.dart`, which exports the eight libraries
under `lib/src/agent_tools/`: 35 exported types (including two typedefs) and
7 top-level functions, with no public top-level constants.

[`doc/agent_tools.md`](../agent_tools.md) introduces the module: declared tools,
a permission scope with a fixed gate order, an invocation record that carries
execution consent, an append-only audit trail, the presentations a model sees
and preview-then-apply runs. This document is arranged for lookup instead: one
heading per symbol, grouped by the library that declares it.

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
  - [AgentToolInvoke](#agenttoolinvoke)
  - [AgentTool](#agenttool)
  - [AgentToolContext](#agenttoolcontext)
  - [AgentToolRegistry](#agenttoolregistry)
  - [AgentToolValueType](#agenttoolvaluetype)
  - [AgentToolArgument](#agenttoolargument)
  - [AgentToolSchema](#agenttoolschema)
  - [AgentScope](#agentscope)
  - [AgentScopeGate](#agentscopegate)
  - [AgentGuardTarget](#agentguardtarget)
  - [AgentOrigin](#agentorigin)
  - [AgentExecutionGrant](#agentexecutiongrant)
  - [AgentInvocation](#agentinvocation)
  - [AgentToolErrorCode](#agenttoolerrorcode)
  - [AgentToolException](#agenttoolexception)
  - [AgentAuditEntryPoint](#agentauditentrypoint)
  - [AgentAuditOutcome](#agentauditoutcome)
  - [AgentAuditEntry](#agentauditentry)
  - [AgentAuditLog](#agentauditlog)
  - [AgentMemoryAuditLog](#agentmemoryauditlog)
  - [AgentAuditStore](#agentauditstore)
  - [AgentFileAuditLog](#agentfileauditlog)
  - [AgentAuditExecution](#agentauditexecution)
  - [AgentAuditRecording](#agentauditrecording)
  - [AgentRunStep](#agentrunstep)
  - [AgentToolResult](#agenttoolresult)
  - [AgentToolBinding](#agenttoolbinding)
  - [AgentInProcessMcpServer](#agentinprocessmcpserver)
  - [AgentRunStatus](#agentrunstatus)
  - [AgentRunOutcome](#agentrunoutcome)
  - [AgentRun](#agentrun)
  - [AgentProposalStatus](#agentproposalstatus)
  - [AgentProposalOutcome](#agentproposaloutcome)
  - [AgentAtomicScope](#agentatomicscope)
  - [AgentPreviewThenApply](#agentpreviewthenapply)
- [Global Functions and Constants](#global-functions-and-constants)
  - [agentGuard](#agentguard)
  - [agentFilterAudit](#agentfilteraudit)
  - [agentAuditExecutionStarted](#agentauditexecutionstarted)
  - [agentAuditResolved](#agentauditresolved)
  - [agentAuditExecution](#agentauditexecution-1)
  - [agentAuditCallIsOneGroup](#agentauditcallisonegroup)
  - [agentAuditEntering](#agentauditentering)

## Overview

The library `lib/agent_tools.dart` re-exports eight libraries. Its import
closure reaches no `dart:io`, so it links into a browser build.

Sources:

| Source | File declares |
| ------ | ------------- |
| `lib/src/agent_tools/tool.dart` | `AgentToolInvoke`, `AgentTool`, `AgentToolContext`, `AgentToolRegistry` |
| `lib/src/agent_tools/schema.dart` | `AgentToolValueType`, `AgentToolArgument`, `AgentToolSchema` |
| `lib/src/agent_tools/scope.dart` | `AgentScope`, `AgentScopeGate`, `AgentGuardTarget`, `agentGuard` |
| `lib/src/agent_tools/invocation.dart` | `AgentOrigin`, `AgentExecutionGrant`, `AgentInvocation` |
| `lib/src/agent_tools/errors.dart` | `AgentToolErrorCode`, `AgentToolException` |
| `lib/src/agent_tools/audit.dart` | `AgentAuditEntryPoint`, `AgentAuditOutcome`, `AgentAuditEntry`, `AgentAuditLog`, `AgentMemoryAuditLog`, `AgentAuditStore`, `AgentFileAuditLog`, `AgentAuditExecution`, `AgentAuditRecording`, `agentFilterAudit`, `agentAuditExecutionStarted`, `agentAuditResolved`, `agentAuditExecution`, `agentAuditCallIsOneGroup`, `agentAuditEntering` |
| `lib/src/agent_tools/binding.dart` | `AgentRunStep`, `AgentToolResult`, `AgentToolBinding`, `AgentInProcessMcpServer`, `AgentRunStatus`, `AgentRunOutcome`, `AgentRun` |
| `lib/src/agent_tools/preview_then_apply.dart` | `AgentProposalStatus`, `AgentProposalOutcome`, `AgentAtomicScope`, `AgentPreviewThenApply` |

**One registry, several presentations.** `AgentToolBinding` (native tool
declarations) and `AgentInProcessMcpServer` (an in-process JSON-RPC handler)
both render an `AgentToolRegistry` and dispatch back into it through
`AgentToolRegistry.invoke`, so neither can declare or run a tool the registry
does not hold. Every call goes through `AgentTool.call`, which validates the
arguments and records the call in the audit trail, so the trail is complete by
construction. The scope gates are asked per target, through
`AgentToolContext.guard`.

## Class Hierarchy

```text
AgentTool<C extends AgentToolContext>
AgentToolContext (abstract)
AgentToolRegistry<C extends AgentToolContext>
AgentToolArgument
AgentToolSchema
AgentScope
AgentGuardTarget
AgentExecutionGrant
AgentInvocation
AgentToolErrorCode
Exception
└── AgentToolException
AgentAuditEntry
AgentAuditLog (abstract)
├── AgentMemoryAuditLog
└── AgentFileAuditLog
AgentAuditStore (abstract interface)
AgentAuditExecution
AgentAuditRecording
AgentRunStep
AgentToolResult
LlmToolBinding (tom_llm)
└── AgentToolBinding<C extends AgentToolContext>
AgentInProcessMcpServer
AgentRunOutcome
AgentRun (abstract final, static only)
AgentProposalOutcome<P>
AgentPreviewThenApply (abstract final, static only)

enum AgentToolValueType, AgentScopeGate, AgentOrigin, AgentAuditEntryPoint,
     AgentAuditOutcome, AgentRunStatus, AgentProposalStatus
typedef AgentToolInvoke<C>, AgentAtomicScope
```

## Classes

**Tools and the registry.** Declared in `lib/src/agent_tools/tool.dart`.

### AgentToolInvoke

`typedef AgentToolInvoke<C extends AgentToolContext> = FutureOr<Object?> Function(C context, Map<String, Object?> arguments)`.
What a tool's body does once its arguments have been validated: it receives the
context and the validated, narrowed argument map.

### AgentTool

`final class AgentTool<C extends AgentToolContext>`. A named, declared operation
on behalf of an agent. The body is private, so the only way to run a tool is
`call`, which validates the arguments against the schema and dispatches inside
the audit recording of the call. The scope gates are not asked here but per
target through `AgentToolContext.guard`; the tool's `isWrite` declaration
travels with the call in a zone so every target is guarded as what the tool
does to it.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentTool` | `const AgentTool({required String name, required String summary, required String result, required AgentToolInvoke<C> invoke, AgentToolSchema arguments = AgentToolSchema.empty, bool isWrite = false, bool needsExecution = false})` | Declares a tool. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `name` | `final String name` | Stable, snake_case name. |
| `summary` | `final String summary` | The description presentations show the model. |
| `arguments` | `final AgentToolSchema arguments` | The declared arguments, validated before the body runs. |
| `result` | `final String result` | Prose description of the returned shape; nothing validates a result. |
| `isWrite` | `final bool isWrite` | Drives the guard's write gate: every target the tool names is guarded as written when true, as read otherwise. |
| `needsExecution` | `final bool needsExecution` | Drives the execution-consent gate and the derived program tool set. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `call` | `FutureOr<Object?> call(C context, Map<String, Object?> raw)` | Validates `raw` against `arguments`, then runs the body inside `AgentAuditRecording.run`, with the tool's `isWrite` in a zone. |
| `toJsonSchema` | `Map<String, Object?> toJsonSchema()` | The tool as MCP's `tools/list` entry: `{name, description, inputSchema}`. |

### AgentToolContext

`abstract class`. What one invocation may reach and how its calls are recorded.
An application extends it with what its tools need and implements the two
transaction operations an agent run needs, `runAtomically` and `dryRunCopy`.
One context serves one invocation.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolContext` | `AgentToolContext({required AgentInvocation invocation, required AgentAuditLog audit})` | Binds the context to its invocation and audit log. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `invocation` | `final AgentInvocation invocation` | The immutable invocation record, the only place execution consent exists. |
| `audit` | `final AgentAuditLog audit` | Where every call made through this context is recorded. |
| `scope` | `AgentScope get scope` | The invocation's scope, read by `guard`. |
| `allowExecution` | `bool get allowExecution` | Whether a tool that runs a program may run one; read from the invocation. |
| `auditTargetKeys` | `List<String> get auditTargetKeys` | Argument keys that name a call's target, first present wins; recorded as `targetId`. Default `['id']`. |
| `auditLocatorKey` | `String get auditLocatorKey` | Argument key naming the resource a call addresses. Default `'locator'`. |
| `createdIdKeys` | `List<String> get createdIdKeys` | Result keys carrying the id of something a call created, used when a dry run replays recorded calls. Default `['id']`. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `nextUndoRef` | `int nextUndoRef()` | The next position in this invocation's undo chain (starting at 0). |
| `guard` | `AgentScopeGate? guard(AgentGuardTarget target)` | The gate that refuses `target` for the call running now, or null; guarded as a write when the running tool declares `isWrite`. |
| `shows` | `bool shows(AgentGuardTarget target)` | Whether `target` passes the guard as a read; for enumerating reads that leave refused entries out. |
| `callZoneValues` | `Map<Object?, Object?> callZoneValues(AgentAuditRecording recording)` | Zone values installed for one call beside its recording; how an application wires its write path to `AgentAuditRecording.recordMutation`. Default empty. |
| `runAtomically` | `Future<T> runAtomically<T>(String label, Future<T> Function() body)` | Abstract. Runs `body` as one atomic unit: rolled back if it throws, one undo entry per resource written otherwise. |
| `dryRunCopy` | `AgentToolContext dryRunCopy()` | Abstract. A context over copies of what this one reaches, with the same invocation and rules and a scratch audit log. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `callWrites` | `static bool get callWrites` | Whether the tool call running now writes its targets; true outside any call. |

### AgentToolRegistry

`final class AgentToolRegistry<C extends AgentToolContext>`. A closed set of
tools a presentation renders. `where` can only remove, so a set derived from a
registry never holds a tool the registry does not. A name the set does not hold
is refused with `E_INVALID_ARGUMENT`, indistinguishable from a typo.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolRegistry` | `AgentToolRegistry(List<AgentTool<C>> tools)` | Holds an unmodifiable copy of `tools`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `tools` | `final List<AgentTool<C>> tools` | The tools, unmodifiable. |
| `names` | `List<String> get names` | The tool names, in order. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `operator []` | `AgentTool<C>? operator [](String name)` | The tool named `name`, or null. |
| `require` | `AgentTool<C> require(String name)` | The tool named `name`, or throws `AgentToolException` (`invalidArgument`, argument `name`). |
| `invoke` | `FutureOr<Object?> invoke(C context, String name, Map<String, Object?> arguments)` | The entry a presentation uses: calls the named tool, or records and throws the same refusal `require` gives. |
| `where` | `AgentToolRegistry<C> where(bool Function(AgentTool<C>) test)` | The subset `test` keeps. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `refuse` | `static FutureOr<Object?> refuse(AgentToolContext context, String name, Map<String, Object?> arguments, Object? Function() refusal)` | Records a call to `name` and runs `refusal` (which throws) inside the recording, so a call turned away without running a tool still appears in the trail. Names longer than 64 characters are truncated in the record. |

**Argument schema.** Declared in `lib/src/agent_tools/schema.dart`.

### AgentToolValueType

`enum`. The value kinds a declared argument may take: the JSON type system, so
the same schema renders as MCP's `inputSchema` and as a provider's native tool
declaration.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `string` | `string('string')` | Accepts a `String`. |
| `integer` | `integer('integer')` | Accepts an `int` that is not a `bool`. |
| `boolean` | `boolean('boolean')` | Accepts a `bool`. |
| `object` | `object('object')` | Accepts a `Map`. |
| `array` | `array('array')` | Accepts a `List`. |

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolValueType` | `const AgentToolValueType(String jsonName)` | Enum constructor. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `jsonName` | `final String jsonName` | The JSON Schema type name. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `accepts` | `bool accepts(Object value)` | Whether `value` is of this kind. |

### AgentToolArgument

`final class`. One declared argument of a tool: name, kind, whether it is
required, a description, and optionally the closed list of values it accepts.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolArgument` | `const AgentToolArgument(String name, AgentToolValueType type, {bool required = false, String description = '', List<String>? allowed})` | Declares an argument. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `name` | `final String name` | The argument key. |
| `type` | `final AgentToolValueType type` | Its value kind. |
| `required` | `final bool required` | Whether a call must supply it. |
| `description` | `final String description` | Rendered into the schema when non-empty. |
| `allowed` | `final List<String>? allowed` | When non-null, the only values accepted; rendered as `enum`. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toJsonSchema` | `Map<String, Object?> toJsonSchema()` | `{type, description?, enum?}`. |

### AgentToolSchema

`final class`. A tool's declared argument set and the validation that runs
before any tool body. An unknown key is refused rather than ignored; a `null`
value reads as absence.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolSchema` | `const AgentToolSchema(List<AgentToolArgument> arguments)` | Declares the argument set. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `arguments` | `final List<AgentToolArgument> arguments` | The declared arguments. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `validate` | `Map<String, Object?> validate(Map<String, Object?> raw)` | `raw` checked and narrowed to the declared keys. Throws `AgentToolException` (`invalidArgument`, naming the argument) for an unknown key, a missing required argument, a wrong kind or a value outside `allowed`. |
| `toJsonSchema` | `Map<String, Object?> toJsonSchema()` | `{type: object, properties, required, additionalProperties: false}`. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `empty` | `static const empty = AgentToolSchema([])` | The schema with no arguments; the default of `AgentTool.arguments`. |

**Scope and guard.** Declared in `lib/src/agent_tools/scope.dart`. The guard `agentGuard` passes
every target through five gates in a fixed order: exclusion, write, kind, id,
allow.

### AgentScope

`final class`. What an invocation may touch: an optional id set, an optional
kind set and whether writes are allowed. Immutable once made; the sets are
stored unmodifiable.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentScope` | `AgentScope({Set<String>? allowedIds, Set<String>? allowedKinds, bool allowWrite = true})` | Builds a scope; null sets admit everything. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `allowedIds` | `final Set<String>? allowedIds` | Null admits any id; otherwise exactly these. |
| `allowedKinds` | `final Set<String>? allowedKinds` | Null admits every kind. |
| `allowWrite` | `final bool allowWrite` | False makes the scope read-only: every write is refused at gate 2. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `covers` | `bool covers(Iterable<String> kinds)` | Whether the scope admits every target of `kinds`: any id and each kind. |
| `admitsKind` | `bool admitsKind(String kind)` | Whether `kind` passes gate 3. |
| `toString` | `String toString()` | `AgentScope(ids: …, kinds: …, write: …)`. |

### AgentScopeGate

`enum`. The gate a guard denial names, with its position in the fixed order and
the reason the audit trail records. Gate 5 is "allow" and has no value.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `excluded` | `excluded(1, 'excluded')` | The application keeps the target out of the surface. |
| `write` | `write(2, 'read-only')` | A write under a read-only scope. |
| `kind` | `kind(3, 'type-out-of-scope')` | A kind outside `allowedKinds`. |
| `id` | `id(4, 'id-out-of-scope')` | An id outside `allowedIds`. |

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentScopeGate` | `const AgentScopeGate(int number, String auditReason)` | Enum constructor. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `number` | `final int number` | 1 to 4. |
| `auditReason` | `final String auditReason` | The deny reason recorded in the audit trail. |

### AgentGuardTarget

`final class`. One target a call reads or writes, or one it is about to create.
A target being created has no id; gate 4 admits it through its parent id.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentGuardTarget` | `const AgentGuardTarget({required String id, required String kind, bool excluded = false})` | An existing target. |
| `AgentGuardTarget.creating` | `const AgentGuardTarget.creating(String kind, {String? parentId, bool excluded = false})` | A target about to be created, placed under `parentId`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `id` | `final String? id` | The target's id; null for one being created. |
| `kind` | `final String kind` | The target's kind, checked at gate 3. |
| `excluded` | `final bool excluded` | Gate 1's fact: the application keeps this target out of the surface. |
| `parentId` | `final String? parentId` | For a target being created, where it is placed. |

**Invocation.** Declared in `lib/src/agent_tools/invocation.dart`.

### AgentOrigin

`enum`. Where an invocation came from. It has one value, so no code path can
construct a remote-origin invocation.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `localAgent` | `localAgent('local-agent')` | An in-process agent. |

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentOrigin` | `const AgentOrigin(String wire)` | Enum constructor. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `wire` | `final String wire` | The spelling on the wire and in the audit. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `parse` | `static AgentOrigin parse(String wire)` | The origin named `wire`; anything but `local-agent` throws `ArgumentError`. |

### AgentExecutionGrant

`final class`. The residual-risk statement an application shows a user before
granting execution, as the value `AgentInvocation.withExecution` checks the
shown text against.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentExecutionGrant` | `const AgentExecutionGrant(String statement)` | Declares the statement. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `statement` | `final String statement` | The text the grant affordance renders. |

### AgentInvocation

`final class`. One entry into the tool surface, immutable once minted. It
carries a random 128-bit hex id, the origin, the scope, the step and time
budgets of a tool-driven program run, and execution consent, which only
`AgentInvocation.withExecution` sets, and only when the text shown equals the
grant's statement. Widening requires a new invocation.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentInvocation.mint` | `factory AgentInvocation.mint({required AgentScope scope, int stepBudget = defaultStepBudget, Duration timeBudget = defaultTimeBudget})` | An invocation without execution. |
| `AgentInvocation.withExecution` | `factory AgentInvocation.withExecution({required AgentExecutionGrant grant, required String residualRiskShown, required AgentScope scope, int stepBudget = defaultStepBudget, Duration timeBudget = defaultTimeBudget})` | An invocation with execution; throws `ArgumentError` unless `residualRiskShown` equals `grant.statement`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `invocationId` | `final String invocationId` | Correlates the audit entries of one invocation. |
| `origin` | `final AgentOrigin origin` | Always `AgentOrigin.localAgent`. |
| `allowExecution` | `final bool allowExecution` | False unless minted by `withExecution`. |
| `scope` | `final AgentScope scope` | What this invocation may touch. |
| `stepBudget` | `final int stepBudget` | How many mutations a program run may apply. |
| `timeBudget` | `final Duration timeBudget` | How long a program run may take. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentInvocation(<id>, <origin>, execution: …, <scope>)`. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `defaultStepBudget` | `static const defaultStepBudget = 1000` | Default `stepBudget`. |
| `defaultTimeBudget` | `static const defaultTimeBudget = Duration(seconds: 30)` | Default `timeBudget`. |

**Errors.** Declared in `lib/src/agent_tools/errors.dart`. A caller-visible error is a
refusal: no code hints at a call that would widen permissions, and a missing
target reads the same whether unknown or excluded.

### AgentToolErrorCode

`final class`. One refusal kind: its `E_…` wire spelling, the reason the audit
trail records, and whether it reports a failure rather than a refusal. A class
rather than an enum, so an application adds its own codes beside the general
ones.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolErrorCode` | `const AgentToolErrorCode(String wire, String auditReason, {bool isFailure = false})` | Declares a code. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `wire` | `final String wire` | The spelling on the wire, `E_` and upper case. |
| `auditReason` | `final String auditReason` | How the audit trail names a refusal with this code. |
| `isFailure` | `final bool isFailure` | True when the code reports work that passed every gate and did not complete. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | The `wire` spelling. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `invalidArgument` | `static const invalidArgument` | `E_INVALID_ARGUMENT` / `invalid-argument`: schema violation, unknown tool, malformed argument. |
| `notFound` | `static const notFound` | `E_NOT_FOUND` / `not-found`: the target does not exist for this caller. |
| `outOfScope` | `static const outOfScope` | `E_OUT_OF_SCOPE` / `out-of-scope`: outside the invocation's scope. |
| `readOnly` | `static const readOnly` | `E_READ_ONLY` / `read-only`: a write under a read-only invocation. |
| `transactionFailed` | `static const transactionFailed` | `E_TRANSACTION_FAILED` / `transaction-failed`, `isFailure: true`: a step failed and the call was rolled back. |

### AgentToolException

`final class implements Exception`. A refused tool call, thrown from a tool's
body. It can carry a true audit reason and the refusing gate, which only the
audit trail sees: `toMap` and `toString` never render them.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolException` | `const AgentToolException(AgentToolErrorCode code, String message, {String? argument, int? step, String? auditReason, AgentScopeGate? gate})` | A refusal. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `code` | `final AgentToolErrorCode code` | The refusal kind. |
| `message` | `final String message` | The caller-visible message. |
| `argument` | `final String? argument` | The offending argument, when one is at fault. |
| `step` | `final int? step` | The 1-based failing step, one past the number of mutations applied. |
| `auditReason` | `String get auditReason` | The recorded deny reason: the given audit reason, else the gate's, else the code's. |
| `gate` | `AgentScopeGate? get gate` | The guard gate behind the refusal, or null. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toMap` | `Map<String, Object?> toMap()` | `{code, message, argument?, step?}`. |
| `toString` | `String toString()` | `<wire>: <message>` with the argument and step when set. |

**Audit trail.** Declared in `lib/src/agent_tools/audit.dart`. An entry holds operations, ids,
digests, sizes and reasons, and has no field that could hold content, program
source, program output or a credential.

### AgentAuditEntryPoint

`enum`. Which surface a call arrived on.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `agent` | `agent('agent')` | An in-process native call. |
| `mcp` | `mcp('mcp')` | The in-process MCP surface. |
| `rest` | `rest('rest')` | A network surface. |

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentAuditEntryPoint` | `const AgentAuditEntryPoint(String wire)` | Enum constructor. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `wire` | `final String wire` | The recorded spelling. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `parse` | `static AgentAuditEntryPoint parse(String wire)` | The value named `wire`; throws `FormatException` otherwise. |

### AgentAuditOutcome

`enum`. What became of the operation an entry records.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `applied` | `applied('applied')` | The operation took effect. |
| `denied` | `denied('denied')` | The operation was refused. |
| `rolledBack` | `rolledBack('rolled-back')` | Applied, then reversed because its call or run failed; the record of the attempt is kept. |
| `failed` | `failed('failed')` | The gates passed and the operation did not complete, with nothing to reverse. |

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentAuditOutcome` | `const AgentAuditOutcome(String wire)` | Enum constructor. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `wire` | `final String wire` | The recorded spelling. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `parse` | `static AgentAuditOutcome parse(String wire)` | The value named `wire`; throws `FormatException` otherwise. |

### AgentAuditEntry

`final class`. One audited operation. `allowed` is true exactly when
`denyReason` is null, and `gate` is set only on a denial (both asserted).

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentAuditEntry` | `const AgentAuditEntry({int opId = 0, required String op, required String? targetId, String? locator, required AgentAuditEntryPoint entry, required String scopeId, required bool allowed, String? denyReason, int? gate, int undoRef = -1, required DateTime appliedAt, required String toolName, String? programId, String? programSha256, required AgentAuditOutcome outcome, int? mutationCount, int? logBytes})` | Builds an entry; `opId` is assigned by `AgentAuditLog.append`. |
| `AgentAuditEntry.fromMap` | `factory AgentAuditEntry.fromMap(Map<Object?, Object?> map)` | Reads an entry back from `toMap`'s shape. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `opId` | `final int opId` | Monotonic across the log. |
| `op` | `final String op` | The mutation kind for a mutation, the tool name otherwise. |
| `targetId` | `final String? targetId` | The target the operation named. |
| `locator` | `final String? locator` | The resource the call reached, when known. |
| `entry` | `final AgentAuditEntryPoint entry` | The surface the call arrived on. |
| `scopeId` | `final String scopeId` | The invocation id. |
| `allowed` | `final bool allowed` | Whether the operation was allowed. |
| `denyReason` | `final String? denyReason` | Present iff not allowed: the true reason. |
| `gate` | `final int? gate` | For a guard denial, the refusing gate 1 to 4. |
| `undoRef` | `final int undoRef` | Position in the invocation's undo chain; -1 for a read, a denial and a rolled-back mutation. |
| `appliedAt` | `final DateTime appliedAt` | When the entry was made. |
| `toolName` | `final String toolName` | The tool that produced the entry. |
| `programId` | `final String? programId` | For a program run, the program executed (never its source). |
| `programSha256` | `final String? programSha256` | For a program run, the SHA-256 of the source that ran. |
| `outcome` | `final AgentAuditOutcome outcome` | What became of the operation. |
| `mutationCount` | `final int? mutationCount` | For the terminal entry of a program run. |
| `logBytes` | `final int? logBytes` | For the terminal entry of a program run: the size of its output, never the output. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `asRolledBack` | `AgentAuditEntry asRolledBack()` | An applied mutation (`undoRef >= 0`) as `rolledBack` with `undoRef` -1; any other entry unchanged. |
| `toMap` | `Map<String, Object?> toMap()` | The entry as a JSON-ready map, `appliedAt` as UTC ISO 8601, null fields left out. |
| `toString` | `String toString()` | A one-line debug form. |

### AgentAuditLog

`abstract class`. The append-only audit log. `append` is synchronous, so a
synchronous tool call from an interpreted program can record; persistence
follows asynchronously in append order and `flush` waits for it. Entries older
than `retention` are dropped from `entries` and storage; there is no other way
out of the log.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentAuditLog` | `AgentAuditLog({Duration retention = defaultRetention, DateTime Function()? clock})` | The clock defaults to UTC now. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `retention` | `Duration get retention` | How long an entry is kept. |
| `clock` | `final DateTime Function() clock` | The time source for entries and pruning. |
| `entries` | `List<AgentAuditEntry> get entries` | Every retained entry, oldest first, unmodifiable. |
| `appended` | `Stream<List<AgentAuditEntry>> get appended` | Each appended batch as it lands (broadcast). |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `applyRetention` | `void applyRetention(Duration value)` | Adopts a new retention, dropping what it no longer covers from `entries` and storage. |
| `pruneStorage` | `void pruneStorage()` | Deletes from storage what `retention` no longer covers; no-op by default. |
| `append` | `List<AgentAuditEntry> append(Iterable<AgentAuditEntry> batch)` | Appends `batch` in order, numbering it after the log's highest `opId`, persists it and emits it; answers the entries as stored. |
| `flush` | `Future<void> flush()` | Waits until every appended batch has been handed to storage. |
| `persist` | `void persist(List<AgentAuditEntry> batch)` | Stores one batch; called once per `append`, in order. No-op by default. |
| `dispose` | `Future<void> dispose()` | Flushes and closes `appended`. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `defaultRetention` | `static const defaultRetention = Duration(days: 90)` | The default retention. |

### AgentMemoryAuditLog

`final class extends AgentAuditLog`. An audit log kept for the life of the
process, for a build with nowhere to write and for tests.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentMemoryAuditLog` | `AgentMemoryAuditLog({Duration retention, DateTime Function()? clock})` | Passes both to `AgentAuditLog`. |

### AgentAuditStore

`abstract interface class`. The keyed file medium an `AgentFileAuditLog` keeps
its files in, supplied by the application. Keys are `/`-separated relative
paths.

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `listFiles` | `Future<List<String>> listFiles()` | Every key in the store. |
| `readString` | `Future<String> readString(String key)` | The file's text. |
| `writeString` | `Future<void> writeString(String key, String value)` | Writes a file. |
| `delete` | `Future<void> delete(String key)` | Deletes a file. |

### AgentFileAuditLog

`final class extends AgentAuditLog`. The audit log as a stream of files over an
`AgentAuditStore`: one new JSON file per appended batch, filed under the UTC day
it was written (`<yyyy-mm-dd>/<µs>-<instance>-<n>.json`), never a rewrite.
Retention deletes whole day folders. The store should be dedicated to the log.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `store` | `final AgentAuditStore store` | Where the files live. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `persist` | `void persist(List<AgentAuditEntry> batch)` | Queues the write of one batch file `{version, entries}`. |
| `flush` | `Future<void> flush()` | Waits for the queued writes and deletions. |
| `pruneStorage` | `void pruneStorage()` | Queues the deletion of every day folder older than the retention cutoff. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `formatVersion` | `static const formatVersion = 2` | The on-disk format of one batch file. |
| `open` | `static Future<AgentFileAuditLog> open(AgentAuditStore store, {Duration retention = AgentAuditLog.defaultRetention, DateTime Function()? clock})` | Opens the log: deletes expired day folders, reads the retained `.json` files of `formatVersion` (skipping files that do not parse or are of another format) and continues numbering after the highest `opId`. |

### AgentAuditExecution

`final class`. What a program run reports to the tool call that started it,
through `agentAuditExecution`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentAuditExecution` | `const AgentAuditExecution({required String programId, required String? programSha256, required AgentAuditOutcome outcome, required int mutationCount, required int logBytes})` | A run report. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `programId` | `final String programId` | The program executed. |
| `programSha256` | `final String? programSha256` | The digest of the source that ran. |
| `outcome` | `final AgentAuditOutcome outcome` | `applied`, `rolledBack` or `failed`. |
| `mutationCount` | `final int mutationCount` | Mutations the run applied. |
| `logBytes` | `final int logBytes` | Size of the run's output. |

### AgentAuditRecording

`final class`. One tool call's audit entries, collected in the call's zone while
it runs and appended to the context's log as one batch when it ends. A call
with no mutations records one entry: `applied`, `denied` (an
`AgentToolException` refusal, with its audit reason and gate), or `failed` (a
failure code or any other error). A program run reported through
`agentAuditExecution` is framed by an entry before and a terminal entry after
its mutations, which are marked rolled back unless the run applied. When the
call declared itself one group (`agentAuditCallIsOneGroup`) and failed, its
mutations are marked rolled back.

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `recordMutation` | `void recordMutation(String op, String? target)` | Records one applied mutation at the next position of the invocation's undo chain. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `current` | `static AgentAuditRecording? get current` | The recording of the tool call running now, or null outside one. |
| `run` | `static FutureOr<Object?> run(String toolName, AgentToolContext context, Map<String, Object?> raw, FutureOr<Object?> Function() call)` | Runs `call` as the audited call of `toolName`, with `context.callZoneValues` installed, and appends its entries however it ends. The target is read from `auditTargetKeys`, the locator from `auditLocatorKey`. |

**Presentations and runs.** Declared in `lib/src/agent_tools/binding.dart`. Nothing here binds a port,
opens a socket or listens on a pipe.

### AgentRunStep

`final class`. One tool call made during a run, as the preview shows it and the
run reports it.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentRunStep` | `const AgentRunStep({required int index, required String toolName, AgentToolException? error, bool notSimulated = false, Map<String, Object?> arguments = const {}, Object? result})` | A step record. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `index` | `final int index` | 1-based, in call order. |
| `toolName` | `final String toolName` | The tool called. |
| `error` | `final AgentToolException? error` | Null when the call completed; the refusal otherwise. |
| `notSimulated` | `final bool notSimulated` | In a dry run: the call needs execution, which a dry run does not perform. |
| `arguments` | `final Map<String, Object?> arguments` | What the call was given. |
| `result` | `final Object? result` | What the call answered, when it completed. |
| `ok` | `bool get ok` | True when there is no error and the step was simulated. |

### AgentToolResult

`final class`. What a dispatched call hands back to the model. Only
`AgentToolBinding` creates one.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `isError` | `final bool isError` | Whether the call was refused or failed. |
| `value` | `final Object? value` | The tool's result, or `{code, message, argument?, step?}` for a refusal. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toText` | `String toText()` | `value` JSON-encoded. |

### AgentToolBinding

`final class AgentToolBinding<C extends AgentToolContext> implements LlmToolBinding`.
The `{invocation, registry}` pair for one request plus the context its calls
run against; a provider holds it for that request only. Declarations are
generated from `registry` on every read. Every call is recorded as a step; once
a call has failed, every later call is refused with `E_TRANSACTION_FAILED`
(and recorded) instead of performed. An exception that is not an
`AgentToolException` is reported to the model as `E_TRANSACTION_FAILED`,
"The call failed.", without its text.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentToolBinding` | `AgentToolBinding({required C context, required AgentToolRegistry<C> registry})` | Binds a context and a registry. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `context` | `final C context` | The context calls run against. |
| `registry` | `final AgentToolRegistry<C> registry` | The tool set presented. |
| `invocation` | `AgentInvocation get invocation` | The context's invocation. |
| `steps` | `List<AgentRunStep> get steps` | Every call made through the binding, in order. |
| `failure` | `AgentRunStep? get failure` | The first refused or failed call, if any. |
| `declarations` | `List<ToolDescriptor> get declarations` | The tool set as `tom_llm` tool descriptors (name, summary, argument JSON schema). |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `call` | `Future<LlmToolAnswer> call(String name, Map<String, Object?> arguments)` | Runs a call on the `agent` entry point and answers `(isError, text)` for the model; a refusal is an error answer, not an exception. |
| `nativeDeclarations` | `List<Map<String, Object?>> nativeDeclarations()` | The tool set in the Anthropic Messages API shape `{name, description, input_schema}`. |
| `dispatch` | `Future<AgentToolResult> dispatch(String name, Map<String, Object?> input)` | `@visibleForTesting`. Runs a call and answers the full result. |

### AgentInProcessMcpServer

`final class`. An MCP server in-process: a JSON-RPC 2.0 message handler a
caller invokes directly. `tools/list` is generated from the binding's registry
and `tools/call` dispatches into the binding, stamping every audit entry with
`entry: mcp`. It answers `initialize`, `ping`, `tools/list` and `tools/call`;
other methods get `-32601`, a malformed request `-32600`, bad `tools/call`
parameters `-32602`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentInProcessMcpServer` | `AgentInProcessMcpServer(AgentToolBinding binding, {required String serverName})` | A server over `binding`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `binding` | `final AgentToolBinding binding` | The binding presented. |
| `serverName` | `final String serverName` | Reported as `serverInfo.name` by `initialize`. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `handle` | `Future<Map<String, Object?>?> handle(Map<String, Object?> message)` | Handles one JSON-RPC message: answers a request, or null for a notification. A `tools/call` answer is `{content: [{type: text, text}], isError}`. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `protocolVersion` | `static const protocolVersion = '2025-06-18'` | The MCP protocol revision `initialize` answers with. |

### AgentRunStatus

`enum`. How an agent run ended.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `accepted` | `accepted` | Every call completed and the user accepted. |
| `rejected` | `rejected` | Every call completed and the user rejected the preview; rolled back. |
| `rolledBack` | `rolledBack` | A call was refused or failed, or the model could not be reached; rolled back. |

### AgentRunOutcome

`final class`. What `AgentRun.execute` reports, and what its `confirm` callback
is shown as the preview.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentRunOutcome` | `const AgentRunOutcome({required AgentRunStatus status, required List<AgentRunStep> steps, String answer = '', Object? error, List<AgentRunStep> dryRun = const []})` | An outcome. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `status` | `final AgentRunStatus status` | How the run ended. |
| `steps` | `final List<AgentRunStep> steps` | The calls made. |
| `answer` | `final String answer` | The model's closing answer, when it gave one. |
| `error` | `final Object? error` | Why a run ended without a failed call. |
| `dryRun` | `final List<AgentRunStep> dryRun` | In a preview, `steps` performed again against copies of the resources as they were before the run; empty otherwise. |
| `failedStep` | `int? get failedStep` | The 1-based index of the call that ended the run. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `dryRunOf` | `AgentRunStep? dryRunOf(int index)` | The dry-run verdict for call `index`, when there is one. |

### AgentRun

`abstract final class`. One agent run: a model-driven sequence of tool calls
kept or discarded as a unit, built on `AgentPreviewThenApply.run` over
`AgentToolContext.runAtomically`.

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `execute` | `static Future<AgentRunOutcome> execute<C extends AgentToolContext>({required AgentToolBinding<C> binding, required AgentAuditLog audit, required Future<String> Function(AgentToolBinding<C> binding) drive, Future<bool> Function(AgentRunOutcome preview)? confirm, String label = 'Agent run'})` | Runs `drive` atomically; a failed call rolls back without asking; otherwise `confirm` (absent: accept) sees a preview with a dry run. The binding's own log is a staging log: its new entries are appended to `audit` at the end, marked rolled back unless accepted. Throws `ArgumentError` when `audit` is the binding's own log. |
| `dryRun` | `static Future<List<AgentRunStep>> dryRun<C extends AgentToolContext>(AgentToolBinding<C> binding, List<({String name, Map<String, Object?> arguments})> steps)` | Performs `steps` in order against a `dryRunCopy` of the binding's context and reports each; a step that needs execution is reported `notSimulated`. |

**Preview then apply.** Declared in `lib/src/agent_tools/preview_then_apply.dart`. Every proposal is
proposed inside one atomic scope, refused or confirmed, and applied in the same
scope; rejecting, refusing and any failure roll the scope back.

### AgentProposalStatus

`enum`. How a proposal ended.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `accepted` | `accepted` | Accepted and applied. |
| `rejected` | `rejected` | The user declined; rolled back, nothing recorded. |
| `failed` | `failed` | Refused, or something threw; rolled back, nothing recorded. |

### AgentProposalOutcome

`final class AgentProposalOutcome<P>`. What `AgentPreviewThenApply.run`
reports.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentProposalOutcome` | `const AgentProposalOutcome({required AgentProposalStatus status, P? proposal, Object? refusal, Object? error})` | An outcome. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `status` | `final AgentProposalStatus status` | How the proposal ended. |
| `proposal` | `final P? proposal` | The proposal, or null when proposing failed. |
| `refusal` | `final Object? refusal` | What `refuse` answered, when the proposal was refused. |
| `error` | `final Object? error` | What was thrown, when something was; never set together with `refusal`. |

### AgentAtomicScope

`typedef AgentAtomicScope = Future<void> Function(String label, Future<void> Function() body)`.
Runs a body as one atomic unit, all of it rolled back together if it throws. An
application supplies one over whatever it writes (an undo group, a database
transaction).

### AgentPreviewThenApply

`abstract final class`. Preview-then-apply as one mechanism for every proposal.

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `run` | `static Future<AgentProposalOutcome<P>> run<P>({required AgentAtomicScope atomically, required String label, required Future<P> Function() propose, required Future<bool> Function(P proposal) confirm, FutureOr<void> Function(P proposal)? apply, Object? Function(P proposal)? refuse})` | Inside `atomically`: proposes; when `refuse` answers non-null the outcome is `failed` without asking; otherwise asks `confirm` and, on acceptance, runs `apply`. A declined proposal is `rejected`; anything thrown is `failed` with `error`. Never throws. |

## Global Functions and Constants

The library exports seven top-level functions and no public top-level
constants or `final` variables.

### agentGuard

`AgentScopeGate? agentGuard(AgentScope scope, AgentGuardTarget target, {required bool write})`

The gate that denies `target` under `scope`, or null when it is allowed. Gates
in order: an `excluded` target; a write under a scope without `allowWrite`; a
kind the scope does not admit; when the scope has an id set, an id not in it
(for a target being created, a parent id not in it).

### agentFilterAudit

`List<AgentAuditEntry> agentFilterAudit(Iterable<AgentAuditEntry> entries, {String? scopeId, String? locator, AgentAuditOutcome? outcome})`

A viewer's three filters over an entry list; a null filter matches everything.

### agentAuditExecutionStarted

`void agentAuditExecutionStarted()`

Marks where a program run's mutations begin in the tool call it runs under. A
no-op outside a call.

### agentAuditResolved

`void agentAuditResolved(String locator)`

Tells the tool call running now which resource it reached, unless a locator is
already known. A no-op outside a call.

### agentAuditExecution

`void agentAuditExecution(AgentAuditExecution run)`

Reports a program run to the tool call it runs under. A no-op outside a call.

### agentAuditCallIsOneGroup

`void agentAuditCallIsOneGroup()`

Tells the tool call running now that its writes are one group: if the call
fails, every write it made is recorded as rolled back. A no-op outside a call.

### agentAuditEntering

`T agentAuditEntering<T>(AgentAuditEntryPoint entry, T Function() body)`

Runs `body` so every entry a tool call records inside it carries `entry`. The
presentation stamps it (`AgentInProcessMcpServer` uses `mcp`); outside any
presentation calls record as `agent`.

| Constant | Type | Description |
| -------- | ---- | ----------- |
| (none) | | The library exports no top-level `final` variables. |

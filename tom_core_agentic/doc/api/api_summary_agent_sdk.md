# Tom Core Agentic API Reference: Agent SDK

The symbol-level mirror of the Agent SDK module, `lib/src/agent_sdk/`, as three
public libraries export it:

- `package:tom_core_agentic/agent_sdk.dart` — the product library: the session
  provider, the sessions, the transports, the transport selector, the stall
  bound, conversation resume and the server installer.
- `package:tom_core_agentic/agent_sdk_testing.dart` — test support: a fake CLI
  server that speaks the wire, the spawnable fixture scripts, the deadlines a
  spawning test bounds itself with, and a Node finder for live suites.
- `package:tom_core_agentic/agent_sdk_live_probe.dart` — the probe a live suite
  runs to learn whether a model answers behind a transport.

[`doc/agent_sdk.md`](../agent_sdk.md) explains how the module behaves and how
its parts fit together. This document is arranged for lookup: one heading per
exported type, function and constant, grouped by the concern it belongs to.

## Table of Contents

- [Overview](#overview)
- [Class Hierarchy](#class-hierarchy)
- [Classes](#classes)
- [Global Functions and Constants](#global-functions-and-constants)
- [Live probe library (agent_sdk_live_probe.dart)](#live-probe-library-agent_sdk_live_probedart)
- [Testing library (agent_sdk_testing.dart)](#testing-library-agent_sdk_testingdart)

## Overview

Sources:

| Source | File declares |
| ------ | ------------- |
| `lib/src/agent_sdk/session_provider.dart` | `AgentSdkWhenBusy`, `AgentSdkRunAttribution`, `AgentSdkSessionProvider` |
| `lib/src/agent_sdk/sessions/session_manager.dart` | `AgentSdkSessionHosting`, `AgentSdkSessionManager` |
| `lib/src/agent_sdk/stall_bound.dart` | `defaultAiStallTimeout`, `boundedAiRun` |
| `lib/src/agent_sdk/transport/transport.dart` | `AgentSdkCompletionRequest`, `AgentSdkAgentLoop`, `AgentSdkToolDeclaration`, `AgentSdkToolSet`, `AgentSdkCompletionEvent`, `AgentSdkTrailed`, `AgentSdkConversation`, `AgentSdkLiveness`, `AgentSdkServerTransport`, `AgentSdkUnavailableKind`, `AgentSdkInstallOutcome`, `AgentSdkInstallableTransport` |
| `lib/src/agent_sdk/transport/cli_server_channel.dart` | `agentRunMaxTurns`, `agentSdkMcpToolName`, `CliServerAiChannel` |
| `lib/src/agent_sdk/transport/hosted_transport.dart` | `AgentSdkWorkspaceCandidate`, `discoverHostedAiWorkspaces`, `HostedServerResolution`, `HostedCliServerAiTransport` |
| `lib/src/agent_sdk/transport/standalone_transport.dart` | `standaloneReadyPrefix`, `standaloneScriptEnvVar`, `agentSdkServerScriptName`, `agentSdkServerPayloadDir`, `requiredNodeMajorVersion`, `StandaloneNodeAiTransport`, `agentSdkNodeProblemFor`, `agentSdkNodeProblem`, `agentSdkNodeMissingReason`, `agentSdkNodeNotRunnableReason`, `agentSdkNodeTooOldReason`, `resolveDefaultServerScript`, `resolveServerScriptFor`, `agentSdkServerScriptCandidates`, `agentSdkServerSourceCandidates`, `resolveAgentSdkServerSourceFor`, `agentSdkChildEnvironment` |
| `lib/src/agent_sdk/transport_selector.dart` | `AgentSdkNotice`, `AgentSdkTransportSelector` |
| `lib/src/agent_sdk/resume.dart` | `AgentSdkResumeStrategy`, `AgentSdkResumeStore`, `AgentSdkStoredResume`, `AgentSdkQuestResume`, `agentSdkLooksLikeResumeError` |
| `lib/src/agent_sdk/server_payload.dart` | `agentSdkInstallExplanationUrl`, `agentSdkServerLockfileName`, `agentSdkServerSourceFiles`, `agentSdkInstallMarkerName`, `agentSdkPlatformFor`, `agentSdkHostPlatform`, `AgentSdkPlatformChoice`, `chooseAgentSdkPlatform`, `agentSdkInLockfile`, `AgentSdkStagingReport`, `AgentSdkStagingException`, `stageAgentSdkServer`, `AgentSdkSourceVerification`, `verifyAgentSdkServerSource`, `AgentSdkPayloadVerification`, `verifyAgentSdkPayloadFor`, `AgentSdkCommandRunner`, `runAgentSdkCommand`, `AgentSdkNodeRuntime`, `AgentSdkServerInstallState`, `AgentSdkServerInstaller`, `AgentSdkServerInstallResult`, `agentSdkInstallOutcomeOf` |
| `lib/src/agent_sdk/live_model_probe.dart` | `agentSdkProbeBound`, `AgentSdkProbeOutcome`, `AgentSdkProbe`, `probeAgentSdkModel` |
| `lib/src/agent_sdk/testing/fake_ai_server.dart` | `readyPrefix`, `FakeAiServerBehaviour`, `FakeAiServer`, `ReservedPort` (its spawned entry point `main` is hidden by the export) |
| `lib/src/agent_sdk/testing/fixture_scripts.dart` | `agentSdkFixtureScript` |
| `lib/src/agent_sdk/testing/node_runtime.dart` | `agentSdkNodeEnvVar`, `findNodeForTests` |
| `lib/src/agent_sdk/testing/spawn_timings.dart` | `spawnStartupTimeout`, `spawnTestTimeout`, `spawnDeadlinesAreOrdered` |

`agent_sdk.dart` exports the first ten files, `agent_sdk_live_probe.dart` the
probe, and `agent_sdk_testing.dart` the four testing files.
`sessions/session_worker.dart`, `transport/sdk_trail_translator.dart` and
`testing/echo_ai_server.dart` are internal: they are used by the exported files
but not exported themselves.

The flow, in one paragraph: an `AgentSdkSessionProvider` (a `tom_llm`
`LlmProvider`) receives an `LlmRequest`, picks the active transport from its
`AgentSdkTransportSelector`, builds an `AgentSdkCompletionRequest` and hands it
to its `AgentSdkSessionManager`, which runs it in the request's session — in an
isolate of its own — under `boundedAiRun`. The transport is either
`HostedCliServerAiTransport` (the CLI server of a running VS Code) or
`StandaloneNodeAiTransport` (a Node child the app starts); both talk the
CLI-server wire through a `CliServerAiChannel`.

## Class Hierarchy

```text
LlmProvider (tom_llm)
└── AgentSdkSessionProvider

AgentSdkServerTransport (abstract)
├── HostedCliServerAiTransport
└── AgentSdkInstallableTransport (abstract interface)
    └── StandaloneNodeAiTransport

AgentSdkCompletionEvent (sealed)
├── AgentSdkTrailed
├── AgentSdkConversation
└── AgentSdkLiveness

AgentSdkResumeStrategy (abstract interface)
├── AgentSdkStoredResume
└── AgentSdkQuestResume

Exception
└── AgentSdkStagingException

Standalone classes: AgentSdkSessionManager, CliServerAiChannel,
AgentSdkTransportSelector, AgentSdkNotice, AgentSdkCompletionRequest,
AgentSdkAgentLoop, AgentSdkToolSet, AgentSdkInstallOutcome,
AgentSdkWorkspaceCandidate, HostedServerResolution, AgentSdkResumeStore,
AgentSdkPlatformChoice, AgentSdkStagingReport, AgentSdkSourceVerification,
AgentSdkPayloadVerification, AgentSdkNodeRuntime, AgentSdkServerInstaller,
AgentSdkServerInstallResult, AgentSdkProbe, FakeAiServer, ReservedPort.

Enums: AgentSdkWhenBusy, AgentSdkRunAttribution, AgentSdkSessionHosting,
AgentSdkUnavailableKind, AgentSdkServerInstallState, AgentSdkProbeOutcome,
FakeAiServerBehaviour.

Typedefs: AgentSdkToolDeclaration (record), AgentSdkCommandRunner (function).
```

## Classes

**The provider**

### AgentSdkSessionProvider

`final class`, extends `LlmProvider`. Anthropic, reached through whichever
transport the selector chose. It holds no HTTP client, no credential and no
document: everything host-specific is below the `AgentSdkServerTransport` seam.
Every run is served from a session of `sessions` (the request's
`LlmOptions.sessionId`, else the session `llmSessionFor` names for the request's
purpose), under the stall bound `stallGap`. The far end receives the request's
`WirePrompt.combined` unchanged, and the run's report carries the prompt's
anchor hash, its body hash and its template. Configured by default for an app's
AI actions (plain completions, the app's own tools, a busy session refused, the
gate checked by the caller); a backend that is itself an agent sets
`agentLoop`, `resume`, `whenBusy`, `connectOnDemand` and `attribution`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkSessionProvider` | `const AgentSdkSessionProvider({required AgentSdkTransportSelector selector, required AgentSdkSessionManager sessions, required String toolServerName, String id = 'anthropic', String? systemPrompt, String? model, bool Function()? agentToolsEnabled, Duration stallGap = defaultAiStallTimeout, AgentSdkAgentLoop? agentLoop, AgentSdkResumeStrategy? resume, AgentSdkWhenBusy whenBusy = AgentSdkWhenBusy.refuse, bool connectOnDemand = false, AgentSdkRunAttribution attribution = AgentSdkRunAttribution.transport})` | Builds the provider. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `selector` | `final AgentSdkTransportSelector selector` | Owns the availability verdict and the active transport. |
| `sessions` | `final AgentSdkSessionManager sessions` | The sessions every run is served from, each in its own isolate. |
| `toolServerName` | `final String toolServerName` | The in-process MCP server a request's tools are declared on; the model sees each tool as `mcp__<toolServerName>__<tool>`. |
| `id` | `final String id` | The provider id, `anthropic` by default. |
| `systemPrompt` | `final String? systemPrompt` | A system prompt sent with every completion in place of the far end's own; configuration, never document-derived. |
| `model` | `final String? model` | The model used when a request names none; null means the transport's default. |
| `agentToolsEnabled` | `final bool Function()? agentToolsEnabled` | The agent-tools switch, read live; null counts as on. Off, the provider reports no tool use and refuses a request carrying a tool binding. |
| `stallGap` | `final Duration stallGap` | The longest silence a completion may contain before it is abandoned as `LlmErrorKind.timeout` (see `boundedAiRun`). |
| `agentLoop` | `final AgentSdkAgentLoop? agentLoop` | Claude Code's own agent loop for every request, or null. With a loop, Claude Code's tool calls go to the trails and are left out of the run's stream. |
| `resume` | `final AgentSdkResumeStrategy? resume` | Which conversation a request continues, or null for a fresh one every time. |
| `whenBusy` | `final AgentSdkWhenBusy whenBusy` | What a run does when its session already has one. |
| `attribution` | `final AgentSdkRunAttribution attribution` | Whom a run names as the provider that answered it. |
| `connectOnDemand` | `final bool connectOnDemand` | Whether a run with no active transport first calls `selector.retry()`; when nothing answers, the run ends as failed with the selector's reason. |
| `trails` | `LlmTrails get trails` | The sessions' consolidated trails (`sessions.trails`). |
| `isAvailable` | `bool get isAvailable` | The availability gate, delegated to the selector. |
| `unavailableReason` | `String? get unavailableReason` | The selector's retained explanation of a shut gate. |
| `capabilities` | `LlmCapabilities get capabilities` | The active transport's capabilities, or `LlmCapabilities.none`; `canUseTools` is also false while `agentToolsEnabled` answers false. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `run` | `Stream<LlmEvent> run(LlmRequest request)` | Runs the request in its session and streams its events; cancelling the stream cancels the run. Throws `UnsupportedError` for a tool binding the provider cannot use, and — without `connectOnDemand` and `resume` — when no transport is active. With `resume`, a resumed conversation the far end rejects before any text arrived (`agentSdkLooksLikeResumeError`) is evicted and retried once, fresh, announced by an `LlmRetry`. A completed run's conversation id is recorded before its end is delivered. An `unreachable` failure calls `selector.markLost`. |
| `embed` | `Future<List<double>> embed(String text)` | Always throws `UnsupportedError`: Anthropic exposes no embeddings API. |

### AgentSdkWhenBusy

`enum`. What a run does when its session already has one.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `refuse` | `refuse` | Refuses with `LlmSessionBusyException`. |
| `queue` | `queue` | Waits for the session to be free, then runs. |

### AgentSdkRunAttribution

`enum`. Whom a run names as the provider that answered it, in its
`LlmRunStarted` and its report.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `transport` | `transport` | The transport that served it (its `id`). |
| `provider` | `provider` | The provider's own `AgentSdkSessionProvider.id`. |

**The sessions**

### AgentSdkSessionManager

`final class`. The AI sessions of an app, run from the main isolate. Each
session runs in its own isolate (or in process, per `hosting`), spawned by its
first run and kept, holding the transport connection, the request loop and the
liveness bound. The manager consolidates every session's events into `trails`,
answers each tool call in the main isolate through the request's tools, refuses
or queues a run in a busy session, cancels a run (stopping a host that does not
stop within `cancelGrace`), and records a session's death in its trail without
letting it reach any other. Sessions run in the zone the manager was built in.
Run starts and ends are logged through `diagnostics`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkSessionManager` | `AgentSdkSessionManager({AgentSdkSessionHosting hosting = AgentSdkSessionHosting.isolate, LlmTrails? trails, TomDiagnostics diagnostics = const TomNullDiagnostics(), Duration cancelGrace = const Duration(seconds: 2), Duration? idleClose})` | Builds the manager; a new `LlmTrails` when none is given. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `hosting` | `final AgentSdkSessionHosting hosting` | Where sessions run. |
| `trails` | `final LlmTrails trails` | The consolidated trails. |
| `diagnostics` | `final TomDiagnostics diagnostics` | Where a run's lifecycle and an unmapped far-end message type are logged, never with any of its text. |
| `cancelGrace` | `final Duration cancelGrace` | How long a cancelled run may take to stop before its session host is stopped. |
| `idleClose` | `final Duration? idleClose` | How long a session may sit without a run before its host is stopped, or null to keep it until `dispose`. A stopped session starts again on its next run. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `isBusy` | `bool isBusy(String sessionId)` | Whether the session has a run in progress. `@visibleForTesting`. |
| `run` | `Stream<LlmEvent> run({required String sessionId, required AgentSdkServerTransport transport, required AgentSdkCompletionRequest request, required List<LlmEvent> prelude, required Duration stallGap, void Function(LlmTransportException failure)? onFailure, void Function(String conversationId)? onConversation, bool queueWhenBusy = false})` | Runs the request in the session over the transport. One run per session: a busy session throws `LlmSessionBusyException`, or with `queueWhenBusy` waits for it to be free. The stream carries `prelude`, then the session's events, ends with one `LlmRunEnded` and does not error; cancelling it cancels the run. A transport other than the session's current one restarts the session's host. Throws `StateError` after `dispose`. |
| `debugKill` | `void debugKill(String sessionId)` | Kills the session's isolate as a death would. `@visibleForTesting`. |
| `dispose` | `Future<void> dispose()` | Stops every session and closes `trails`. |

### AgentSdkSessionHosting

`enum`. Where a session runs.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `isolate` | `isolate` | In an isolate of its own, started from the transport's `sessionCopy`. |
| `inProcess` | `inProcess` | In the main isolate, through the same worker and messages — for a suite whose stand-in transport holds state the test reads. |

**The transport seam**

### AgentSdkServerTransport

`abstract class`. The seam the provider is written against; the hosted and
standalone paths implement it. It names nothing about VS Code, Node, sockets or
processes. Cancelling the subscription to `complete`'s stream aborts the remote
completion. The transport holds no stall bound: the provider applies one over
whatever stream any transport returns, so a transport whose far end is alive
but silent must report `AgentSdkLiveness`.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `id` | `String get id` | A stable identifier for diagnostics and settings; not a display string. |
| `capabilities` | `LlmCapabilities get capabilities` | What the far end can do; static per transport. |
| `isConnected` | `bool get isConnected` | Whether a live connection is held. |
| `unavailableReason` | `String? get unavailableReason` | Why the last `probe` answered false, phrased as a remedy; null when never probed or the probe succeeded. Defaults to null. |
| `selectionNotice` | `String? get selectionNotice` | A sentence to tell the user once about a working transport, or null. Defaults to null. |
| `sessionCopy` | `AgentSdkServerTransport Function()? get sessionCopy` | A function that builds, in another isolate, an unconnected transport reaching the same far end; it captures only sendable values. Null for a transport that can only run where it was made, or one that has not found its far end yet. Defaults to null. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `probe` | `Future<bool> probe()` | Tests reachability without side effects and without throwing. |
| `connect` | `Future<void> connect()` | Establishes the connection; throws `LlmTransportException` with `LlmErrorKind.unreachable` when no server can be reached. |
| `complete` | `Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request)` | Streams a completion: an `AgentSdkTrailed` per trail event in order, `AgentSdkLiveness` whenever the far end is alive and silent. Closes on completion; a failure is an `LlmTransportException` error. |
| `close` | `Future<void> close()` | Releases the connection and everything the transport owns (for the standalone path, the child process). |

### AgentSdkInstallableTransport

`abstract interface class`, implements `AgentSdkServerTransport`. A transport
that can say which kind of unavailable it is and install what it is missing
when the user asks. The selector checks for it with `is`.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `unavailableKind` | `AgentSdkUnavailableKind? get unavailableKind` | The kind of the last false `probe`, or null. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `install` | `Future<AgentSdkInstallOutcome> install({void Function(String line)? onProgress})` | Installs the server's dependencies. Never throws; called only on the user's request. |

### AgentSdkCompletionRequest

`final class`. One completion request at the transport layer. Its `prompt` is
text already assembled by the caller; the class can hold no application model
object.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkCompletionRequest` | `const AgentSdkCompletionRequest({required String prompt, String? systemPrompt, String? model, AgentSdkToolSet? tools, String? resume, AgentSdkAgentLoop? agentLoop})` | Builds a request. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `prompt` | `final String prompt` | The body as sent: the request's `WirePrompt.combined`, unchanged. |
| `systemPrompt` | `final String? systemPrompt` | An optional system prompt; null keeps the far end's own. |
| `model` | `final String? model` | An optional model; null means the far end's default. |
| `tools` | `final AgentSdkToolSet? tools` | The tools the model may call during this request, or null for a plain completion. |
| `resume` | `final String? resume` | The far end's conversation to continue (the SDK's `resume`), or null. |
| `agentLoop` | `final AgentSdkAgentLoop? agentLoop` | Claude Code's own agent loop, or null. Null turns the SDK's own tools off and allows one turn (or `agentRunMaxTurns` with `tools`). |

### AgentSdkAgentLoop

`final class`. Claude Code running its own agent loop for a request: its tools,
its MCP servers and its turns, under a permission mode.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkAgentLoop` | `const AgentSdkAgentLoop({int? maxTurns, String permissionMode = 'default'})` | Builds a loop configuration. |
| `fromMap` | `factory AgentSdkAgentLoop.fromMap(Map<String, Object?> map)` | Reads one back from `toMap`'s shape; a missing `permissionMode` is `default`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `maxTurns` | `final int? maxTurns` | The most turns Claude Code may take, or null for the SDK's default. |
| `permissionMode` | `final String permissionMode` | The SDK's permission mode as its wire string (`default`, `acceptEdits`, `bypassPermissions`, `plan`, `dontAsk`, `auto`). |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toMap` | `Map<String, Object?> toMap()` | `{maxTurns, permissionMode}`, the form sent to a session isolate. |

### AgentSdkToolDeclaration

`typedef AgentSdkToolDeclaration = ({String name, String description, Map<String, Object?> inputSchema})`.
One tool as the model is told about it: the registry entry's name, summary and
JSON-Schema arguments.

### AgentSdkToolSet

`final class`. The tools a request offers, reduced to what a transport needs to
relay a call: declarations and a function that answers a call with text.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkToolSet` | `const AgentSdkToolSet({required String serverName, required List<AgentSdkToolDeclaration> declarations, required Future<LlmToolAnswer> Function(String name, Map<String, Object?> arguments) call})` | Builds a tool set. |
| `fromBinding` | `factory AgentSdkToolSet.fromBinding(LlmToolBinding binding, {required String serverName})` | The tool set of an `LlmToolBinding`: its declarations, each call dispatched back into the binding. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `serverName` | `final String serverName` | The in-process MCP server the tools are declared on (see `agentSdkMcpToolName`). |
| `declarations` | `final List<AgentSdkToolDeclaration> declarations` | Every tool the model may call. |
| `call` | `final Future<LlmToolAnswer> Function(String name, Map<String, Object?> arguments) call` | Runs a call and answers the model; a refusal is an answer with `isError: true`, never a throw. |

### AgentSdkCompletionEvent

`sealed class`. One thing a running completion says: an event of its trail,
the conversation it belongs to, or the fact that it is still alive. Every kind
resets the provider's stall bound.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkCompletionEvent` | `const AgentSdkCompletionEvent()` | For the subclasses. |

### AgentSdkTrailed

`final class`, extends `AgentSdkCompletionEvent`. Something the run did, for its
trail: the far end's start, thinking, text, a tool call or its result, a retry,
the usage, the end.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkTrailed` | `const AgentSdkTrailed(LlmEvent event)` | Wraps a trail event. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `event` | `final LlmEvent event` | The trail event. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkTrailed(<event kind>)`. |

### AgentSdkConversation

`final class`, extends `AgentSdkCompletionEvent`. The far end named the
conversation the run belongs to — the id a later request passes as
`AgentSdkCompletionRequest.resume`. Not a trail event.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkConversation` | `const AgentSdkConversation(String id)` | Wraps a conversation id. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `id` | `final String id` | The conversation id. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkConversation(<id>)`. |

### AgentSdkLiveness

`final class`, extends `AgentSdkCompletionEvent`. The far end showed it is alive
and said nothing the trail records: a partial message's bookkeeping, a progress
event, a tool call being run. Counted by the stall bound and otherwise dropped.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkLiveness` | `const AgentSdkLiveness(String source, {String? unmappedType})` | Builds a liveness event. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `source` | `final String source` | What the far end did (`stream_event`, `tool call …`). |
| `unmappedType` | `final String? unmappedType` | The type of a message the translator does not map, or null; `boundedAiRun` reports each such type once per run. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkLiveness(<source>)`. |

### AgentSdkUnavailableKind

`enum`. Why the availability gate is shut, as a kind a program can branch on.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `notConfigured` | `notConfigured` | The build wired no transport at all. |
| `unreachable` | `unreachable` | A backend was expected and did not answer. |
| `noRuntime` | `noRuntime` | No usable Node.js: none was found, or the one found is below `requiredNodeMajorVersion`. |
| `notInstalled` | `notInstalled` | Node is fine, but the server's dependencies are not installed in the app's data folder, or were installed for an earlier version of the server; the app installs them when the user asks. |

### AgentSdkInstallOutcome

`final class`. What an on-demand install of a transport's server ended with.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `succeeded` | `const AgentSdkInstallOutcome.succeeded()` | A successful install. |
| `failed` | `const AgentSdkInstallOutcome.failed(String failure)` | A failed install, with the sentence for the user. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `ok` | `final bool ok` | Whether the server is installed and passed its post-install check. |
| `failure` | `final String? failure` | Why not; null when `ok`. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkInstallOutcome(ok)` or `AgentSdkInstallOutcome(failed: …)`. |

**The CLI-server channel**

### CliServerAiChannel

`final class`. A connected CLI-server endpoint, reduced to the one operation the
AI adapter needs; both transports hold one. The wire is the CLI server's
JSON-RPC 2.0 in length-prefixed frames over loopback TCP (`agentSdk.queryVce`,
`agentSdk.cancelVce`, `agentSdk.chunk`, and the server-to-client
`agentSdk.toolCall`), delegated to `tom_vscode_scripting_api`. The channel
translates Agent SDK messages into `AgentSdkCompletionEvent`s and holds no
stall bound. A `system/api_retry` carrying a 401 (or an assistant message whose
`error` is `authentication_failed`) ends the completion at once as a rejected
credential.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `CliServerAiChannel` | `CliServerAiChannel({required String transportId, required VSCodeBridgeClient client})` | Wraps a JSON-RPC client. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `transportId` | `final String transportId` | The transport id reported in errors raised from the channel. |
| `client` | `final VSCodeBridgeClient client` | The JSON-RPC client, owned by the channel. |
| `isConnected` | `bool get isConnected` | Whether the socket is connected. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `connect` | `Future<void> connect()` | Connects the socket; a failed connect throws `LlmTransportException` (`unreachable`). |
| `complete` | `Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request)` | Runs one completion. Without an agent loop the SDK's own tools are off, only the request's tools are allowed (on an in-process MCP server, `strictMcpConfig`), and `maxTurns` is 1, or `agentRunMaxTurns` with tools; with an agent loop its `maxTurns` and `permissionMode` apply. Both set `includePartialMessages` and adaptive summarized thinking. Emits `AgentSdkConversation` when the far end names a session id, and a failed result as an `LlmTransportException` (`remote`). Cancelling the subscription cancels the remote query. |
| `close` | `Future<void> close()` | Disconnects, waiting at most `closeBound`. Idempotent. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `debugMessageTap` | `static void Function(String transportId, Map<String, dynamic> raw)? debugMessageTap` | Sees every raw Agent SDK message every channel receives, before translation; null except in a recording run. `@visibleForTesting`. |
| `closeBound` | `static const closeBound = Duration(seconds: 2)` | How long `close` waits for the socket to finish closing. `@visibleForTesting`. |

**The hosted transport**

### HostedCliServerAiTransport

`final class`, implements `AgentSdkServerTransport`. Reaches Anthropic through
the CLI server of a running VS Code. Discovery scans the loopback ports
`minPort`–`maxPort` with `tom_vscode_scripting_api`'s scan; with a
`workspaceName` pin it takes the lowest port whose window reports that
workspace, without one the lowest responding server. It never starts anything:
with no server answering, `probe` is false. The host must be a loopback address.
Its id is `vscode-cli-server`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `HostedCliServerAiTransport` | `HostedCliServerAiTransport({String host = '127.0.0.1', String? workspaceName, int minPort = defaultVSCodeBridgePort, int maxPort = maxVSCodeBridgePort, CliServerAiChannel Function(String host, int port)? channelFactory, Future<HostedServerResolution> Function(String host, int minPort, int maxPort, String? workspaceName)? resolve})` | Builds the transport; `channelFactory` and `resolve` are seams for tests. Throws `ArgumentError` for a host other than `127.0.0.1`, `::1` or `localhost`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `host` | `final String host` | The loopback host the CLI server is expected on. |
| `workspaceName` | `final String? workspaceName` | The workspace whose window to use, or null for the lowest-numbered responding server. |
| `minPort` | `final int minPort` | The lowest port scanned, inclusive. |
| `maxPort` | `final int maxPort` | The highest port scanned, inclusive. |
| `id` | `String get id` | `vscode-cli-server`. |
| `capabilities` | `LlmCapabilities get capabilities` | Completes and uses tools, does not embed, 180000 context tokens. |
| `isConnected` | `bool get isConnected` | Whether the channel is connected. |
| `unavailableReason` | `String? get unavailableReason` | Why the last `probe` answered false — the same remedy text `connect` raises. |
| `selectionNotice` | `String? get selectionNotice` | When a pin matched more than one window: which port was taken, and why windows on one workspace cannot be told apart. Recomputed on every resolution. |
| `sessionCopy` | `AgentSdkServerTransport Function()? get sessionCopy` | A transport pinned to the port the last `connect` reached; null before any connect. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `probe` | `Future<bool> probe()` | Scans; true when a server was resolved. Never throws. |
| `connect` | `Future<void> connect()` | Scans and connects a channel to the resolved port; throws `LlmTransportException` (`unreachable`) when none answers. |
| `complete` | `Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request)` | The channel's stream, returned directly; an `unreachable` error stream when not connected. |
| `close` | `Future<void> close()` | Closes the channel. |

### AgentSdkWorkspaceCandidate

`final class`. One VS Code CLI server that answered a discovery scan: its
workspace identity and the port it answered on (for this scan only).

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkWorkspaceCandidate` | `const AgentSdkWorkspaceCandidate({required String identity, required int port})` | Builds a candidate. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `identity` | `final String identity` | What the window reports as its workspace identity — the `.code-workspace` basename, else the workspace or root folder name. Not unique. |
| `port` | `final int port` | The loopback port it answered on. |
| `hashCode` | `int get hashCode` | Hash of identity and port. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `==` | `bool operator ==(Object other)` | Equal when identity and port are equal. |
| `toString` | `String toString()` | `AgentSdkWorkspaceCandidate(<identity> on <port>)`. |

### HostedServerResolution

`final class`. What one discovery scan concluded for a transport's
configuration.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `HostedServerResolution` | `const HostedServerResolution(int? port, {List<int> pinMatches = const []})` | Builds a resolution. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `port` | `final int? port` | The port to connect to, or null when nothing matched. |
| `pinMatches` | `final List<int> pinMatches` | Every port whose server answered to the configured pin, ascending; empty when no pin is set. |

**The standalone transport**

### StandaloneNodeAiTransport

`final class`, implements `AgentSdkInstallableTransport`. Reaches Anthropic
through a Node server the app starts and owns: `connect` spawns
`node <serverScript>` (no shell), waits for the `standaloneReadyPrefix` line
announcing its loopback port, and connects a `CliServerAiChannel`; `close`
closes the child's stdin and terminates it. The Node comes from an
`LlmNodeResolver`, resolved on the first probe and kept once it found one. The
child's environment is built by `agentSdkChildEnvironment`. With an
`installer`, a missing or outdated install makes the transport
`AgentSdkUnavailableKind.notInstalled`. Its id is `standalone-node`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `StandaloneNodeAiTransport` | `StandaloneNodeAiTransport({required LlmNodeResolver node, String? serverScript, AgentSdkServerInstaller? installer, String? apiKey, Set<String> scrubbedVariables = const {}, String? credentialIsolationRoot, Duration startupTimeout = const Duration(seconds: 20), void Function(String line)? onStderr, CliServerAiChannel Function(int port)? channelFactory})` | Builds the transport. `serverScript` defaults to the installer's script, else `resolveDefaultServerScript()`. Throws `ArgumentError` for an empty `apiKey`. |
| `forApp` | `factory StandaloneNodeAiTransport.forApp({required String appDataDirectory, required LlmNodeResolver node, String? apiKey, Set<String> scrubbedVariables = const {}, void Function(String line)? onStderr})` | The transport a packaged app uses: an installer from the source found by `resolveAgentSdkServerSourceFor` into `AgentSdkServerInstaller.installDirFor(appDataDirectory)`. When `standaloneScriptEnvVar` is set, runs that script with no installer. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `node` | `LlmNodeResolution? get node` | The Node resolution the transport runs on, once a probe made it. |
| `nodeExecutable` | `String? get nodeExecutable` | The executable the resolution named, or null. |
| `serverScript` | `final String serverScript` | The server script to run. |
| `installer` | `final AgentSdkServerInstaller? installer` | Installs the server's dependencies on the user's request, or null for a server installed elsewhere. |
| `apiKey` | `final String? apiKey` | The Anthropic credential, handed to the child in its environment. Given, it is the only credential the child can use; null lets the child use the environment's own. |
| `scrubbedVariables` | `final Set<String> scrubbedVariables` | Environment variables of the app's own the child must not inherit. |
| `startupTimeout` | `final Duration startupTimeout` | How long to wait for the child's ready line. `@visibleForTesting`. |
| `onStderr` | `final void Function(String line)? onStderr` | Receives the child's stderr lines and non-ready stdout lines. `@visibleForTesting`. |
| `id` | `String get id` | `standalone-node`. |
| `capabilities` | `LlmCapabilities get capabilities` | The same as the hosted transport's. |
| `isConnected` | `bool get isConnected` | Whether the channel is connected. |
| `unavailableReason` | `String? get unavailableReason` | Why the last probe answered false, naming the remedy. |
| `unavailableKind` | `AgentSdkUnavailableKind? get unavailableKind` | `noRuntime`, `notInstalled` or `unreachable` after a false probe; null otherwise. |
| `selectionNotice` | `String? get selectionNotice` | Always null. |
| `sessionCopy` | `AgentSdkServerTransport Function()? get sessionCopy` | A transport that starts its own server on the resolved Node and script (without installer or stderr listener); null before a Node was resolved. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `install` | `Future<AgentSdkInstallOutcome> install({void Function(String line)? onProgress})` | Runs the installer on the resolved Node; fails with a sentence when there is no installer. |
| `probe` | `Future<bool> probe()` | Checks the preconditions without starting anything: the install (when there is an installer), the script's existence and the Node (`agentSdkNodeProblemFor`). |
| `connect` | `Future<void> connect()` | Checks the same preconditions, creates a fresh empty configuration directory when `apiKey` is set, spawns the child and connects to the announced port. Throws `LlmTransportException`: `unreachable` for a precondition, a spawn failure or an early exit (naming the child's last stderr lines), `timeout` past `startupTimeout`, `protocol` for an unreadable ready line. |
| `complete` | `Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request)` | The channel's stream, returned directly; an `unreachable` error stream when not connected. |
| `close` | `Future<void> close()` | Closes the channel, closes the child's stdin, sends a kill and a SIGKILL after 5 s, and removes the configuration directory. Idempotent. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `stderrDrainBound` | `static const stderrDrainBound = Duration(seconds: 2)` | How long an early-exit report waits for the child's stderr to close. `@visibleForTesting`. |
| `credentialIsolationRootFor` | `static String credentialIsolationRootFor(String appDataDirectory)` | `<appDataDirectory>/ai/isolated-config`, where an app keeps the configuration directories of children started with an explicit key. `@visibleForTesting`. |

**The transport selector**

### AgentSdkTransportSelector

`final class`. Picks the transport to use and owns the availability verdict.
Candidates are tried in order (hosted first, standalone as the fallback). The
gate is a field read; all work happens in `initialize`, `retry` and `install`.
Notices are emitted once per unavailability episode and on explicit retries,
never on a read of the gate.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkTransportSelector` | `AgentSdkTransportSelector(List<AgentSdkServerTransport> candidates)` | Builds a selector over the candidates, in preference order. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `candidates` | `List<AgentSdkServerTransport> get candidates` | The candidates, in preference order. |
| `active` | `AgentSdkServerTransport? get active` | The selected transport, or null. |
| `isAvailable` | `bool get isAvailable` | The availability gate: whether a transport is selected. |
| `unavailableReason` | `String? get unavailableReason` | Why the gate is shut, retained for as long as it is, or null. |
| `unavailableKind` | `AgentSdkUnavailableKind? get unavailableKind` | The kind of unavailable: `notInstalled` when any candidate is missing only its install, else `noRuntime`, else `unreachable`; `notConfigured` with no candidates. |
| `needsInstall` | `bool get needsInstall` | Whether a candidate is waiting for the user to install its server. |
| `isInstalling` | `bool get isInstalling` | Whether an `install` is running. |
| `notices` | `Stream<AgentSdkNotice> get notices` | Broadcast notices: once per unavailability episode, on each failed explicit retry, and a working transport's `selectionNotice` once. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `initialize` | `Future<void> initialize()` | Probes the candidates in order and selects the first that probes and connects (the proving connection is closed again; sessions hold their own). Never throws. With no candidates the gate is shut with `llmNotConfiguredReason` and no notice. |
| `retry` | `Future<bool> retry()` | An explicit retry: resets the once-per-episode flags, runs `initialize`, answers `isAvailable`. |
| `install` | `Future<AgentSdkInstallOutcome> install({void Function(String line)? onProgress})` | Installs the candidate waiting for an install, then retries. Never throws; fails when nothing waits or an install is already running. |
| `markLost` | `void markLost(LlmTransportException error)` | Closes the gate after the active transport was lost mid-use and emits one notice. |
| `replaceCandidates` | `Future<void> replaceCandidates(List<AgentSdkServerTransport> candidates)` | Replaces the candidates and closes the old ones; the gate stays shut until the next `initialize` or `retry`. |
| `dispose` | `Future<void> dispose()` | Closes every candidate and the notice stream. |

### AgentSdkNotice

`final class`. One sentence about AI the shell shows once: an unavailability
explanation or a working transport's selection notice. Credential-free and
content-free.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkNotice` | `const AgentSdkNotice(String message)` | Wraps a message. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `message` | `final String message` | The user-facing sentence. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkNotice: <message>`. |

**Conversation resume**

### AgentSdkResumeStrategy

`abstract interface class`. Decides per call whether the provider resumes a
stored conversation or starts fresh, and records the conversation id a
successful call produced. No method may throw because the stored state is
damaged.

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resumeIdFor` | `Future<String?> resumeIdFor(LlmOptions options)` | The conversation id to resume, or null to start fresh. |
| `record` | `Future<void> record(LlmOptions options, String conversationId)` | Records the id a successful call produced. |
| `evict` | `Future<void> evict(LlmOptions options)` | Forgets the stored id after a resume-shaped failure, so the retry starts fresh. |

### AgentSdkResumeStore

`final class`. A JSON-backed `session id → conversation id` map at `file`,
loaded lazily and cached; every mutation flushes the whole map. A missing,
corrupt or unreadable file reads as empty, and a flush that cannot land is
dropped; no operation throws for a damaged store.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkResumeStore` | `AgentSdkResumeStore(File file)` | A store backed by the file. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The on-disk JSON file. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `lookup` | `Future<String?> lookup(String sessionKey)` | The conversation id stored for the key, or null. |
| `put` | `Future<void> put(String sessionKey, String conversationId)` | Stores the id under the key and flushes. |
| `remove` | `Future<void> remove(String sessionKey)` | Removes the key's id and flushes when one was stored. |

### AgentSdkStoredResume

`final class`, implements `AgentSdkResumeStrategy`. Keeps the conversation id in
an `AgentSdkResumeStore` keyed by `LlmOptions.sessionId`. A call with a null
session id always starts fresh and is never recorded.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkStoredResume` | `const AgentSdkStoredResume(AgentSdkResumeStore store)` | A strategy over the store. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `store` | `final AgentSdkResumeStore store` | The store the ids are persisted in. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resumeIdFor` | `Future<String?> resumeIdFor(LlmOptions options)` | The stored id for the call's session id. |
| `record` | `Future<void> record(LlmOptions options, String conversationId)` | Stores the id under the call's session id. |
| `evict` | `Future<void> evict(LlmOptions options)` | Removes the call's session id from the store. |

### AgentSdkQuestResume

`final class`, implements `AgentSdkResumeStrategy`. Resumes the conversation
recorded in a VS Code window's quest history, read-only: the `sessionId` field
of `{questHistoryRoot}/{questId}/history/{sessionKey}.session.json`, re-read on
every call. A missing or unreadable file means a fresh session. `evict`
remembers the last answered id as rejected for the life of the strategy, and
`resumeIdFor` answers null for a rejected id.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkQuestResume` | `AgentSdkQuestResume({required String questHistoryRoot, required String questId, required String sessionKey})` | A strategy reading one quest session file. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `questHistoryRoot` | `final String questHistoryRoot` | Root folder holding the per-quest history subfolders. |
| `questId` | `final String questId` | The quest whose history is read. |
| `sessionKey` | `final String sessionKey` | Which session file to read (e.g. `default`, `chat`). |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resumeIdFor` | `Future<String?> resumeIdFor(LlmOptions options)` | The file's non-empty `sessionId` unless rejected, else null. |
| `record` | `Future<void> record(LlmOptions options, String conversationId)` | A no-op: the quest history is never written. |
| `evict` | `Future<void> evict(LlmOptions options)` | Remembers the id last answered as rejected; the file is left alone. |

**The server payload and its installer**

### AgentSdkPlatformChoice

`final class`. Which Claude Code CLI an install will get, or why it can get
none; produced by `chooseAgentSdkPlatform`.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `platform` | `final String? platform` | The SDK platform suffix npm will install (`darwin-arm64`, …), or null when refused. |
| `refusal` | `final String? refusal` | Why no CLI can be installed for this Node, naming the remedy; null when `platform` is set. |
| `ok` | `bool get ok` | Whether a CLI was chosen. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkPlatformChoice(<platform>)` or `AgentSdkPlatformChoice(refused: …)`. |

### AgentSdkStagingReport

`final class`. What `stageAgentSdkServer` did, for a build log.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkStagingReport` | `const AgentSdkStagingReport({required String destination, required List<String> files, required int byteCount})` | Builds a report. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `destination` | `final String destination` | Where the source files were written. |
| `files` | `final List<String> files` | The files written, by name. |
| `byteCount` | `final int byteCount` | Bytes written. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | Destination, files and size in KiB. |

### AgentSdkStagingException

`final class`, implements `Exception`. Thrown when a build cannot stage the
server's source; a build failure, never a runtime one.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkStagingException` | `const AgentSdkStagingException(String message)` | Builds the exception. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `message` | `final String message` | What is wrong. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkStagingException: <message>`. |

### AgentSdkSourceVerification

`final class`. What `verifyAgentSdkServerSource` found: everything wrong with
the server source a build carries. Empty `problems` means shippable.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkSourceVerification` | `const AgentSdkSourceVerification({required String sourceDir, required List<String> problems})` | Builds a result. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `sourceDir` | `final String sourceDir` | The directory checked. |
| `problems` | `final List<String> problems` | Everything wrong, in the order checked. |
| `ok` | `bool get ok` | Whether `problems` is empty. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | A one-line ok summary, or the problems as a bulleted list. |

### AgentSdkPayloadVerification

`final class`. What `verifyAgentSdkPayloadFor` found about an installed server.
Empty `problems` means runnable.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkPayloadVerification` | `const AgentSdkPayloadVerification({required String payloadDir, required List<String> problems, required List<String> cliPlatforms, required String? expectedPlatform})` | Builds a result. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `payloadDir` | `final String payloadDir` | The directory checked. |
| `problems` | `final List<String> problems` | Everything wrong, in the order checked. |
| `cliPlatforms` | `final List<String> cliPlatforms` | The platform CLI packages present, by suffix, sorted. |
| `expectedPlatform` | `final String? expectedPlatform` | The platform the install was expected to carry, or null for any one. |
| `ok` | `bool get ok` | Whether `problems` is empty. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | A one-line ok summary with the CLI platforms, or the problems as a bulleted list. |

### AgentSdkCommandRunner

`typedef AgentSdkCommandRunner = Future<int> Function(String executable, List<String> arguments, {required String workingDirectory, required Map<String, String> environment, required void Function(String line) onOutput})`.
Runs one command, reports its output line by line and returns its exit code;
throws `ProcessException` when the command cannot be started. The installer's
seam; `runAgentSdkCommand` is the production one.

### AgentSdkNodeRuntime

`final class`. What the installing Node said about itself.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkNodeRuntime` | `const AgentSdkNodeRuntime({required String version, required int? major, required String platform, required String arch, required String execPath})` | Builds a runtime record. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `version` | `final String version` | `process.versions.node`, e.g. `22.22.3`. |
| `major` | `final int? major` | The major version, or null when `version` is not that shape. |
| `platform` | `final String platform` | `process.platform` (`darwin`, `linux`, `win32`). |
| `arch` | `final String arch` | `process.arch` (`arm64`, `x64`). |
| `execPath` | `final String execPath` | `process.execPath`, the interpreter's absolute path. |

### AgentSdkServerInstallState

`enum`. The installer's state as of the last look at the disk.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `notInstalled` | `notInstalled` | Nothing installed, or an install that never finished (no marker or no script). |
| `outdated` | `outdated` | Installed from a different lockfile than the app carries. |
| `installed` | `installed` | Installed from the app's lockfile, and checked. |

### AgentSdkServerInstaller

`final class`. Installs the server's dependencies into the app's data folder on
the user's request. `sourceDir` holds the three shipped files
(`agentSdkServerSourceFiles`); `installDir` is `<app-data>/ai`. The install is
built in `<installDir>.installing`, checked with `verifyAgentSdkPayloadFor`,
marked with `agentSdkInstallMarkerName` and only then moved into place, so a
failed install leaves the previous state as it was.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkServerInstaller` | `AgentSdkServerInstaller({required String sourceDir, required String installDir, List<String>? npmCommand, AgentSdkCommandRunner? runCommand})` | Builds the installer. `npmCommand` (executable plus leading arguments) overrides the npm that ships with the Node; `runCommand` defaults to `runAgentSdkCommand`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `sourceDir` | `final String sourceDir` | The shipped server source: the packaged app's `ai/` folder, or a checkout's `tom_core_agentic/node`. |
| `installDir` | `final String installDir` | Where the server is installed. |
| `serverScript` | `String get serverScript` | The installed server script the transport runs. |
| `state` | `AgentSdkServerInstallState get state` | Whether the server is installed and current: the marker and the script exist, and the installed lockfile equals the shipped one. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `install` | `Future<AgentSdkServerInstallResult> install({required LlmNodeResolution node, void Function(String line)? onProgress})` | Probes the Node (version floor, platform, architecture), chooses the CLI platform from the shipped lockfile (`chooseAgentSdkPlatform`), runs `npm ci --omit=dev --no-audit --no-fund` in the staging folder with the Node's directory first on `PATH`, verifies, writes the marker and moves the tree into place. Never throws; every failure is a result with a sentence. `onProgress` receives a line per step and every npm line. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `installDirFor` | `static String installDirFor(String appDataDirectory)` | `<appDataDirectory>/ai` (`agentSdkServerPayloadDir`). |

### AgentSdkServerInstallResult

`final class`. What `AgentSdkServerInstaller.install` ended with.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `failed` | `const AgentSdkServerInstallResult.failed(String failure, {AgentSdkPayloadVerification? verification})` | A failed install. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `ok` | `final bool ok` | Whether the server is installed and passed its post-install check. |
| `failure` | `final String? failure` | Why not, for the user; null when `ok`. |
| `platform` | `final String? platform` | The CLI platform installed; null on failure. |
| `sdkVersion` | `final String? sdkVersion` | The Agent SDK version installed; null on failure. |
| `verification` | `final AgentSdkPayloadVerification? verification` | The post-install check, when it ran. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `AgentSdkServerInstallResult(ok: …)` or `AgentSdkServerInstallResult(failed: …)`. |

## Global Functions and Constants

### boundedAiRun

```dart
Stream<LlmEvent> boundedAiRun(
  Stream<AgentSdkCompletionEvent> events, {
  required Duration stallGap,
  required String transportId,
  List<LlmEvent> prelude = const [],
  void Function(LlmTransportException failure)? onFailure,
  void Function(String messageType)? onUnmapped,
  void Function(String conversationId)? onConversation,
})
```

The transport's events as the run's trail: `prelude` first, then every
`AgentSdkTrailed` event in order, ending in exactly one `LlmRunEnded` — the far
end's own, `completed` when the stream ends without one, `failed` after an
`LlmRunError` when the stream errors, and `timeout` after an `LlmStall` when
nothing at all arrives for `stallGap`. Every event resets the gap, liveness
included. The stream never errors. `onFailure` observes a transport failure,
`onUnmapped` is told once per run of each unmapped message type, and
`onConversation` receives each `AgentSdkConversation` id. Cancelling the
result cancels the transport's stream.

### defaultAiStallTimeout

```dart
const defaultAiStallTimeout = Duration(seconds: 120);
```

How long a completion may go without any event before it is declared stalled:
a gap, not a total budget. Set at ten times the largest measured silence of a
real completion.

### agentRunMaxTurns

```dart
const agentRunMaxTurns = 24;
```

How many model turns a tool-using run without an agent loop may take before the
SDK ends it.

### agentSdkMcpToolName

```dart
String agentSdkMcpToolName(String server, String name)
```

The SDK name of a tool declared on an in-process MCP server:
`mcp__<server>__<name>`.

### discoverHostedAiWorkspaces

```dart
Future<List<AgentSdkWorkspaceCandidate>> discoverHostedAiWorkspaces({
  String host = '127.0.0.1',
  int minPort = defaultVSCodeBridgePort,
  int maxPort = maxVSCodeBridgePort,
})
```

Every VS Code CLI server answering right now, duplicates of one identity
included, sorted by port — for a workspace-pin picker.

### standaloneReadyPrefix

```dart
const standaloneReadyPrefix = 'AGENT_SDK_SERVER_READY ';
```

The line the standalone server prints once it is listening, followed by a JSON
object with its `port`.

### standaloneScriptEnvVar

```dart
const standaloneScriptEnvVar = 'AGENT_SDK_SERVER_SCRIPT';
```

The environment variable naming the server script, overriding the default
resolution.

### agentSdkServerScriptName

```dart
const agentSdkServerScriptName = 'agent_sdk_server.js';
```

The server script a packaged app ships and the standalone transport runs.

### agentSdkServerPayloadDir

```dart
const agentSdkServerPayloadDir = 'ai';
```

The name of the server's folder beside the app executable (its source) and in
the app's data folder (the installed server).

### requiredNodeMajorVersion

```dart
const requiredNodeMajorVersion = llmRequiredNodeMajorVersion;
```

The lowest Node major version the server and the Agent SDK accept; `tom_llm`'s
`llmRequiredNodeMajorVersion`.

### agentSdkNodeProblemFor

```dart
Future<String?> agentSdkNodeProblemFor(LlmNodeResolution node)
```

Why the resolved Node cannot run the server, as a sentence naming the remedy,
or null when it can: `agentSdkNodeMissingReason` when the resolution named no
executable, else `agentSdkNodeProblem`. Used by the transport's probe and
connect.

### agentSdkNodeProblem

```dart
Future<String?> agentSdkNodeProblem(String nodeExecutable)
```

Runs `<nodeExecutable> --version`: the not-runnable sentence when it cannot run
or exits non-zero, the too-old sentence when it reports a major below
`requiredNodeMajorVersion`, null otherwise (an unrecognisable version passes).

### agentSdkNodeMissingReason

```dart
String agentSdkNodeMissingReason(LlmNodeResolution node)
```

The sentence for a search that found no Node at or above the floor: its report
of where it looked, then the remedy.

### agentSdkNodeNotRunnableReason

```dart
String agentSdkNodeNotRunnableReason(String nodeExecutable)
```

The sentence for a Node that cannot be run at all.

### agentSdkNodeTooOldReason

```dart
String agentSdkNodeTooOldReason(String nodeExecutable, int major)
```

The sentence for a Node below `requiredNodeMajorVersion`.

### resolveDefaultServerScript

```dart
String resolveDefaultServerScript()
```

A runnable `agent_sdk_server.js` for a transport with no installer: the
`standaloneScriptEnvVar` override, else `resolveServerScriptFor` from the
executable's directory.

### resolveServerScriptFor

```dart
String resolveServerScriptFor({required String executableDir})
```

The first existing entry of `agentSdkServerScriptCandidates`, else
`<executableDir>/ai/agent_sdk_server.js` so an error names a location.

### agentSdkServerScriptCandidates

```dart
List<String> agentSdkServerScriptCandidates({required String executableDir})
```

Every place a runnable server script is looked for, in order — source
checkouts only: this package's `node/` through the package configuration, then
walks up from the working directory and from the script's directory.

### agentSdkServerSourceCandidates

```dart
List<String> agentSdkServerSourceCandidates({required String executableDir})
```

Every folder the server's source is looked for in: the packaged
`<executableDir>/ai` first, then the source checkouts' `node/` folders.

### resolveAgentSdkServerSourceFor

```dart
String resolveAgentSdkServerSourceFor({required String executableDir})
```

The first of `agentSdkServerSourceCandidates` holding all three source files,
else the packaged location.

### agentSdkChildEnvironment

```dart
Map<String, String> agentSdkChildEnvironment({
  required Map<String, String> parent,
  required String nodeExecutable,
  Set<String> scrubbed = const {},
  ({String apiKey, String configDirectory})? credential,
})
```

The environment the standalone server child starts with: `parent` without the
`scrubbed` variables; with a `credential`, also without every variable whose
name starts with `ANTHROPIC_` or `CLAUDE`, and with `ANTHROPIC_API_KEY` and
`CLAUDE_CONFIG_DIR` set from it; and, for a Node given as a path, that Node's
directory prepended to `PATH` (under the parent's own spelling of the
variable).

### agentSdkLooksLikeResumeError

```dart
bool agentSdkLooksLikeResumeError(String message)
```

True when the message looks like Claude Code rejecting a stale or unknown
session: it contains `session` and one of `not found`, `no conversation found`,
`invalid`, `no such`, `unknown`, `expired`, `does not exist`
(case-insensitive).

### agentSdkInstallExplanationUrl

```dart
const agentSdkInstallExplanationUrl =
    'https://github.com/al-the-bear/tom_ai_core/blob/main/'
    'tom_core_agentic/README.md#installing-the-server';
```

Where a user reads what Install does and why it is needed.

### agentSdkServerLockfileName

```dart
const agentSdkServerLockfileName = 'package-lock.json';
```

The lockfile the shipped source carries and `npm ci` installs from.

### agentSdkServerSourceFiles

```dart
const agentSdkServerSourceFiles = [
  agentSdkServerScriptName,
  'package.json',
  agentSdkServerLockfileName,
];
```

The three files a packaged app carries of the server, and the only ones.

### agentSdkInstallMarkerName

```dart
const agentSdkInstallMarkerName = '.agent_sdk_install.json';
```

The file an install writes last, after its tree passed the check; its presence
is what "installed" means.

### agentSdkPlatformFor

```dart
String? agentSdkPlatformFor({
  required String operatingSystem,
  required bool isArm64,
})
```

The Agent SDK's platform suffix for a Dart operating system name
(`darwin-<arch>`, `linux-<arch>`, `win32-<arch>`), or null for one it ships no
CLI for.

### chooseAgentSdkPlatform

```dart
AgentSdkPlatformChoice chooseAgentSdkPlatform({
  required String nodePlatform,
  required String nodeArch,
  required Set<String> shipped,
  String? sdkVersion,
})
```

Which CLI package an install for a Node reporting `nodePlatform` / `nodeArch`
gets, from the suffixes the locked SDK ships (a Linux `-musl` twin counts).
Refuses, naming the remedy, for a platform or architecture outside
macOS/Linux/Windows on arm64/x64, for Windows on ARM when only `win32-x64` is
shipped (the remedy is an x64 Node), and for any other unshipped suffix.

### stageAgentSdkServer

```dart
AgentSdkStagingReport stageAgentSdkServer({
  required String nodeSourceDir,
  required String destination,
})
```

Copies the three source files into `destination` (the `ai/` folder beside the
built executable), replacing it; never copies `node_modules`. Throws
`AgentSdkStagingException` when the source folder or a file is missing.

### verifyAgentSdkServerSource

```dart
AgentSdkSourceVerification verifyAgentSdkServerSource({
  required String sourceDir,
})
```

The release gate: the folder exists; the three files exist and are non-empty;
the lockfile locks the SDK with at least one platform package; and the folder
carries no `node_modules` and nothing of the Agent SDK.

### verifyAgentSdkPayloadFor

```dart
AgentSdkPayloadVerification verifyAgentSdkPayloadFor({
  required String payloadDir,
  required String? expectedPlatform,
})
```

The post-install check: the script and manifest are present and non-empty; the
SDK is installed with the entry point its `main` names and every peer in
`peerDependencies`; at least one platform CLI package is present (only the
`expectedPlatform` one, or its `-musl` twin, when given); and each CLI binary
exists and, off Windows, is executable.

### runAgentSdkCommand

```dart
Future<int> runAgentSdkCommand(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
  required void Function(String line) onOutput,
})
```

The production `AgentSdkCommandRunner`: `Process.start` with the parent
environment included and no shell (except a Windows `.cmd` fallback), stdin
closed, stdout and stderr reported line by line.

### agentSdkInstallOutcomeOf

```dart
AgentSdkInstallOutcome agentSdkInstallOutcomeOf(
  AgentSdkServerInstallResult result,
)
```

The `AgentSdkInstallOutcome` a transport reports for an install result.

#### Top-level getters and record-returning functions

| Constant | Type | Description |
| -------- | ---- | ----------- |
| `agentSdkHostPlatform` | `String? get agentSdkHostPlatform` | `agentSdkPlatformFor` for the machine this Dart process runs on. `@visibleForTesting`. |
| `agentSdkInLockfile` | `({String? version, Set<String> platforms})? agentSdkInLockfile(String lockfile)` | The locked SDK version and the platform suffixes it ships a CLI for, read from a `package-lock.json` text; null when the lockfile does not lock the SDK or is not JSON. |

#### Functions of the live-probe and testing libraries

Each has its own section in its library's part below.

| Function | Library | Description |
| -------- | ------- | ----------- |
| `probeAgentSdkModel` | `agent_sdk_live_probe.dart` | Connects a transport, asks for one tiny completion and waits at most `bound` for its first text. |
| `agentSdkFixtureScript` | `agent_sdk_testing.dart` | The path of a spawnable fixture script this package ships. |
| `findNodeForTests` | `agent_sdk_testing.dart` | A Node at or above `requiredNodeMajorVersion`, or null. |
| `spawnDeadlinesAreOrdered` | `agent_sdk_testing.dart` | Whether the spawn startup timeout is shorter than the test timeout. |

## Live probe library (agent_sdk_live_probe.dart)

### AgentSdkProbe

`final class`. What `probeAgentSdkModel` found, and how long finding it took.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `AgentSdkProbe` | `const AgentSdkProbe(AgentSdkProbeOutcome outcome, Duration elapsed, String detail)` | Builds a result. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `outcome` | `final AgentSdkProbeOutcome outcome` | What the probe concluded. |
| `elapsed` | `final Duration elapsed` | How long it took. |
| `detail` | `final String detail` | The sentence a skip or a failure carries. |
| `answered` | `bool get answered` | Whether a model answered. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `<outcome> after <ms> ms: <detail>`. |

### AgentSdkProbeOutcome

`enum`. The three answers of the probe.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `answered` | `answered` | A model replied; run the suite. |
| `noModel` | `noModel` | The transport connected and no model answered within the bound, the answer ended empty, or the far end failed other than as unreachable; the suite skips. |
| `unreachable` | `unreachable` | The transport could not be reached; a failure, not a skip. |

### probeAgentSdkModel

```dart
@visibleForTesting
Future<AgentSdkProbe> probeAgentSdkModel(
  AgentSdkServerTransport transport, {
  Duration bound = agentSdkProbeBound,
})
```

Connects the transport, asks for one tiny completion ("Reply with the single
word OK.") and waits at most `bound` for its first non-empty text, then closes
the transport. The transport must be a fresh instance the probe owns.

### agentSdkProbeBound

```dart
const agentSdkProbeBound = Duration(seconds: 30);
```

How long the probe waits for the first word of an answer.

## Testing library (agent_sdk_testing.dart)

### FakeAiServer

`final class`. A loopback server that speaks the CLI-server wire. In process it
backs hosted-transport tests: it answers `workspace.getInfoVce` for the
discovery scan, `agentSdk.queryVce` according to `behaviour`, and
`agentSdk.cancelVce`; other methods get a JSON-RPC error. Spawned as a script it
stands in for the Node server: it prints `readyPrefix` with its port and exits
when stdin closes. It records every raw byte and every decoded request it
receives.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `replies` | `final List<String> replies` | Text deltas returned for each query. |
| `behaviour` | `final FakeAiServerBehaviour behaviour` | How queries are answered. |
| `workspaceName` | `final String workspaceName` | The workspace identity reported to the discovery scan. |
| `dripInterval` | `final Duration dripInterval` | The pause between deltas, thinking beats or retry events. |
| `thinkingBeats` | `final int thinkingBeats` | How many beats precede the answer under `thinkAloudThenAnswer` (and retries under `retryThenAnswer`). |
| `recorded` | `final List<Map<String, dynamic>> recorded` | The messages `replay` sends, in order. |
| `receivedBytes` | `final BytesBuilder receivedBytes` | Every byte received, in order. |
| `requests` | `final List<Map<String, dynamic>> requests` | Every decoded request, in order. |
| `cancelled` | `final List<String> cancelled` | Stream ids that received an `agentSdk.cancelVce`. |
| `toolCalls` | `List<(String, String, Map<String, Object?>)> toolCalls` | The calls made under `callTools`, as `(server, tool, args)`; settable. |
| `toolAnswers` | `final List<Map<String, dynamic>> toolAnswers` | The client's whole JSON-RPC answer to each `agentSdk.toolCall`, in order. |
| `port` | `int get port` | The bound port. |
| `receivedText` | `String get receivedText` | Everything received, decoded as UTF-8. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `stop` | `Future<void> stop()` | Stops open-ended behaviours and closes the server socket. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `start` | `static Future<FakeAiServer> start({List<String> replies = const ['Hello from the fixture.'], FakeAiServerBehaviour behaviour = FakeAiServerBehaviour.succeed, String workspaceName = 'agent-sdk-fixture', Duration dripInterval = const Duration(milliseconds: 200), int thinkingBeats = 5, int port = 0, List<Map<String, dynamic>> recorded = const []})` | Binds a loopback server (port 0 for an ephemeral one) and starts answering. |

### FakeAiServerBehaviour

`enum`. How a `FakeAiServer` answers a query.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `succeed` | `succeed` | Streams `replies` as assistant text blocks, then `done`. |
| `echoPrompt` | `echoPrompt` | Answers with the prompt it received, as one text block. |
| `failWithError` | `failWithError` | Sends a terminal `error` chunk. |
| `slowDrip` | `slowDrip` | Streams `replies` with `dripInterval` before each — a slow but live far end. |
| `thinkAloudThenAnswer` | `thinkAloudThenAnswer` | Sends only `stream_event` chunks for `thinkingBeats` beats, then the answer in one block. |
| `hang` | `hang` | Accepts the query and never answers. |
| `rejectCredential` | `rejectCredential` | `system/init`, then a `system/api_retry` carrying status 401 / `authentication_failed` every `dripInterval` until cancelled. |
| `retryThenAnswer` | `retryThenAnswer` | `thinkingBeats` `system/api_retry` events with status 529 / `server_error`, then the answer. |
| `callTools` | `callTools` | An assistant message with the first reply and a `tool_use` block per `toolCalls` entry, then one `agentSdk.toolCall` request per entry (each awaited, answers in `toolAnswers`), then the remaining replies and `done`. |
| `replay` | `replay` | Sends each `recorded` message as one chunk, then `done`. |

### ReservedPort

`final class`. A loopback port held but not served: every connection is closed
at once, which a client cannot tell from no server, and no other process can
take the port. `serve` later turns the same socket into a `FakeAiServer`.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `port` | `int get port` | The held port. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `serve` | `FakeAiServer serve({List<String> replies = const ['Hello from the fixture.'], FakeAiServerBehaviour behaviour = FakeAiServerBehaviour.succeed, String workspaceName = 'agent-sdk-fixture'})` | Starts answering on this port as a `FakeAiServer` (200 ms drip interval, 5 thinking beats). |
| `release` | `Future<void> release()` | Closes the socket. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `bind` | `static Future<ReservedPort> bind()` | Binds an ephemeral loopback port and holds it. |

### readyPrefix

```dart
const readyPrefix = 'AGENT_SDK_SERVER_READY ';
```

The ready line the spawned fixture prints, the same the standalone transport
waits for.

**The script's entry point** (`Future<void> main(List<String> args)`, not part
of the library):

The spawned entry point of `fake_ai_server.dart` (`dart <path>`, see
`agentSdkFixtureScript`): starts a `FakeAiServer` answering
`['Hello from the ', 'spawned fixture.']`, prints `readyPrefix` with its port as
JSON, and stops and exits when stdin closes. `agent_sdk_testing.dart` exports
the file with `hide main`, so it is not part of the library's namespace; it is
run as a script.

### agentSdkFixtureScript

```dart
String agentSdkFixtureScript(String name)
```

The path of the spawnable fixture `<name>.dart` this package ships —
`fake_ai_server` (scripted answers) or `echo_ai_server` (answers with the
prompt it received) — resolved through the package configuration, for a
standalone transport to start with a Dart CLI in place of Node. Throws
`StateError` when no package configuration resolves the package and
`ArgumentError` for an unknown name.

### agentSdkNodeEnvVar

```dart
const agentSdkNodeEnvVar = 'AGENT_SDK_NODE';
```

The environment variable that names the Node for the tests explicitly.

### findNodeForTests

```dart
String? findNodeForTests()
```

A Node at or above `requiredNodeMajorVersion`, or null: tries
`agentSdkNodeEnvVar`, then `node`, then the nvm installs under
`~/.nvm/versions/node`, newest first.

### spawnStartupTimeout

```dart
const spawnStartupTimeout = Duration(seconds: 30);
```

How long a spawned fixture may take to print its ready line.

### spawnTestTimeout

```dart
const spawnTestTimeout = Duration(seconds: 90);
```

The harness bound for a test that spawns a child: three times the startup
bound, so a slow start fails as a transport error inside a live test.

#### Top-level getter

| Constant | Type | Description |
| -------- | ---- | ----------- |
| `spawnDeadlinesAreOrdered` | `bool get spawnDeadlinesAreOrdered` | Whether `spawnStartupTimeout < spawnTestTimeout`, as a value a test can assert. |

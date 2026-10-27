# Tom Core Agentic API Reference: Index

Symbol-level API summaries for this package's units, one file per unit, under
`doc/api/`. Each lists every public type, function and constant its unit's
barrel exports, with a section per name, and names every public static member.
Which units get one is a stated rule, below.

`test/api_summary_test.dart` holds that claim. Nothing in it is written out:
the summaries are discovered from this directory, the required set is derived
from each unit's barrel, and the rule below is applied to every directory under
`lib/src/`. So a summary that exists is complete, a summary that falls behind
the code fails rather than misleading, and a unit that grows past the threshold
without gaining one fails too.

## Summaries

| Unit | Summary | Covers |
| ---- | ------- | ------ |
| `agent` | [api_summary_agent.md](api_summary_agent.md) | The editor-facing agent layer: eleven YAML sidecars and their models, bridge discovery and binding, the reconnect loop, and the send engine. |
| `isolate_streaming` | [api_summary_isolate_streaming.md](api_summary_isolate_streaming.md) | The primitives a host and a worker isolate share: cancellation tokens, close signals, backpressure credit, request guards, and typed-error reconstruction. |
| `llm` | [api_summary_llm.md](api_summary_llm.md) | The Anthropic Agent SDK provider over the `tom_core_llm` contract, and the three session strategies. |
| `placeholders` | [api_summary_placeholders.md](api_summary_placeholders.md) | The placeholder engine: the four forms, the lexical scope chain, the expression seam, and the three wire-coded failures. |

## Which units get one

**A unit earns a summary at ten exported public members.** Members, not types
and not lines: what a reader has to hold in their head to use a unit is the set
of things they can call, and a type with nine methods on it costs more than
three types with one each.

| Unit | Members | Types | Summary |
| ---- | ------: | ----: | ------- |
| `agent` | 345 | 52 | yes |
| `isolate_streaming` | 47 | 12 | yes |
| `llm` | 35 | 6 | yes |
| `placeholders` | 35 | 6 | yes |
| `bearer_auth` | 5 | 3 | yes, and `doc/bearer_auth.md` |
| `mcp_auth` | 0 | 0 | yes, and `doc/mcp_auth.md` |

Both columns are derived and pinned: `test/api_summary_test.dart` measures each
unit and fails this table when a figure drifts. A source-line column stood here
and was removed rather than pinned — the argument rests on members, and a length
nobody maintains is worse than no length.

**Counting types instead put `placeholders` on the wrong side**, which is what
the measure was changed for. On types it reads 6 against `isolate_streaming`'s
12 and lands beside `bearer_auth`'s 3; on members it reads 35 against 47 and
lands beside `isolate_streaming`, which is where its source size puts it too.
`PlaceholderResolver` and `PlaceholderStack` carry seventeen members between
them, and a type count cannot see any of them.

The member figure also partitions more decisively: 0, 5 | 35, 47, 107, 345 is a
sevenfold gap with nothing near the line, where 3, 6 | 12, 20, 52 is a factor of
two. A threshold is only worth stating rather than deciding case by case when
it has no borderline, and this one has none.

**`tom_flutter_ui` states the same threshold over types**, and deliberately so:
it is a widget catalogue where a type *is* the unit of surface — 299 widgets,
most of them a constructor and no more — so counting members there would
measure the base class's parameter list rather than the kit. The two rules
disagree because the packages have different shapes, not because one is stale
— so the number is the same and what it counts is not, and a reader who has met
one index should not assume the other.

**Below the threshold the unit's prose page is a mirror too**, and that is a
checked claim rather than a courtesy: the `## Overview` table of
`doc/<unit>.md` is held to every public type, function and constant the unit
exports, by the same test. The threshold is the floor this package's suite sets;
the repository's `tom_ai/core/tool/check_api_reference.py` asks for a summary
of every unit, which is why `bearer_auth` and `mcp_auth` have both.

The Overview check exists here rather than only in
`tool/check_doc_overview_types.py` because that gate compares **types**, and a
unit that exports none is skipped by it — `mcp_auth` is two constants and is
named in that gate's source as the reason the skip exists. Two constants are
exactly the surface a reader most expects a document to have got right, so the
package's own suite asks the question the repository gate cannot.

### Agent (`lib/src/agent/`)

Summary: [api_summary_agent.md](api_summary_agent.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `AgentProfile` | final class | A named persona that supplies the system prompt and per-send behaviour. |
| `AgentProfileStore` | final class | Loads/saves the agent-profile set (`List<AgentProfile>`) as YAML. |
| `AgentSdkClientFactory` | typedef | Builds (and connects) an [AgentSdkClient] over the VS Code bridge at [host]:[port] — the editor's transport seam. |
| `AgentSendChunk` | final class | A streamed chunk of assistant answer text (in order). |
| `AgentSendCompleted` | final class | Terminal success: the query produced a result message. |
| `AgentSendConfig` | final class | The editor-assembled inputs to one `query` `Options`, minus the session id (which the engine supplies from [SpecSessionStore]). |
| `AgentSendEngine` | final class | Streams a single prompt through the Agent SDK and keeps the per-spec session id refreshed. |
| `AgentSendEvent` | sealed class | One step of an [AgentSendEngine.send] run. |
| `AgentSendFailed` | final class | Terminal failure: a non-session error, or a stream with no result message. |
| `AgentSendSessionRefreshed` | final class | Emitted when a session error caused the stored session id to be dropped and the prompt to be retried with a fresh session. |
| `AgentSendStarted` | final class | Emitted once, first, when a send begins. |
| `AgentSettings` | final class | Global agent settings: bridge target + the defaults a profile overlays. |
| `AgentSettingsStore` | final class | Loads/saves the singleton [AgentSettings] as YAML. |
| `BridgeChoice` | final class | The persisted choice: which host+port the editor last bound to. |
| `BridgeChoiceStore` | final class | Persists the picked bridge server to a YAML sidecar so the binding is restored on the next launch. |
| `BridgeConnectionService` | final class | Discovers live VS Code bridge servers. |
| `BridgePortScanner` | typedef | Scans the bridge port range and returns a `port → workspace` table. |
| `BridgeServer` | final class | One responsive VS Code bridge: its port, the workspace its window has open, and how it relates to the editor (`available` / `bound`). |
| `BridgeServerStatus` | enum | How a discovered server relates to the editor right now. |
| `ChatMessage` | final class | A single message in a chat exchange. |
| `ChatRole` | enum | Who authored a chat message. |
| `ChatVariable` | final class | A single placeholder binding identified by its [name]. |
| `ChatVariableStore` | final class | Loads/saves the custom chat-variable set (`List<ChatVariable>`) as YAML. |
| `EditorPlaceholderBindings` | final class | Resolves the editor's supported placeholder forms against a fixed set of [bindings] (e.g. |
| `PlaceholderExpressionsUnsupportedError` | final class | Thrown when a template contains a `${{ … }}` expression form, which the editor deliberately does not support. |
| `PromptQueueStore` | final class | Loads/saves the editor prompt queue (`List<QueuedPrompt>`) as YAML. |
| `PromptTemplate` | final class | A reusable prompt body identified by [id]. |
| `PromptTemplateStore` | final class | Loads/saves the prompt-template set (`List<PromptTemplate>`) as YAML. |
| `PromptTrailStore` | final class | Loads/saves the editor prompt trail (`List<TrailPair>`) as YAML. |
| `QueueTemplate` | final class | A named, ordered set of prompt bodies identified by [id]. |
| `QueueTemplateStore` | final class | Loads/saves the queue-template set (`List<QueueTemplate>`) as YAML. |
| `QueuedFollowUpPrompt` | final class | A follow-up prompt sent after a queue item's main prompt is answered. |
| `QueuedPrePrompt` | final class | A pre-prompt sent ahead of a queue item's main prompt. |
| `QueuedPrePromptStatus` | enum | Status of a pre-prompt — the source uses a narrower set than the main queue item. |
| `QueuedPrompt` | final class | A prompt queued for dispatch, with optional pre-prompts, follow-ups, reminders, repeats and multi-transport routing. |
| `QueuedPromptStatus` | enum | Lifecycle of a queued prompt. |
| `QueuedPromptType` | enum | What kind of queued prompt this is. |
| `QueuedTransport` | enum | Which backend a queued prompt dispatches through. |
| `ReconnectCoordinator` | final class | Runs the reconnect back-off: after each delay it rescans the bridge range and, the first time the bound port answers, classifies the result as the same or a different workspace; if the port never answers it resolves [ReconnectResolution.stillGone]. |
| `ReconnectDelay` | typedef | Delays for [duration] before the next rescan. |
| `ReconnectResolution` | enum | How a reconnect attempt resolved. |
| `ReconnectResult` | final class | The outcome of [ReconnectCoordinator.reconnect]. |
| `ReminderTemplate` | final class | A reusable reminder body identified by [id]. |
| `ReminderTemplateStore` | final class | Loads/saves the reminder-template set (`List<ReminderTemplate>`) as YAML. |
| `ScheduleMode` | enum | How a timed request fires: on a fixed interval or at scheduled times. |
| `ScheduledTime` | final class | A single scheduled slot. |
| `SpecSessionStore` | final class | The per-specification SDK session id, persisted to a YAML sidecar so the agent can resume the same Claude-Code conversation across sends and launches. |
| `TimedRequest` | final class | A timed / repeating prompt entry. |
| `TimedRequestStatus` | enum | Lifecycle of a timed request entry. |
| `TimedRequestStore` | final class | Loads/saves the timed-request set (`List<TimedRequest>`) as YAML. |
| `ToolApprovalMode` | enum | Approval gate for write tool calls. |
| `TrailPair` | final class | One request/answer pair from an SDK exchange, as shown in the trail. |
| `composeInterruptRetry` | function | Composes the auto-resend body for an interrupted prompt: the active profile's [prefix] followed by the original [prompt]. |
| `connectAgentSdkClient` | function | The production [AgentSdkClientFactory]: opens a [VSCodeBridgeClient] socket and wraps it in the bridge-backed transport. |
| `decodeAgentYaml` | function | Parses a YAML document [yaml] into a plain `Map<String, dynamic>`. |
| `decodeAgentYamlEntries` | function | Builds models from the YAML list [node], skipping the elements it cannot build, or returns `null` when [node] is not a list at all. |
| `decodeAgentYamlList` | function | Builds the models in the list under [key] of [root], skipping the entries the file cannot supply. |
| `decodeAgentYamlValue` | function | Builds the single model under [key] of [root], or [orElse] when the file cannot supply it. |
| `deepPlainYaml` | function | Recursively converts a parsed YAML tree ([YamlMap] / [YamlList] / scalar) into plain Dart collections. |
| `encodeAgentYaml` | function | Serialises [data] to a YAML document string. |
| `permissionModeForApproval` | function | The SDK permission mode a [ToolApprovalMode] asks for. |
| `thinkingConfigFor` | function | The SDK thinking configuration a profile's thinking settings ask for, or `null` when unset. |
| `readAgentYamlFile` | function | Reads and parses the sidecar at [file], or `null` when it is missing, empty, unreadable or malformed. |
| `specSessionLooksLikeError` | function | True when [message] should be treated as an SDK **session error** under the editor rule: its text contains `session`, `message`, or `msg` (case-insensitive). |
| `yamlEnum` | function | Reads [key] as a string and maps it through [fromValue], or `null` when [key] holds no string. |
| `yamlStringList` | function | Reads [key] as a list of strings, keeping the elements that are strings, or `null` when [key] does not hold a list. |
| `yamlValue` | function | Reads [key] from [yaml] when it holds a [T], and `null` when it does not — whether the key is absent or present with the wrong type. |

### Bearer Auth (`lib/src/bearer_auth/`)

Summary: [api_summary_bearer_auth.md](api_summary_bearer_auth.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `BearerAuthFailure` | final class | Raised when a bearer token cannot be accepted. |
| `BearerAuthFailureReason` | enum | Categories of bearer-token authentication failure. |
| `BearerTokenAuthenticator` | abstract interface class | Validates a bearer token and resolves it to a principal of type [P]. |

### Isolate Streaming (`lib/src/isolate_streaming/`)

Summary: [api_summary_isolate_streaming.md](api_summary_isolate_streaming.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `BackpressureTracker` | final class | Per-stream credit ledger held by a stream producer. |
| `IsolateCancellationException` | final class | Thrown by the executor when a cancellable request is cancelled at (or after) a checkpoint. |
| `IsolateCancellationHandle` | final class | Per-request cancellation handle returned by [IsolateCancellationRegistry.register]. |
| `IsolateCancellationRegistry` | final class | In-isolate registry of cancellation state per token. |
| `IsolateCancellationToken` | final class | Opaque identifier for a cancellable request, sendable across an isolate boundary. |
| `IsolateCancellationTokenAllocator` | final class | Host-side counter that hands out unique [IsolateCancellationToken]s. |
| `IsolateExceptionFactory` | typedef | Rebuilds a typed exception host-side from the flat wire form a worker packed: the original `message` and a sendable `details` map of the exception's structured fields. |
| `IsolateExceptionRegistry` | final class | Host-side registry that turns the flat wire form of a worker-thrown exception (a type tag + message + sendable details map) back into a typed instance, so consumers `catch` the same type the worker threw instead of an untyped boundary wrapper. |
| `IsolateRequestFailure` | final class | Typed failure raised in place of an indefinite hang when a guarded isolate request cannot complete. |
| `IsolateRequestFailureReason` | enum | Why a request crossing an isolate boundary could not complete. |
| `IsolateRequestGuard` | final class | Bounds each request crossing an isolate boundary so it fails with a typed [IsolateRequestFailure] instead of hanging forever. |
| `IsolateStreamCloseSignal` | final class | Per-stream close-signal block held by a stream producer. |

### Llm (`lib/src/llm/`)

Summary: [api_summary_llm.md](api_summary_llm.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `AgentSdkLlmProvider` | final class | One Anthropic-Agent-SDK backend, exposed as an [LlmProvider]. |
| `AgentSdkSessionStore` | final class | A small JSON-backed `session id → Claude-Code session id` map, persisted at [file]. |
| `AgentSdkSessionStrategy` | abstract interface class | Decides, per call, whether the provider resumes a stored Claude-Code session or starts fresh, and records the session id a successful call produced. |
| `BrainSessionStrategy` | final class | Session mode `brain`: persists the Claude-Code session id keyed by the caller's session id ([LlmOptions.sessionId]). |
| `NoSessionStrategy` | final class | Session mode `none`: every call is a first call. |
| `QuestSessionStrategy` | final class | Session mode `quest`: resumes the Claude-Code session recorded in the VS Code window's quest history file, read-only. |
| `agentSdkLooksLikeSessionError` | function | True when [message] looks like a Claude-Code rejection of a stale / unknown session id, so the `brain`-mode provider should evict the stored id and retry once with a fresh session. |

### Mcp Auth (`lib/src/mcp_auth/`)

Summary: [api_summary_mcp_auth.md](api_summary_mcp_auth.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |

### Placeholders (`lib/src/placeholders/`)

Summary: [api_summary_placeholders.md](api_summary_placeholders.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `PlaceholderExpressionException` | final class | Raised when a `${{ … }}` expression throws or fails to parse during evaluation against the expression backing, or when a `${{ … }}` form is encountered by a resolver that has no expression backing (e.g. |
| `PlaceholderExpressions` | abstract interface class | Evaluates the `${{ … }}` placeholder form against a binding scope. |
| `PlaceholderRecursionException` | final class | Raised when recursive placeholder expansion does not terminate within the resolver's level cap (default 10). |
| `PlaceholderUnresolvedException` | final class | Raised when an unknown `${name}` / `${env:NAME}` is encountered while the resolver runs in **strict** mode. |
| `isSimpleIdentifier` | function | Returns whether [name] is a bare Dart identifier. |

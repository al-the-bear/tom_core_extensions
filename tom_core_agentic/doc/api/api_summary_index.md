# Tom Core Agentic API Reference: Index

Symbol-level API summaries for the whole public API of this package, under
`doc/api/`: one per unit (a folder under `lib/src/` with a barrel named after
it), one per public library beside the main one (`agent_sdk.dart` with its
testing and live-probe libraries, `agent_tools.dart`), and one for the small
helpers the main library exports straight from `lib/src/` (the utilities).
Each lists every public type, function and constant of what it mirrors, with a
section per name, and names every public member.

`test/api_summary_test.dart` holds that claim. Nothing in it is written out:
the summaries are discovered from this directory, the required set is derived
from each unit's barrel or library, and every unit and public library is asked
for its summary. So a summary that exists is complete, a summary that falls
behind the code fails rather than misleading, and a unit or library without one
fails too. `buildkit :apisummary --strict` checks the same API from the other
side: every public symbol of `lib/*.dart` named in some summary.

## Summaries

| Summary | Mirrors | Covers |
| ------- | ------- | ------ |
| [api_summary_agent.md](api_summary_agent.md) | unit `agent` | The editor-facing agent layer: eleven YAML sidecars and their models, bridge discovery and binding, the reconnect loop, and the send engine. |
| [api_summary_agent_sdk.md](api_summary_agent_sdk.md) | `agent_sdk.dart`, `agent_sdk_testing.dart`, `agent_sdk_live_probe.dart` | The Agent SDK client: its transports, sessions and resume, the server payloads, the stall bound, and the fake server and live probe for tests. |
| [api_summary_agent_tools.md](api_summary_agent_tools.md) | `agent_tools.dart` | Tools an agent calls: their schemas, scopes and binding, invocation, preview-then-apply, the audit trail and the errors. |
| [api_summary_bearer_auth.md](api_summary_bearer_auth.md) | unit `bearer_auth` | Bearer-token authentication: the authenticator interface and its failures. |
| [api_summary_isolate_streaming.md](api_summary_isolate_streaming.md) | unit `isolate_streaming` | The primitives a host and a worker isolate share: cancellation tokens, close signals, backpressure credit, request guards, and typed-error reconstruction. |
| [api_summary_mcp_auth.md](api_summary_mcp_auth.md) | unit `mcp_auth` | The two constants of bearer authentication over MCP. |
| [api_summary_placeholders.md](api_summary_placeholders.md) | unit `placeholders` | The placeholder engine: the four forms, the lexical scope chain, the expression seam, and the three wire-coded failures. |
| [api_summary_utilities.md](api_summary_utilities.md) | the main library's own `lib/src/*.dart` files | The small domain-free helpers: guards, clocks and deadlines, caches and rate limits, YAML and JSON readers, text and time formatting, and the rest. |

## Prose pages

A unit or library with a guide has a prose page `doc/<name>.md` beside its
summary: `agent.md`, `agent_sdk.md`, `agent_tools.md`, `bearer_auth.md`,
`isolate_streaming.md`, `mcp_auth.md`, `placeholders.md`. The page explains
behaviour and is free to omit a symbol, with one exception the test holds: the
`## Overview` table of a small unit (fewer than ten exported members:
`bearer_auth`, `mcp_auth`) names its whole surface, because that page is the
one a reader of a small unit is sent to.

**`tom_flutter_ui` states a threshold over types**: there a summary is written
for a module from ten exported types, because a widget is the unit of surface.
This package summarises everything, so no count decides here.

## Units

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
| `AgentSidecarStore` | abstract base class | The base of the agent stores: one YAML sidecar read and written through the workspace's `TomFileSystem`. |
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
| `specSessionLooksLikeError` | function | True when [message] should be treated as an SDK **session error** under the editor rule: its text contains `session`, `message`, or `msg` (case-insensitive). |
| `yamlEnum` | function | Reads [key] as a string and maps it through [fromValue], or `null` when [key] holds no string. |
| `yamlStringList` | function | Reads [key] as a list of strings, keeping the elements that are strings, or `null` when [key] does not hold a list. |
| `yamlValue` | function | Reads [key] from [yaml] when it holds a [T], and `null` when it does not — whether the key is absent or present with the wrong type. |

### Agent SDK (`lib/agent_sdk.dart`, `agent_sdk_testing.dart`, `agent_sdk_live_probe.dart`)

Summary: [api_summary_agent_sdk.md](api_summary_agent_sdk.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `AgentSdkSessionProvider` | final class | `final class`, extends `LlmProvider`. |
| `AgentSdkWhenBusy` | enum | What a run does when its session already has one. |
| `AgentSdkRunAttribution` | enum | Whom a run names as the provider that answered it, in its `LlmRunStarted` and its report. |
| `AgentSdkSessionManager` | final class | The AI sessions of an app, run from the main isolate. |
| `AgentSdkSessionHosting` | enum | Where a session runs. |
| `AgentSdkServerTransport` | abstract class | The seam the provider is written against; the hosted and standalone paths implement it. |
| `AgentSdkInstallableTransport` | abstract interface class | `abstract interface class`, implements `AgentSdkServerTransport`. |
| `AgentSdkCompletionRequest` | final class | One completion request at the transport layer. |
| `AgentSdkAgentLoop` | final class | Claude Code running its own agent loop for a request: its tools, its MCP servers and its turns, under a permission mode. |
| `AgentSdkToolDeclaration` | typedef | One tool as the model is told about it: the registry entry's name, summary and JSON-Schema arguments. |
| `AgentSdkToolSet` | final class | The tools a request offers, reduced to what a transport needs to relay a call: declarations and a function that answers a call with text. |
| `AgentSdkCompletionEvent` | sealed class | One thing a running completion says: an event of its trail, the conversation it belongs to, or the fact that it is still alive. |
| `AgentSdkTrailed` | final class | `final class`, extends `AgentSdkCompletionEvent`. |
| `AgentSdkConversation` | final class | `final class`, extends `AgentSdkCompletionEvent`. |
| `AgentSdkLiveness` | final class | `final class`, extends `AgentSdkCompletionEvent`. |
| `AgentSdkUnavailableKind` | enum | Why the availability gate is shut, as a kind a program can branch on. |
| `AgentSdkInstallOutcome` | final class | What an on-demand install of a transport's server ended with. |
| `CliServerAiChannel` | final class | A connected CLI-server endpoint, reduced to the one operation the AI adapter needs; both transports hold one. |
| `HostedCliServerAiTransport` | final class | `final class`, implements `AgentSdkServerTransport`. |
| `AgentSdkWorkspaceCandidate` | final class | One VS Code CLI server that answered a discovery scan: its workspace identity and the port it answered on (for this scan only). |
| `HostedServerResolution` | final class | What one discovery scan concluded for a transport's configuration. |
| `StandaloneNodeAiTransport` | final class | `final class`, implements `AgentSdkInstallableTransport`. |
| `AgentSdkTransportSelector` | final class | Picks the transport to use and owns the availability verdict. |
| `AgentSdkNotice` | final class | One sentence about AI the shell shows once: an unavailability explanation or a working transport's selection notice. |
| `AgentSdkResumeStrategy` | abstract interface class | Decides per call whether the provider resumes a stored conversation or starts fresh, and records the conversation id a successful call produced. |
| `AgentSdkResumeStore` | final class | A JSON-backed `session id → conversation id` map at `file`, loaded lazily and cached; every mutation flushes the whole map. |
| `AgentSdkStoredResume` | final class | `final class`, implements `AgentSdkResumeStrategy`. |
| `AgentSdkQuestResume` | final class | `final class`, implements `AgentSdkResumeStrategy`. |
| `AgentSdkPlatformChoice` | final class | Which Claude Code CLI an install will get, or why it can get none; produced by `chooseAgentSdkPlatform`. |
| `AgentSdkStagingReport` | final class | What `stageAgentSdkServer` did, for a build log. |
| `AgentSdkStagingException` | final class | `final class`, implements `Exception`. |
| `AgentSdkSourceVerification` | final class | What `verifyAgentSdkServerSource` found: everything wrong with the server source a build carries. |
| `AgentSdkPayloadVerification` | final class | What `verifyAgentSdkPayloadFor` found about an installed server. |
| `AgentSdkCommandRunner` | typedef | Runs one command, reports its output line by line and returns its exit code; throws `ProcessException` when the command cannot be started. |
| `AgentSdkNodeRuntime` | final class | What the installing Node said about itself. |
| `AgentSdkServerInstallState` | enum | The installer's state as of the last look at the disk. |
| `AgentSdkServerInstaller` | final class | Installs the server's dependencies into the app's data folder on the user's request. |
| `AgentSdkServerInstallResult` | final class | What `AgentSdkServerInstaller.install` ended with. |
| `boundedAiRun` | function | The transport's events as the run's trail: `prelude` first, then every `AgentSdkTrailed` event in order, ending in exactly one `LlmRunEnded` — the far end's own, `completed` when the stream ends without one, `failed` after an `LlmRunError` when the stream errors, and `timeout` after an `LlmStall` when nothing at all arrives for `stallGap`. |
| `defaultAiStallTimeout` | constant | How long a completion may go without any event before it is declared stalled: a gap, not a total budget. |
| `agentRunMaxTurns` | constant | How many model turns a tool-using run without an agent loop may take before the SDK ends it. |
| `agentSdkMcpToolName` | function | The SDK name of a tool declared on an in-process MCP server: `mcp__<server>__<name>`. |
| `discoverHostedAiWorkspaces` | function | Every VS Code CLI server answering right now, duplicates of one identity included, sorted by port — for a workspace-pin picker. |
| `standaloneReadyPrefix` | constant | The line the standalone server prints once it is listening, followed by a JSON object with its `port`. |
| `standaloneScriptEnvVar` | constant | The environment variable naming the server script, overriding the default resolution. |
| `agentSdkServerScriptName` | constant | The server script a packaged app ships and the standalone transport runs. |
| `agentSdkServerPayloadDir` | constant | The name of the server's folder beside the app executable (its source) and in the app's data folder (the installed server). |
| `requiredNodeMajorVersion` | constant | The lowest Node major version the server and the Agent SDK accept; `tom_llm`'s `llmRequiredNodeMajorVersion`. |
| `agentSdkNodeProblemFor` | function | Why the resolved Node cannot run the server, as a sentence naming the remedy, or null when it can: `agentSdkNodeMissingReason` when the resolution named no executable, else `agentSdkNodeProblem`. |
| `agentSdkNodeProblem` | function | Runs `<nodeExecutable> --version`: the not-runnable sentence when it cannot run or exits non-zero, the too-old sentence when it reports a major below `requiredNodeMajorVersion`, null otherwise (an unrecognisable version passes). |
| `agentSdkNodeMissingReason` | function | The sentence for a search that found no Node at or above the floor: its report of where it looked, then the remedy. |
| `agentSdkNodeNotRunnableReason` | function | The sentence for a Node that cannot be run at all. |
| `agentSdkNodeTooOldReason` | function | The sentence for a Node below `requiredNodeMajorVersion`. |
| `resolveDefaultServerScript` | function | A runnable `agent_sdk_server.js` for a transport with no installer: the `standaloneScriptEnvVar` override, else `resolveServerScriptFor` from the executable's directory. |
| `resolveServerScriptFor` | function | The first existing entry of `agentSdkServerScriptCandidates`, else `<executableDir>/ai/agent_sdk_server.js` so an error names a location. |
| `agentSdkServerScriptCandidates` | function | Every place a runnable server script is looked for, in order — source checkouts only: this package's `node/` through the package configuration, then walks up from the working directory and from the script's directory. |
| `agentSdkServerSourceCandidates` | function | Every folder the server's source is looked for in: the packaged `<executableDir>/ai` first, then the source checkouts' `node/` folders. |
| `resolveAgentSdkServerSourceFor` | function | The first of `agentSdkServerSourceCandidates` holding all three source files, else the packaged location. |
| `agentSdkChildEnvironment` | function | The environment the standalone server child starts with: `parent` without the `scrubbed` variables; with a `credential`, also without every variable whose name starts with `ANTHROPIC_` or `CLAUDE`, and with `ANTHROPIC_API_KEY` and `CLAUDE_CONFIG_DIR` set from it; and, for a Node given as a path, that Node's directory prepended to `PATH` (under the parent's own spelling of the variable). |
| `agentSdkLooksLikeResumeError` | function | True when the message looks like Claude Code rejecting a stale or unknown session: it contains `session` and one of `not found`, `no conversation found`, `invalid`, `no such`, `unknown`, `expired`, `does not exist` (case-insensitive). |
| `agentSdkInstallExplanationUrl` | constant | Where a user reads what Install does and why it is needed. |
| `agentSdkServerLockfileName` | constant | The lockfile the shipped source carries and `npm ci` installs from. |
| `agentSdkServerSourceFiles` | constant | The three files a packaged app carries of the server, and the only ones. |
| `agentSdkInstallMarkerName` | constant | The file an install writes last, after its tree passed the check; its presence is what "installed" means. |
| `agentSdkPlatformFor` | function | The Agent SDK's platform suffix for a Dart operating system name (`darwin-<arch>`, `linux-<arch>`, `win32-<arch>`), or null for one it ships no CLI for. |
| `chooseAgentSdkPlatform` | function | Which CLI package an install for a Node reporting `nodePlatform` / `nodeArch` gets, from the suffixes the locked SDK ships (a Linux `-musl` twin counts). |
| `stageAgentSdkServer` | function | Copies the three source files into `destination` (the `ai/` folder beside the built executable), replacing it; never copies `node_modules`. |
| `verifyAgentSdkServerSource` | function | The release gate: the folder exists; the three files exist and are non-empty; the lockfile locks the SDK with at least one platform package; and the folder carries no `node_modules` and nothing of the Agent SDK. |
| `verifyAgentSdkPayloadFor` | function | The post-install check: the script and manifest are present and non-empty; the SDK is installed with the entry point its `main` names and every peer in `peerDependencies`; at least one platform CLI package is present (only the `expectedPlatform` one, or its `-musl` twin, when given); and each CLI binary exists and, off Windows, is executable. |
| `runAgentSdkCommand` | function | The production `AgentSdkCommandRunner`: `Process.start` with the parent environment included and no shell (except a Windows `.cmd` fallback), stdin closed, stdout and stderr reported line by line. |
| `agentSdkInstallOutcomeOf` | function | The `AgentSdkInstallOutcome` a transport reports for an install result. |
| `AgentSdkProbe` | final class | What `probeAgentSdkModel` found, and how long finding it took. |
| `AgentSdkProbeOutcome` | enum | The three answers of the probe. |
| `probeAgentSdkModel` | function | Connects the transport, asks for one tiny completion ("Reply with the single word OK.") and waits at most `bound` for its first non-empty text, then closes the transport. |
| `agentSdkProbeBound` | constant | How long the probe waits for the first word of an answer. |
| `FakeAiServer` | final class | A loopback server that speaks the CLI-server wire. |
| `FakeAiServerBehaviour` | enum | How a `FakeAiServer` answers a query. |
| `ReservedPort` | final class | A loopback port held but not served: every connection is closed at once, which a client cannot tell from no server, and no other process can take the port. |
| `readyPrefix` | constant | The ready line the spawned fixture prints, the same the standalone transport waits for. |
| `agentSdkFixtureScript` | function | The path of the spawnable fixture `<name>.dart` this package ships — `fake_ai_server` (scripted answers) or `echo_ai_server` (answers with the prompt it received) — resolved through the package configuration, for a standalone transport to start with a Dart CLI in place of Node. |
| `agentSdkNodeEnvVar` | constant | The environment variable that names the Node for the tests explicitly. |
| `findNodeForTests` | function | A Node at or above `requiredNodeMajorVersion`, or null: tries `agentSdkNodeEnvVar`, then `node`, then the nvm installs under `~/.nvm/versions/node`, newest first. |
| `spawnStartupTimeout` | constant | How long a spawned fixture may take to print its ready line. |
| `spawnTestTimeout` | constant | The harness bound for a test that spawns a child: three times the startup bound, so a slow start fails as a transport error inside a live test. |
| `agentSdkHostPlatform` | getter | `agentSdkPlatformFor` for the machine this Dart process runs on. |
| `agentSdkInLockfile` | function | The locked Agent SDK version and the platform suffixes a lockfile names, or null. |
| `spawnDeadlinesAreOrdered` | getter | Whether the spawn startup timeout is shorter than the test timeout (`agent_sdk_testing.dart`). |

### Agent Tools (`lib/agent_tools.dart`)

Summary: [api_summary_agent_tools.md](api_summary_agent_tools.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `AgentToolInvoke` | typedef | What a tool's body does once its arguments have been validated: it receives the context and the validated, narrowed argument map. |
| `AgentTool` | final class | A named, declared operation on behalf of an agent. |
| `AgentToolContext` | abstract class | What one invocation may reach and how its calls are recorded. |
| `AgentToolRegistry` | final class | A closed set of tools a presentation renders. |
| `AgentToolValueType` | enum | The value kinds a declared argument may take: the JSON type system, so the same schema renders as MCP's `inputSchema` and as a provider's native tool declaration. |
| `AgentToolArgument` | final class | One declared argument of a tool: name, kind, whether it is required, a description, and optionally the closed list of values it accepts. |
| `AgentToolSchema` | final class | A tool's declared argument set and the validation that runs before any tool body. |
| `AgentScope` | final class | What an invocation may touch: an optional id set, an optional kind set and whether writes are allowed. |
| `AgentScopeGate` | enum | The gate a guard denial names, with its position in the fixed order and the reason the audit trail records. |
| `AgentGuardTarget` | final class | One target a call reads or writes, or one it is about to create. |
| `AgentOrigin` | enum | Where an invocation came from. |
| `AgentExecutionGrant` | final class | The residual-risk statement an application shows a user before granting execution, as the value `AgentInvocation.withExecution` checks the shown text against. |
| `AgentInvocation` | final class | One entry into the tool surface, immutable once minted. |
| `AgentToolErrorCode` | final class | One refusal kind: its `E_…` wire spelling, the reason the audit trail records, and whether it reports a failure rather than a refusal. |
| `AgentToolException` | final class | A refused tool call, thrown from a tool's body. |
| `AgentAuditEntryPoint` | enum | Which surface a call arrived on. |
| `AgentAuditOutcome` | enum | What became of the operation an entry records. |
| `AgentAuditEntry` | final class | One audited operation. |
| `AgentAuditLog` | abstract class | The append-only audit log. |
| `AgentMemoryAuditLog` | final class | An audit log kept for the life of the process, for a build with nowhere to write and for tests. |
| `AgentAuditStore` | abstract interface class | The keyed file medium an `AgentFileAuditLog` keeps its files in, supplied by the application. |
| `AgentFileAuditLog` | final class | The audit log as a stream of files over an `AgentAuditStore`: one new JSON file per appended batch, filed under the UTC day it was written (`<yyyy-mm-dd>/<µs>-<instance>-<n>.json`), never a rewrite. |
| `AgentAuditExecution` | final class | What a program run reports to the tool call that started it, through `agentAuditExecution`. |
| `AgentAuditRecording` | final class | One tool call's audit entries, collected in the call's zone while it runs and appended to the context's log as one batch when it ends. |
| `AgentRunStep` | final class | One tool call made during a run, as the preview shows it and the run reports it. |
| `AgentToolResult` | final class | What a dispatched call hands back to the model. |
| `AgentToolBinding` | final class | The `{invocation, registry}` pair for one request plus the context its calls run against; a provider holds it for that request only. |
| `AgentInProcessMcpServer` | final class | An MCP server in-process: a JSON-RPC 2.0 message handler a caller invokes directly. |
| `AgentRunStatus` | enum | How an agent run ended. |
| `AgentRunOutcome` | final class | What `AgentRun.execute` reports, and what its `confirm` callback is shown as the preview. |
| `AgentRun` | abstract final class | One agent run: a model-driven sequence of tool calls kept or discarded as a unit, built on `AgentPreviewThenApply.run` over `AgentToolContext.runAtomically`. |
| `AgentProposalStatus` | enum | How a proposal ended. |
| `AgentProposalOutcome` | final class | What `AgentPreviewThenApply.run` reports. |
| `AgentAtomicScope` | typedef | Runs a body as one atomic unit, all of it rolled back together if it throws. |
| `AgentPreviewThenApply` | abstract final class | Preview-then-apply as one mechanism for every proposal. |
| `agentGuard` | function | `AgentScopeGate? agentGuard(AgentScope scope, AgentGuardTarget target, {required bool write})` |
| `agentFilterAudit` | function | `List<AgentAuditEntry> agentFilterAudit(Iterable<AgentAuditEntry> entries, {String? scopeId, String? locator, AgentAuditOutcome? outcome})` |
| `agentAuditExecutionStarted` | function | `void agentAuditExecutionStarted()` |
| `agentAuditResolved` | function | `void agentAuditResolved(String locator)` |
| `agentAuditExecution` | function | `void agentAuditExecution(AgentAuditExecution run)` |
| `agentAuditCallIsOneGroup` | function | `void agentAuditCallIsOneGroup()` |
| `agentAuditEntering` | function | `T agentAuditEntering<T>(AgentAuditEntryPoint entry, T Function() body)` |

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

### Mcp Auth (`lib/src/mcp_auth/`)

Summary: [api_summary_mcp_auth.md](api_summary_mcp_auth.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `bearerTokenMetaKey` | constant | The JSON-RPC `_meta` key a client places the bearer token under at `initialize`. |
| `bearerAuthRpcErrorCode` | constant | The JSON-RPC error code an MCP server returns when a `BearerAuthFailure` is raised during `initialize`. |

### Placeholders (`lib/src/placeholders/`)

Summary: [api_summary_placeholders.md](api_summary_placeholders.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `PlaceholderExpressionException` | final class | Raised when a `${{ … }}` expression throws or fails to parse during evaluation against the expression backing, or when a `${{ … }}` form is encountered by a resolver that has no expression backing (e.g. |
| `PlaceholderExpressions` | abstract interface class | Evaluates the `${{ … }}` placeholder form against a binding scope. |
| `PlaceholderResolver` | final class | Expands the four placeholder forms in a template, re-scanning after each pass until nothing resolvable remains. |
| `PlaceholderStack` | final class | Lexical, shadowing scope as a stack of binding frames, starting with one root frame. |
| `PlaceholderRecursionException` | final class | Raised when recursive placeholder expansion does not terminate within the resolver's level cap (default 10). |
| `PlaceholderUnresolvedException` | final class | Raised when an unknown `${name}` / `${env:NAME}` is encountered while the resolver runs in **strict** mode. |
| `isSimpleIdentifier` | function | Returns whether [name] is a bare Dart identifier. |

### Utilities (`lib/src/*.dart`, exported by `lib/tom_core_agentic.dart`)

Summary: [api_summary_utilities.md](api_summary_utilities.md)

| Type | Kind | Description |
| ---- | ---- | ----------- |
| `ShutdownAction` | typedef | The async teardown an `AsyncShutdownCoordinator` runs on the first trigger. |
| `ProcessTerminator` | typedef | Terminates the process with `code`. |
| `AsyncShutdownCoordinator` | final class | Watches trigger streams of type `S` (OS signals, supervisor messages, test stimuli) and runs an async teardown to completion before terminating the process. |
| `CategoryLog` | abstract base class | A category-tagged facade over the global `tomLog`. |
| `CloseGuard` | mixin | Owns a closed flag for an object that holds a resource: `ensureOpen` rejects use after close, and `markClosed` performs the transition once so the class's own `close()` can stay idempotent. |
| `DeadlineExceeded` | final class | `final class`, implements `Exception`. |
| `Deadline` | final class | A wall-clock expiry instant read against an injectable clock (default `systemClock`). |
| `DeliberationVerdict` | enum | Which execution branch a prompt's surface text points to, as `classifyDeliberationCue` decides it. |
| `HttpDate` | final class | Parser for the three date formats RFC 7231 § 7.1.1.1 permits in an HTTP-date header, using only core Dart so it compiles for the web. |
| `LatencySummary` | final class | An immutable summary of latency samples: count, min, max, p50 and p95. |
| `MapFieldErrorFactory` | typedef | Builds the exception a `MapFieldReader` throws: it receives the finished message and wraps it in the caller's own error type (for example `FormatException.new`). |
| `MapFieldReader` | final class | Type-safe accessors over a plain `Map<Object?, Object?>` whose values come from an untrusted boundary (decoded JSON, script input, hand-edited config). |
| `ScopedPath` | typedef | A root that admits a resolved path, paired with that path: `root` is the normalised absolute root, `path` the resolved, containment-checked absolute path under it. |
| `PathScope` | final class | A union of filesystem roots a path must stay within. |
| `PathScopeIo` | extension | `extension PathScopeIo on PathScope`, in `path_scope_io.dart`, which imports `dart:io` so the lexical `PathScope` stays web-safe. |
| `PlanStepOrdering` | final class | The outcome of `orderPlanSteps`. |
| `ProcedureRerankWeights` | final class | The relative weight of the four re-rank factors `scoreProcedureCandidate` combines. |
| `TokenBucketPolicy` | final class | The immutable configuration of a `TokenBucket`: a bucket holds at most `capacity` tokens and refills `refillTokens` every `refillPeriod`. |
| `TokenBucketSnapshot` | final class | An immutable snapshot of one key's bucket, the persistable form. |
| `TokenBucket` | final class | A keyed continuous-refill token bucket: one bucket per non-empty key, created full on first sight and kept for the instance's lifetime. |
| `ParsedToolCall` | final class | One tool call recovered from model text, normalised across dialects. |
| `TtlCache` | final class | An absolute-TTL cache: each entry expires a fixed `ttl` after it was written, however often it is read. |
| `YamlConfigErrorFactory` | typedef | Builds the exception a `YamlConfigReader` throws when a typed read or an `${env:NAME}` expansion fails; each loader wraps the message in its own exception class. |
| `YamlConfigReader` | final class | Type-safe accessors over a plain config map (the output of `loadYamlAsMap`, never a `YamlMap`), plus an environment-variable expander. |
| `YamlMapErrorFactory` | typedef | Builds the exception `loadYamlAsMap` throws when parsing or type-checking fails. |
| `requireNonEmpty` | function | Returns `value` when it is non-empty; otherwise throws `ArgumentError.value(value, name, 'must be non-empty')`. |
| `shutdownExitOk` | constant | Exit code of a clean shutdown. |
| `shutdownExitError` | constant | Exit code when the teardown threw (`EX_SOFTWARE`). |
| `mapEquals` | function | `true` when both maps have the same length, the same keys and `a[k] == b[k]` for every key. |
| `setEquals` | function | `true` when both sets have the same length and every element of `a` is in `b`. |
| `listEquals` | function | `true` when both lists have the same length and equal elements by position (`==`). |
| `deepValueEquals` | function | Deep equality for a scalar or an arbitrarily nested `List`: lists compare element by element recursively, two `null`s are equal, everything else uses `==`. |
| `deepValueHash` | function | Hash companion to `deepValueEquals`: `null` hashes to 0, a list hashes its elements recursively in order, anything else uses its own `hashCode`. |
| `startOfDay` | function | Midnight at the start of `t`'s calendar day, in `t`'s own zone (UTC or local). |
| `nextDayStart` | function | The start of the day after `t`'s day, in `t`'s zone; month and year rollover are normalised by `DateTime`. |
| `buildUniqueById` | function | Builds an unmodifiable `id → item` map. |
| `deliberationCues` | constant | The canonical cue phrases, lower-case: `think about`, `think through`, `reason about`, `work through`, `reflect on`, `mull over`, `ponder`, `research`, `deliberate`, `contemplate`. |
| `classifyDeliberationCue` | function | `DeliberationVerdict.thinking` when `text` contains any of `deliberationCues`, matched case-insensitively on word boundaries (so `research` does not match "researcher"); otherwise `DeliberationVerdict.normal`. |
| `formatException` | function | `'<runtimeType>: <message>'`, or `'<runtimeType>(<context>): <message>'` when `context` is given (an empty context renders as `()`). |
| `decodeJsonObject` | function | Decodes `json` into a fresh `Map<String, Object?>`. |
| `percentileDuration` | function | The nearest-rank percentile of an ascending list: rank `ceil(q · n)` (at least 1), the sample at `rank − 1`, clamped. |
| `nearestRankPercentile` | function | The same nearest-rank percentile over integer samples, with the same errors. |
| `orderPlanSteps` | function | Topologically orders the steps of `dependencies` (step id → ids it depends on) with Kahn's algorithm. |
| `scoreProcedureCandidate` | function | Clamps each factor to `[0, 1]` and returns their weight-normalised average, a score in `[0, 1]`. |
| `recencyDecay` | function | Exponential half-life decay of the age of the last successful run: `1.0` for an age of zero or less, `0.5` at one half-life, towards `0` after. |
| `promptSha256` | function | `'sha256:<lowercase-hex>'` of `body`, using `tom_basics`' `tomSha256OfText` (UTF-8 bytes). |
| `sqlPlaceholders` | function | `count` bind placeholders joined by `separator`, e.g. |
| `fnv1a32` | function | FNV-1a 32-bit hash over the low byte of each UTF-16 code unit. |
| `sqlSafeIdentifier` | function | Lower-cases `input`, replaces every character outside `[a-z0-9_]` with `_` and caps the result at `maxLength`. |
| `blobFromColumnOrNull` | function | `raw` as a `Uint8List` when it is one or a `List<int>`; otherwise `null`. |
| `blobFromColumn` | function | Like `blobFromColumnOrNull`, but throws `StateError('<context>: expected BLOB, got <type>')` for a non-blob. |
| `systemClock` | constant | The production wall-clock source, the default of every injectable `DateTime Function()` seam. |
| `textPreview` | function | `text` unchanged when it has at most `limit` characters; otherwise its first `limit` characters followed by `ellipsis`. |
| `approxCharsPerToken` | constant | Characters per token assumed by `estimateTokens`. |
| `estimateTokens` | function | `ceil(text.length / approxCharsPerToken)`; an empty string is zero tokens. |
| `parseToolCallsFromText` | function | Recovers every tool call in `text`. |
| `looksLikeToolCallAttempt` | function | Whether the trimmed `text` starts with `{`, `[` or a code fence, contains `<tool_call>`, `<\|tool_call>` or `[TOOL_CALLS]`, or contains a `call:NAME{` opening. |
| `loadYamlAsMap` | function | Parses one YAML document into plain `Map<String, Object?>` / `List<Object?>` / scalar values. |

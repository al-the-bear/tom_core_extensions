# tom_core_agentic

Generic, domain-free building blocks for agentic systems in the TOM
framework, safe to reuse across the brain, the assistant, Webwork and any
future agent runtime. The main barrel depends on `tom_basics`, `tom_llm`,
`tom_vscode_scripting_api` (for the editor bridge), `yaml` / `yaml_edit` (the
config read path and the agent YAML) and `path` (the `PathScope` sandbox). Two
further libraries live here: the Claude Agent SDK provider
(`agent_sdk.dart`) and the tool surface an LLM agent works through
(`agent_tools.dart`).

Cooperative cancellation (`TomCancellationToken`, `TomCancellationSource`,
`TomOperationCancelled`), the AST-preserving YAML config writer
(`TomYamlConfigWriter`) and the SHA-256 behind `promptSha256`
(`tomSha256OfText`) are `tom_basics`' (`package:tom_basics/utilities.dart`).
This package uses them and declares none of them; import them from there.


## Libraries

| Import | What it is |
| ------ | ---------- |
| `package:tom_core_agentic/tom_core_agentic.dart` | The building blocks below, the agent data models and the `tom_llm`-based helpers |
| `package:tom_core_agentic/agent_sdk.dart` | Anthropic's Claude Agent SDK as a `tom_llm` provider — see [Agent SDK provider](#agent-sdk-provider-agent_sdkdart) |
| `package:tom_core_agentic/agent_sdk_live_probe.dart` | The probe every live AI suite runs before a real completion |
| `package:tom_core_agentic/agent_sdk_testing.dart` | Test doubles for the Agent SDK transports |
| `package:tom_core_agentic/agent_tools.dart` | The tool surface an LLM agent works through — see [Agent tools](#agent-tools-agent_toolsdart); browser-safe |

## `dart:io` coupling

The package as a whole is **not** `dart:io`-free and does not claim to
be. This section is about the main barrel; `agent_sdk.dart` spawns processes
by purpose, and `agent_tools.dart` is `dart:io`-free as a whole. 15 files of the main library import `dart:io`, and 5 of the 34 barrel
exports reach one of them — directly or transitively:

| Coupled barrel export | Reaches | Through |
|-----------------------|--------:|---------|
| `src/agent/agent.dart` | 13 | nine file-backed stores, `agent_send.dart`, `agent_sidecar.dart`, `bridge_connection.dart`, and `placeholder_resolver.dart` through the editor placeholder bindings |
| `src/llm/llm.dart` | 1 | `agent_sdk_session.dart` (subprocess transport) |
| `src/path_scope_io.dart` | 1 | itself — it *is* the `dart:io` half of `PathScope`, by design |
| `src/placeholders/placeholders.dart` | 1 | `placeholder_resolver.dart` (`Platform.environment` default) |
| `src/yaml_config_reader.dart` | 1 | `placeholder_resolver.dart`, via `${…}` expansion |

Every figure above is derived by `test/dart_io_coupling_test.dart`, which
reads this section and fails when a number here stops matching the import
graph. The counts were prose once and went stale the first time a module
gained an import.

The remaining **29 exports are `dart:io`-free**, and that subset is what
makes the package usable from `dart:io`-forbidding consumers. The one in
the tree today, `tom_brain_shared`, uses seven symbols
(`requireNonEmpty`, `textPreview`, and the five `collection_equality`
helpers), all of which live in that subset.

**The failure mode is a runtime one, not a build one.** On the current
SDK `dart compile js` does not reject `dart:io`: it compiles, stubs the
library, and throws `UnsupportedError` when a stubbed member is actually
reached. A web consumer can therefore import the barrel — even `show` a
symbol from a coupled export — and only discover the problem when the
coupled code path runs. That is precisely why the split above is pinned
by `test/dart_io_coupling_test.dart` rather than by prose: the compiler
will not catch a regression here, so a test has to.

`PlaceholderResolver` is the one coupling that is incidental rather than
inherent — it needs `dart:io` only to default `environment` to
`Platform.environment`. Passing an explicit `environment:` map avoids
touching the stub at runtime, which every config-layer call site and
every test already does. Removing the import outright is deferred rather than
planned — it would also un-couple `yaml_config_reader.dart`, which reaches
`dart:io` solely through this one import, so the change is worth more than it
looks and is still not urgent.

## What lives here

| Building block | Purpose |
|----------------|---------|
| `CloseGuard` | Mixin that tracks a `isClosed` flag and throws on use-after-close. |
| `buildUniqueById` | Build an id-keyed map from a list, rejecting duplicate ids. |
| `textPreview` | Single-line, length-bounded preview of arbitrary text. |
| `HttpDate` | RFC 7231 / RFC 1123 HTTP-date parsing and formatting. |
| `CategoryLog` | Category-tag facade over the global `tomLog` (prepends `[category]`, forwards every level). |
| `systemClock` | The `DateTime.now` default for injectable `DateTime Function()` clock seams. |
| `AsyncShutdownCoordinator<S>` | Signal → awaited async teardown → terminate; `dart:io`-free, generic over the trigger type. |
| `loadYamlAsMap` / `expandEnvVars` | YAML → plain `Map<String, Object?>` parse boundary, plus `${ENV}` expansion. |
| `YamlConfigReader` / `MapFieldReader` | Typed, dotted-path reads over **plain** config maps (no `YamlMap` in the read path). |
| `percentileDuration` / `LatencySummary` | Nearest-rank percentile maths and a count/min/max/p50/p95 summary over `Duration` samples. |

## Integration with `tom_basics` / `tom_core_*` (reuse vs own)

This package sits in the **lightweight tier**: it depends only on
`tom_basics` and never on `tom_core_kernel` (which pulls `dart:io`,
`tom_reflection`, `http`, and a SQL client). The table below records,
per audited concern, whether the primitive is **reused** from
`tom_basics` or **owned** here — and, where a heavier `tom_core_*`
analogue exists, why it is not reused.

| Concern | Disposition | Detail |
|---------|-------------|--------|
| **Logging** | **Reuse** `tom_basics` | `CategoryLog` and `AsyncShutdownCoordinator` forward to the global `tomLog` (`TomLogger` / `TomLogLevel`). No second logger is implemented. `CategoryLog` is a forwarding facade, not a re-implementation. |
| **Clock** | **Own** (no equivalent) | Neither `tom_basics` nor `tom_core_kernel` ships a clock. `systemClock` is the one-line `DateTime.now` tear-off used as the default for injectable clock seams. |
| **Shutdown** | **Own by tier-design** | `tom_core_kernel` ships `TomShutdownCleanup`, but it imports `dart:io` (`ProcessSignal`) and `tom_reflection/mirrors`, so it lives in the heavy kernel tier. `AsyncShutdownCoordinator` is the `dart:io`-free, async-await-correct, trigger-generic coordinator the lightweight tier needs. Depending on the kernel to share it would drag `dart:io` + reflection into `tom_brain_shared`; the bounded duplication is intentional. |
| **Cancellation** | **Reuse** `tom_basics` | `TomCancellationToken` / `TomCancellationSource` / `TomOperationCancelled` from `package:tom_basics/utilities.dart`; `agent_send.dart` takes the token. |
| **Content hash** | **Reuse** `tom_basics` | `promptSha256` is `'sha256:'` + `tomSha256OfText`. |
| **Config read** | **Own** (no equivalent) | No YAML config loader/reader exists in `tom_basics` or `tom_core_kernel`. `loadYamlAsMap` + `YamlConfigReader`/`MapFieldReader` own the read path (plain maps, no `YamlMap` leak). |
| **Config write** | **Reuse** `tom_basics` | `TomYamlConfigWriter` is the AST-preserving writer (surgical `set`/`remove` over `yaml_edit`). |

**Audit result:** no divergent re-implementation
of a `tom_core_kernel`-owned primitive was found. Logging, cancellation,
the content hash and the config writer are reused from `tom_basics`;
the clock and the config reader have no `tom_core_*` equivalent; the shutdown
coordinator is a deliberate lightweight-tier alternative to the kernel's
`dart:io`-coupled `TomShutdownCleanup`. The audited helpers
(`CategoryLog`, `systemClock`, `AsyncShutdownCoordinator`,
`YamlConfigReader`/`MapFieldReader`) keep their
existing unit tests.

## Module documentation

One prose page per module with a surface worth explaining, under
[`doc/`](doc/):

| Page | Covers |
| ---- | ------ |
| [`doc/agent_sdk.md`](doc/agent_sdk.md) | The Agent SDK provider module (`agent_sdk.dart`): what it holds, where the README describes it, and its dependencies |
| [`doc/agent_tools.md`](doc/agent_tools.md) | The agent tool module (`agent_tools.dart`): what it holds, where the README describes it, and its dependencies |
| [`doc/agent.md`](doc/agent.md) | The editor-facing agent session: the eleven YAML sidecars and how a damaged one degrades, bridge discovery and binding, the reconnect back-off, and the send engine's retry and cancellation rules |
| [`doc/api/api_summary_agent.md`](doc/api/api_summary_agent.md) | The symbol-level mirror of the same unit: every exported type, top-level function and constant with a section, held complete by `test/api_summary_test.dart` |
| [`doc/bearer_auth.md`](doc/bearer_auth.md) | The transport-neutral bearer-token contract and its three failure reasons |
| [`doc/mcp_auth.md`](doc/mcp_auth.md) | The MCP-specific `_meta` slot and JSON-RPC refusal code over that contract |
| [`doc/llm.md`](doc/llm.md) | The Agent SDK provider over the `tom_llm` contract: its control inversion and single retry, and the three session strategies |
| [`doc/api/api_summary_llm.md`](doc/api/api_summary_llm.md) | The symbol-level mirror of the same unit: six types with a section each and the session-error matcher |
| [`doc/isolate_streaming.md`](doc/isolate_streaming.md) | Streaming results back across an isolate boundary |
| [`doc/api/api_summary_isolate_streaming.md`](doc/api/api_summary_isolate_streaming.md) | The symbol-level mirror of the same unit: twelve types with a section each, and which side of the boundary each lives on |
| [`doc/placeholders.md`](doc/placeholders.md) | The placeholder engine: forms, scope stack, recursion and typed failures |
| [`doc/api/api_summary_placeholders.md`](doc/api/api_summary_placeholders.md) | The symbol-level mirror of the same unit: six types, one function and three constants with a section each, and the wire codes each failure carries |
| [`doc/api/api_summary_index.md`](doc/api/api_summary_index.md) | Which units get a symbol-level summary and which are mirrored by their prose page instead — the ten-type threshold, and the six units measured against it |

## Runnable examples

Six programs under [`example/`](example/), one per module that has a surface
worth driving directly:

| Example | Demonstrates |
| ------- | ------------ |
| [`example/llm/`](example/llm/llm_example.dart) | The provider seam from the implementer's side: a complete `EchoProvider`, the event contract and the route stamp asserted under a model override, and the two shapes one failure takes through `complete` and `run` |
| [`example/agent/`](example/agent/agent_example.dart) | The agent unit end to end without a network: a sidecar round-trip and its two degradation rules, bridge discovery and endpoint matching, the reconnect back-off resolving all three ways, and a send that refreshes a stale session |
| [`example/placeholders/`](example/placeholders/placeholders_example.dart) | The placeholder forms, both entry points, the lexical scope stack, transitive recursion and the typed failures |
| [`example/lifecycle_guards/`](example/lifecycle_guards/lifecycle_guards_example.dart) | Cooperative cancellation and the close-guard family |
| [`example/isolate_streaming/`](example/isolate_streaming/isolate_streaming_example.dart) | Streaming results back across an isolate boundary |
| [`example/mcp_auth/`](example/mcp_auth/mcp_auth_example.dart) | Bearer-token verification and the principal it resolves |

**Run them with the flag their headers name:**

```bash
dart run --enable-asserts example/placeholders/placeholders_example.dart
```

`--enable-asserts` is not optional. Each example states its expectations with
`assert`, and `dart run` leaves assertions *disabled* — that is what the flag is
for — so under a flagless run every expectation would compile out and the
example would print its transcript and exit 0 having verified nothing. It
refuses instead: each example opens by checking that asserts are on, and exits
with status 2 and the corrected command if they are not.

`test/examples_test.dart` holds all three parts: it runs every example under
exactly the command its header names, it requires every header to name that
command — a sweep that passes a flag the header omits proves nothing about what
a reader will see — and it requires every example to refuse a flagless run.
(`tom_core_server` answers the same question the other way, with a helper that
throws instead of asserting; either is sound, and documenting one while
verifying the other is not. `tom_core_kernel`'s samples refuse a flagless run
the same way these do.)

The two libraries with an `## Example` section carry its compiled form as
[`example/agent_sdk/readme.dart`](example/agent_sdk/readme.dart) and
[`example/agent_tools/readme.dart`](example/agent_tools/readme.dart). They
are held by their own `readme_example_test.dart` rather than by the sweep
above, because the Agent SDK one streams a real completion when an AI backend
is reachable.

## What does NOT live here

Anything brain- or domain-specific. The `sha256:<hex>` prompt-hash
convention and the `BrainEventBus<E>` live in `tom_brain_shared`;
retry / circuit-breaker transport policy lives in `tom_core_kernel`.

## Agent SDK provider (`agent_sdk.dart`)

Anthropic's Claude Agent SDK as a `tom_llm` provider: one transport seam
with two implementations — a running VS Code window's CLI server, and a
standalone Node server the app starts and owns — the SDK's messages translated
into run events, a liveness bound every run passes, sessions that each run in
an isolate of their own, an availability gate that says why it is shut, and an
on-demand install of the server's npm dependencies. The app hands it requests
and, for an agent run, the tools the model may call; it holds no HTTP client
and no credential store.

### Overview

- **`AgentSdkSessionProvider`** is the `LlmProvider`. Every request runs in a
  session; the run streams the events of `tom_llm` — the request's
  prelude, the far end's start, thinking and text as they stream, each tool
  call with its result, retries, usage and exactly one end — and the end of a
  completed run carries its `LlmCallReport`, kept by an `LlmRunAccount` from the
  run's own events. It sends a request's two channels as they are: the
  instruction (user channel) followed by the context (system channel).
  `agentToolsEnabled` is a switch read on every request: while it answers
  false the provider reports `canUseTools: false` and refuses a request that
  carries tools, before anything is sent.
- **`AgentSdkServerTransport`** is the seam, and it names nothing about VS
  Code, Node, sockets or processes: send a composed prompt, stream the run's
  events back, report failures as `LlmTransportException` with a kind, cancel
  by cancelling the subscription, and probe reachability without side effects.
  - **`HostedCliServerAiTransport`** reaches a running VS Code's CLI server: one
    scan of ports 19900–19909, an identity handshake (`workspace.getInfoVce`)
    and a local match against an optional workspace pin. Two windows with the
    same workspace answer identically, so a pin selects a workspace, not a
    window; the choice is the lowest port, and it is reported through
    `selectionNotice` rather than made silently. `discoverHostedAiWorkspaces`
    returns the same scan as `AgentSdkWorkspaceCandidate`s, so a settings
    surface can offer the identities that answer rather than ask for one to be
    typed.
  - **`StandaloneNodeAiTransport`** starts `node/agent_sdk_server.js` on a Node
    at or above a version floor (currently 20) and speaks the same wire to it.
    The floor is enforced rather than mere resolvability, because the Agent SDK
    starts the Claude Code CLI as a grandchild that inherits the interpreter:
    an older Node would probe as available and then fail with an unreadable
    child error. It tells its own `close()` from a crash, so a connect still
    waiting for the ready line reports that the transport was closed, not that
    the server exited with code -15. A server that dies before it is ready is
    reported with its last stderr lines, waited for up to `stderrDrainBound`
    (2 s), because the exit code and those lines arrive on different pipes.
- **`CliServerAiChannel`** is the wire both transports hold. Every SDK message
  goes through an `SdkTrailTranslator` into the run event it means; text and
  thinking arrive twice — as partial deltas and again in the assembled message
  — and are emitted once, from the deltas, so a trail is live. Anything that
  carries no event is liveness. A credential rejection — a `system/api_retry`
  carrying a 401, or an `authentication_failed` assistant message — fails the
  run as `remote` at once and cancels the query. The query asks for partial
  messages and adaptive, summarized thinking: without partial messages a
  thinking model is silent until it has finished, and the liveness bound would
  cap model latency instead of detecting a dead far end.
- **`boundedAiRun`** is the liveness bound, applied by the provider over
  whatever stream a transport returns, so no transport can escape it. A run
  that hears nothing — no event, no liveness — for `defaultAiStallTimeout`
  (120 s) ends as a stall, an error and a `timeout`, and its transport stream is
  cancelled. It is a **gap**, not a budget: every event resets it, so a long
  completion is never cut off. A stall leaves the availability gate open,
  because the server is up and answering. The figure is ten times the largest
  silence a long thinking completion was measured to contain; re-measure it
  with `test/agent_sdk/stall_gap_measure_live_test.dart` whenever the SDK, the model or a
  transport changes.
- **`AgentSdkTransportSelector`** owns the availability gate. It probes the
  transports in preference order; `initialize()` never throws, because "nothing
  reachable" is the ordinary offline case. `isAvailable` is a field read, and
  `unavailableReason` is a sentence that names the remedy — no CLI server
  listening (and the command that starts one), the server not installed, no
  Node at or above the floor (and where the search looked). `notices` emits
  once per unavailability episode; the reason stays current for as long as the
  gate is shut. A selector with no transports says the AI is not configured.
  Every place this package raises `unreachable` says what to fix, and
  `test/agent_sdk/unreachable_messages_test.dart` holds each site to it.
- **`AgentSdkServerInstaller`** installs the server's dependencies on the
  user's request; see [Installing the server](#installing-the-server).

The far end owns the Anthropic credential on both paths: the hosted path never
sees one, and the standalone path hands a given key straight into its child's
environment. Capabilities are static per transport; `canEmbed` is false.

### Entry points

`package:tom_core_agentic/agent_sdk.dart` is the provider and its transports;
`agent_sdk_live_probe.dart` is the probe live suites run first, and
`agent_sdk_testing.dart` the test doubles. A product build links neither of
the last two.

### Features

| Type | What it does |
| ---- | ------------ |
| `AgentSdkSessionProvider` | The `LlmProvider`: runs every request in a session over the selected transport. |
| `AgentSdkServerTransport`, `AgentSdkInstallableTransport` | The transport seam; a transport whose server the user installs. |
| `HostedCliServerAiTransport`, `discoverHostedAiWorkspaces`, `AgentSdkWorkspaceCandidate` | A running VS Code's CLI server; the windows that answer a scan. |
| `StandaloneNodeAiTransport`, `agentSdkChildEnvironment` | A Node server the app starts and owns; the environment its child gets. |
| `AgentSdkCompletionRequest`, `AgentSdkToolSet`, `AgentSdkCompletionEvent` | What a transport is handed and what it streams back. |
| `CliServerAiChannel`, `agentSdkMcpToolName` | The wire both transports hold; how a relayed tool is named to the model. |
| `boundedAiRun`, `defaultAiStallTimeout` | The liveness bound. |
| `AgentSdkTransportSelector`, `AgentSdkNotice`, `AgentSdkUnavailableKind` | The availability gate and what it says. |
| `AgentSdkSessionManager`, `AgentSdkSessionHosting` | Sessions, each in an isolate of its own. |
| `AgentSdkServerInstaller`, `stageAgentSdkServer`, `verifyAgentSdkPayloadFor` | Installing the server's dependencies; staging and verifying a build's payload. |
| `probeAgentSdkModel` (`agent_sdk_live_probe.dart`) | Whether a model answers behind a transport, for live suites. |
| `FakeAiServer`, `agentSdkFixtureScript` (`agent_sdk_testing.dart`) | A fake CLI server and spawnable fixture servers, for suites with no model. |

### Example

```dart
import 'dart:io';

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/io.dart';

Future<void> main() async {
  const request = LlmRequest(
    prompt: WirePrompt(
      system: 'The formula engine now recalculates transitively.',
      user: 'Summarize this in five words.',
      anchorHash: '',
      roleId: 'summarize',
    ),
  );
  print(request.prompt.combined);
  // The formula engine now recalculates transitively.
  //
  // Summarize this in five words.

  final selector = AgentSdkTransportSelector([
    HostedCliServerAiTransport(), // a running VS Code
    StandaloneNodeAiTransport(
      node: llmNodeResolverFor(), // PATH, nvm, Homebrew, /usr/local
      apiKey: Platform.environment['ANTHROPIC_API_KEY'],
    ), // our own Node process
  ]);
  await selector.initialize(); // never throws
  // Every run is served from a session in its own isolate.
  final sessions = AgentSdkSessionManager();
  final provider = AgentSdkSessionProvider(
    selector: selector,
    sessions: sessions,
    toolServerName: 'tools',
  );

  if (provider.isAvailable) {
    await for (final delta in llmAnswerText(provider.run(request))) {
      stdout.write(delta);
    }
  } else {
    // The ordinary offline case: the app stays usable, AI gated off.
    print('AI unavailable');
  }
  await sessions.dispose();
  await selector.dispose();
}
```

The compiled form is [`example/agent_sdk/readme.dart`](example/agent_sdk/readme.dart),
and `test/agent_sdk/readme_example_test.dart` asserts what it prints.

### Sessions

`AgentSdkSessionProvider` runs every request in a session, and every session
in an isolate of its own, through an `AgentSdkSessionManager` the application
builds once and disposes before the transport selector. The isolate holds the
transport's connection, the request loop and the liveness bound, and is kept
between runs; two sessions run at once, and a death, a hang or a cancel in one
leaves the other running.

- **What crosses.** A transport cannot be sent to an isolate, so each answers
  `sessionCopy`: a function over primitives that builds a copy of it there. The
  hosted copy reuses the port the selector found; the standalone copy starts
  its own Node child, because the server accepts one client.
- **One run per session.** A second run in a busy session throws
  `LlmSessionBusyException` at once, and is never queued.
- **Cancel.** The caller's stream ends with a cancelled run at once. A session
  that has not acknowledged within `cancelGrace` (2 s) is killed, and the next
  run spawns a new one.
- **Tool calls run in the main isolate**, through the request's
  `LlmToolBinding`, against whatever state the application owns there.
- **Logs.** `ai.run.started`, `ai.run.ended` and `ai.session.failed`, none
  carrying text.

`AgentSdkSessionHosting.inProcess` runs the same worker in the main isolate,
for a stand-in whose state a copy in another isolate could not share.

### Tools

When a request carries a `toolBinding`, the provider hands the transport an
`AgentSdkToolSet` — the binding's declarations and a function that answers a
call with text — declared on the in-process MCP server the provider was given
as `toolServerName`, so the model sees `mcp__<toolServerName>__<tool>`. The
server crosses the wire as a descriptor and the far end rebuilds it (the VS
Code extension's bridge, or `node/agent_sdk_server.js`). Each call comes back
over the same connection as `agentSdk.toolCall {streamId, server, tool, args}`
and is answered from the binding; a refusal is an answer with
`isError: true`. No socket, port or pipe is added.

Such a query has the SDK's own tools off, `allowedTools` exactly the relayed
tools, `strictMcpConfig` so no MCP server from the far end's settings is
reachable, and `maxTurns: agentRunMaxTurns` (24) instead of a plain
completion's 1. A provider whose transport reports `canUseTools: false` and is
handed a binding anyway refuses it before anything is sent.

### Installing the server

The standalone transport runs a small Node.js server,
`node/agent_sdk_server.js`, this package's own code under BSD-3-Clause. It
runs on **Anthropic's Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`),
which is **proprietary software** (© Anthropic PBC, usable under Anthropic's
terms, <https://code.claude.com/docs/en/legal-and-compliance>), so an
application built on this package does not ship it. A build carries only the
server's three source files (`agent_sdk_server.js`, `package.json`,
`package-lock.json`) in `<app-executable-dir>/ai/` and **no `node_modules`**,
and the user installs the SDK from the app when they decide to use AI.

**What an install does.** When AI is unavailable because the server is not
installed, the transport's kind is `notInstalled` and the application offers
an install. `AgentSdkServerInstaller`:

1. checks that Node.js **20 or newer** is available — the same search and the
   same check the gate uses, so without one no install is offered;
2. reads the shipped `package-lock.json` and checks that the locked SDK version
   ships a Claude Code CLI for that Node's platform (`darwin-arm64`,
   `win32-x64`, …) — on Windows on ARM with an SDK that has no `win32-arm64`
   build, it refuses and says to use the x64 Node.js;
3. runs `npm ci --omit=dev` with that Node's own npm into a staging folder
   beside `<app-data>/ai/`, downloading the SDK, its native CLI for the
   platform (~220 MB) and their dependencies;
4. checks the installed tree (the SDK's entry point and peers, the CLI binary
   and its executable bit) and only then moves it to `<app-data>/ai/`. A
   failed install leaves the previous state untouched and reports npm's last
   lines.

When an application update moves the locked SDK version, the install reports
as outdated and installing again updates it. Removing it is deleting
`<app-data>/ai/`.

**Which Node.js.** The transport never spawns the bare name `node`: an app
started from a launcher has a minimal `PATH`. It runs `tom_llm`'s Node
search (`llmDiscoverNode`) — every `PATH` entry, then nvm's versions newest
first, then Homebrew and `/usr/local` — and takes the first at or above the
floor by version. A path the user sets (`llmNodeAt`) replaces the search.

**From a terminal:**

```bash
dart run tom_core_agentic:install_agent_sdk_server --app-data <dir> [--node <node>]
```

**Developers** can skip all of it: `npm ci --omit=dev` in this package's
`node/`, then point `AGENT_SDK_SERVER_SCRIPT` at `node/agent_sdk_server.js`, or
run from a checkout, where the transport finds the script itself.

**A key handed to the standalone transport is the only credential its server
can use.** With `apiKey` given, the child starts without any of the app's
`ANTHROPIC_*` or `CLAUDE*` variables and with `CLAUDE_CONFIG_DIR` pointing at
an empty directory of its own, so the machine's Claude Code login cannot
answer in place of the key. With no key the child inherits the app's
environment, and the ambient login answers. `scrubbedVariables` names any
further variable of the app's own — a session token it was launched with —
that the child, a tool-running process, must not inherit.

### Live suites

`package:tom_core_agentic/agent_sdk_live_probe.dart` (`probeAgentSdkModel`) runs one
tiny completion with a 30 s bound before a live suite spends minutes on real
ones: a model answering runs the suite, a transport that connects with no model
behind it **skips** it with a sentence naming the credential, and an
unreachable transport **fails**.

- `AGENT_SDK_LIVE_HOSTED=1`, with VS Code running **and its CLI server
  started** (the "Start CLI Server" command, `tomAi.cliServer.start`; its
  autostart is off by default). `AGENT_SDK_LIVE_WORKSPACE` optionally pins the
  identity the server reports.
- `AGENT_SDK_LIVE=1`, with the server installed (`npm ci` in `node/`). No
  `ANTHROPIC_API_KEY` is required: the SDK falls back to the ambient Claude
  Code login.
- `AGENT_SDK_RECORD=1` beside either re-records
  `test/fixtures/sdk_messages/<transport>_agent_run.json` through
  `test/agent_sdk/event_stream_live_test.dart`. `tool/write_trail_replay.dart` turns a
  recording into the run events a UI test's stand-in transport replays.
- `AGENT_SDK_LIVE_MEASURE=1` runs the stall-gap measurement (~170k input
  tokens per transport).

### Deadlines in tests that spawn a child

A test that starts a server child is bounded twice: by the transport's
`startupTimeout` and by the harness. The harness timer starts earlier — it
covers `setUp`, the fixture server's own bind and the `node --version` runs
before the child is spawned — so equal bounds mean the harness always wins,
abandoning the body mid-connect with a live child. The rule is
`harness >= 2 × startup`: a spawning test declares a library-level `@Timeout`
of at least twice `spawnStartupTimeout` (30 s), exported with the other
deadlines from `agent_sdk_testing.dart`.

### Limits

- **Two transports, one model family.** Both reach Anthropic models through the
  Agent SDK; a provider for another API is a different `LlmProvider`.
- **No embeddings.** `canEmbed` is false on both transports.
- **Closing a channel waits at most two seconds** (`CliServerAiChannel.closeBound`):
  a socket's close completes in the zone it was last written in, which may never
  run again, and the standalone transport kills its child only after the channel
  closes.

### Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `tom_llm` | runtime | the provider contract, the run events, the run account, sessions and the Node search |
| `tom_vscode_scripting_api` | runtime | the CLI-server wire, the port scan and the Agent SDK message mirror |
| `tom_basics` | runtime | the diagnostics port the session manager logs through |
| `meta` | runtime | `@visibleForTesting` |
| `test`, `lints` | dev | the suite |
| `@anthropic-ai/claude-agent-sdk` | npm, installed by the user | the server's runtime (proprietary, not shipped) |

### Status

`dart test test/agent_sdk` runs the offline suite — the transport contract
over a fake CLI server and spawned stand-in servers, the translator over real
recordings of both transports, the liveness bound, sessions in isolates,
degradation and the availability gate's sentences, the install and payload
checks, and the example — and the live suites run behind the variables above.

## Agent tools (`agent_tools.dart`)

The tool surface an LLM agent works through: tools with declared arguments,
validated before a body runs; one registry presented to a model as native tool
declarations or through an in-process MCP server; a permission scope every
target passes in a fixed gate order; an invocation record that carries
execution consent; an append-only audit trail of every call; and
preview-then-apply runs that keep or discard an agent's work as one unit. An
application supplies its tools, its context — what a call reaches and how its
writes are rolled back — and nothing else.

### Overview

- **A tool** (`AgentTool`) is a name, a summary, an argument schema, a prose
  result, and a body. It declares whether it writes (`isWrite`) and whether it
  runs a program (`needsExecution`). The body is private: the only way to run
  a tool is `call`, which validates the arguments, records the call in the
  audit trail and runs the body with its declaration in force. A call refused
  by validation, by a gate or by its own body is recorded exactly as an
  applied one is.
- **The registry** (`AgentToolRegistry`) is what a presentation renders.
  `where` derives a narrower set and can only remove, so a set offered to a
  program — the registry less every tool that `needsExecution` — follows the
  declarations rather than a second list, and an agent → program → agent call
  graph stays bounded. An application keeps its surface closed by
  constructing its registry once and deriving every other set from it.
- **The scope and the guard** (`AgentScope`, `agentGuard`) decide every
  target of every call in one order: (1) exclusion — a target the application
  keeps out of the surface, asked before any grant; (2) the write gate; (3)
  the kind gate; (4) the id gate, through which a target being created is
  admitted by its parent; (5) allow. A refusal names the gate in the audit
  trail; an excluded target is "not found" to the caller, so the surface is
  not an existence oracle.
- **The invocation** (`AgentInvocation`) is immutable and minted per user act.
  Execution consent exists only on it, and the one factory that grants it
  takes the application's residual-risk statement (`AgentExecutionGrant`) as
  proof it was shown. Its origin is a closed set of one, `local-agent`.
- **The audit trail** (`AgentAuditLog`) is append-only, synchronous to append
  and persisted in order. An entry holds operations, ids, digests, sizes and
  reasons and has no field that could hold content, a program's source or
  output, or a credential. `AgentFileAuditLog` keeps one file per appended
  batch, filed by UTC day, over any `AgentAuditStore`; retention deletes whole
  days. An application reports its writes to the running call through
  `AgentToolContext.callZoneValues` and `AgentAuditRecording.recordMutation`,
  and a program run through `agentAuditExecution`.
- **The presentations** (`AgentToolBinding`, `AgentInProcessMcpServer`) are
  generated from the registry on every call and dispatch back into it. The
  binding is the `LlmToolBinding` of `tom_llm` a tool-capable provider
  receives per request; the MCP server is a JSON-RPC handler a caller invokes
  directly — no port, socket or pipe. A refusal is an answer the model sees;
  once a call of a run fails, every later call is refused rather than
  performed; a defect answers "the call failed" and nothing of its text.
- **Runs** (`AgentRun`, `AgentPreviewThenApply`) keep an agent's work whole.
  A run is a proposal: the calls write inside `AgentToolContext.runAtomically`
  while the model works, a refused call rolls the run back without asking,
  and the user's decision keeps it or rolls it back. The preview carries a dry
  run of the calls against `dryRunCopy`, replaying ids the run created and
  leaving program steps unsimulated. The audit entries are staged and
  committed once the run's fate is known, rolled-back ones marked so.

### Entry point

`package:tom_core_agentic/agent_tools.dart`. Its import closure reaches no
`dart:io`, no Flutter and no package but `meta` and `tom_llm`, so it links
into a browser build; `test/agent_tools/package_shape_test.dart` holds that.

### Features

| Type | What it does |
| ---- | ------------ |
| `AgentTool`, `AgentToolSchema`, `AgentToolArgument`, `AgentToolValueType` | A declared tool and the arguments it validates. |
| `AgentToolErrorCode`, `AgentToolException` | The refusals a call can end in; an application adds codes of its own. |
| `AgentToolContext` | What a call runs against: the invocation, the audit log, the guard, and the transaction hooks an application implements. |
| `AgentToolRegistry` | A set of tools, invoked by name, narrowed by `where`. |
| `AgentScope`, `AgentScopeGate`, `AgentGuardTarget`, `agentGuard` | The scope and the five-gate guard. |
| `AgentInvocation`, `AgentExecutionGrant`, `AgentOrigin` | The invocation record and the consent it carries. |
| `AgentAuditEntry`, `AgentAuditLog`, `AgentMemoryAuditLog`, `AgentFileAuditLog`, `AgentAuditStore`, `agentFilterAudit` | The audit trail and where it is kept. |
| `AgentAuditRecording`, `agentAuditExecution`, `agentAuditResolved`, `agentAuditCallIsOneGroup`, `agentAuditEntering` | The per-call recording and what an application reports to it. |
| `AgentToolBinding`, `AgentToolResult`, `AgentInProcessMcpServer` | The presentations a provider and an MCP client see. |
| `AgentRun`, `AgentRunStep`, `AgentRunOutcome`, `AgentRunStatus` | An agent run, its steps, and its dry run. |
| `AgentPreviewThenApply`, `AgentProposalOutcome`, `AgentProposalStatus`, `AgentAtomicScope` | Preview-then-apply for any proposal. |

### Example

```dart
import 'dart:convert';

import 'package:tom_core_agentic/agent_tools.dart';

/// What the tools reach: notes by id, one kept out of the agent's view.
final notes = {'n1': 'Buy milk', 'n2': 'Call Ada', 'vault': 'pin 1234'};

/// The context a call runs against: the guard, and an atomic scope.
class NotesContext extends AgentToolContext {
  NotesContext(AgentInvocation invocation)
    : super(invocation: invocation, audit: AgentMemoryAuditLog());

  @override
  List<String> get auditTargetKeys => const ['noteId'];

  /// The note [id], once the guard admits it; the vault is never admitted.
  String admit(String id) {
    final text = notes[id];
    final gate = guard(
      AgentGuardTarget(id: id, kind: 'note', excluded: id == 'vault'),
    );
    if (text == null || gate == AgentScopeGate.excluded) {
      throw const AgentToolException(
        AgentToolErrorCode.notFound,
        'No such note.',
      );
    }
    if (gate != null) {
      throw AgentToolException(
        AgentToolErrorCode.readOnly,
        'Refused.',
        gate: gate,
      );
    }
    return text;
  }

  @override
  Future<T> runAtomically<T>(String label, Future<T> Function() body) => body();

  @override
  NotesContext dryRunCopy() => NotesContext(invocation);
}

final tools = AgentToolRegistry<NotesContext>([
  AgentTool(
    name: 'read_note',
    summary: 'Read one note.',
    result: '{text}',
    arguments: const AgentToolSchema([
      AgentToolArgument('noteId', AgentToolValueType.string, required: true),
    ]),
    invoke: (context, arguments) => {
      'text': context.admit(arguments['noteId']! as String),
    },
  ),
]);

Future<void> main() async {
  final context = NotesContext(
    AgentInvocation.mint(scope: AgentScope(allowWrite: false)),
  );
  final binding = AgentToolBinding(context: context, registry: tools);

  // What a provider declares to the model.
  print(binding.declarations.single.name); // read_note

  // What the model's calls answer — a refusal is an answer too.
  print((await binding.call('read_note', {'noteId': 'n1'})).text);
  // {"text":"Buy milk"}
  print((await binding.call('read_note', {'noteId': 'vault'})).text);
  // {"code":"E_NOT_FOUND","message":"No such note."}

  // The same registry over MCP, in-process.
  final server = AgentInProcessMcpServer(binding, serverName: 'notes');
  final listed = await server.handle({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'tools/list',
  });
  print(jsonEncode((listed!['result']! as Map)['tools'].length)); // 1

  // Every call is in the audit trail; the vault's text is not.
  for (final entry in context.audit.entries) {
    print('${entry.toolName} ${entry.targetId} ${entry.outcome.wire}');
  }
  // read_note n1 applied
  // read_note vault denied
}
```

The compiled form of this section is
[`example/agent_tools/readme.dart`](example/agent_tools/readme.dart), and
`test/agent_tools/readme_example_test.dart` asserts what it prints.

### Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `tom_llm` | runtime | `LlmToolBinding`, the per-request binding a provider receives |
| `meta` | runtime | `@visibleForTesting` |
| `test`, `lints` | dev | the suite |

### Status

`dart test test/agent_tools` runs the suite: the schema, the guard's order,
the invocation's consent, a call's recording, the registry, the audit log and
its file store, the binding, the MCP server, runs and their dry run,
preview-then-apply, the package's shape, and the example.

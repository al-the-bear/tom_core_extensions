# Agent Module

The editor-facing half of an agent session: the persisted domain models, the
eleven YAML sidecars that hold them, the bridge discovery and reconnect
protocol, and the send engine that streams one prompt through the Agent SDK.

> **Want to run it?** [`example/agent/agent_example.dart`](../example/agent/agent_example.dart)
> walks the whole unit without a network — a sidecar round-trip and both
> degradation rules, bridge discovery and endpoint matching, the reconnect
> back-off resolving all three ways, and a send that refreshes a stale session.
> Every seam that would need a socket, a clock or an API key is injected, so it
> runs in under a second and touches only a temporary directory.

> **Looking for a signature?** This page explains behaviour.
> [`doc/api/api_summary_agent.md`](api/api_summary_agent.md) is the
> symbol-level mirror: all 52 exported types, 13 top-level functions and 4
> constants with a section each, and every public static named.
> `test/api_summary_test.dart` derives the required set from the barrel, so it
> cannot fall behind the code.

Everything here is **non-UI and non-Flutter**. The Flutter controllers and
widgets that drive it live in `tom_forge_agentic`; this module is what they
drive, and what a second front end would reuse unchanged. The split is load
bearing rather than tidy: the send engine's retry rule and the reconnect
protocol are the parts worth testing, and neither needs a widget tree to run.

## Table of Contents

- [Overview](#overview)
- [The sidecar stores](#the-sidecar-stores)
- [How a damaged sidecar degrades](#how-a-damaged-sidecar-degrades)
- [Bridge discovery and binding](#bridge-discovery-and-binding)
- [Reconnect](#reconnect)
- [The send engine](#the-send-engine)
- [Core Components](#core-components)
- [Dependencies](#dependencies)

---

## Overview

| Symbol | Kind | Purpose |
| ------ | ---- | ------- |
| `readAgentYamlFile` | function | Reads and parses one sidecar, answering `null` for missing, empty, unreadable and malformed alike |
| `decodeAgentYamlList` / `decodeAgentYamlValue` | function | Builds models from a parsed sidecar — skipping a bad entry, or falling back for a bad singleton |
| `AgentProfileStore` | final class | Sidecar of named agent configurations |
| `AgentSettingsStore` | final class | Sidecar of the single settings mapping |
| `ChatVariableStore` | final class | Sidecar of chat variables, identified by `name` |
| `PromptQueueStore` | final class | Sidecar of queued prompts |
| `PromptTemplateStore` | final class | Sidecar of prompt templates |
| `QueueTemplateStore` | final class | Sidecar of queue templates |
| `ReminderTemplateStore` | final class | Sidecar of reminder templates |
| `TimedRequestStore` | final class | Sidecar of timed requests |
| `PromptTrailStore` | final class | Sidecar of sent-prompt / received-answer pairs |
| `BridgeChoiceStore` | final class | Sidecar of the persisted bridge binding |
| `SpecSessionStore` | final class | The per-specification SDK session id — a bare scalar, the one sidecar with no model behind it |
| `AgentSettings` | final class | Bridge target plus the global `Options` defaults a profile overlays |
| `AgentProfile` | final class | One named agent configuration, including `interruptRetryPrefix` |
| `ToolApprovalMode` | enum | How a profile answers the SDK's tool-approval prompt |
| `ChatMessage` | final class | One turn of a conversation |
| `ChatRole` | enum | Who spoke a `ChatMessage` |
| `TrailPair` | final class | One sent prompt with the answer it drew, as the trail stores it |
| `ChatVariable` | final class | One named value a template can interpolate |
| `PromptTemplate` | final class | A reusable prompt body |
| `QueueTemplate` | final class | A reusable queue entry |
| `ReminderTemplate` | final class | A reusable reminder body |
| `TimedRequest` | final class | A request the editor sends on a schedule |
| `TimedRequestStatus` | enum | Where a `TimedRequest` stands |
| `ScheduleMode` | enum | Interval or fixed times |
| `ScheduledTime` | final class | One `HH:MM` slot, optionally pinned to a date for a one-shot |
| `QueuedPrompt` | final class | One queue entry with its pre-prompts and follow-ups |
| `QueuedPromptStatus` | enum | Where a `QueuedPrompt` stands |
| `QueuedPromptType` | enum | What a queue entry is for |
| `QueuedTransport` | enum | Which transport a queue entry is dispatched over |
| `QueuedPrePrompt` | final class | A prompt sent before the main one, awaiting its own answer |
| `QueuedPrePromptStatus` | enum | Where a `QueuedPrePrompt` stands |
| `QueuedFollowUpPrompt` | final class | A prompt sent after the main one, in insertion order |
| `BridgeConnectionService` | final class | Scans the bridge port range and reports the responsive servers |
| `BridgeServer` | final class | One discovered bridge: its port and what answered |
| `BridgeServerStatus` | enum | Whether a scanned port answered, refused or timed out |
| `BridgePortScanner` | typedef | The probe the service scans with, injectable for tests |
| `BridgeChoice` | final class | The bridge the editor is bound to, matched endpoint-wise |
| `ReconnectCoordinator` | final class | The reconnect back-off loop and its three resolutions |
| `ReconnectResult` | final class | What one reconnect attempt settled on |
| `ReconnectResolution` | enum | Reconnected, gave up, or was superseded |
| `ReconnectDelay` | typedef | The back-off schedule, injectable so a test need not wait |
| `AgentSendEngine` | final class | Streams one prompt, refreshes the session id, honours cancellation |
| `AgentSendConfig` | final class | The per-send inputs the engine assembles `Options` from |
| `AgentSendEvent` | sealed class | One step of a send |
| `AgentSendStarted` | final class | Opens a send, exactly once |
| `AgentSendChunk` | final class | One piece of answer text — `TextBlock` content only |
| `AgentSendSessionRefreshed` | final class | The stale session id was dropped and the query re-issued |
| `AgentSendCompleted` | final class | Closes a send successfully |
| `AgentSendFailed` | final class | Closes a send on failure |
| `AgentSdkClientFactory` | typedef | How the engine obtains its SDK client, injectable for tests |
| `EditorPlaceholderBindings` | final class | The editor's binding namespace over the shared resolver: sync, lenient, no I/O |
| `PlaceholderExpressionsUnsupportedError` | final class | Thrown for a `${{ … }}` form, which the editor refuses to evaluate |

## The sidecar stores

Eleven small YAML files, written synchronously on every change, living in the
spec workspace and deliberately **outside** the document's `*.docspecs.yaml` pass:
they are editor and transport state, not specification content.

Each store resolves its own path the same way — an environment variable when it
is set and non-empty, otherwise a fixed name under `<cwd>/.tom/`:

| Store | Environment override | Default path |
| ----- | -------------------- | ------------ |
| `PromptQueueStore` | `TOM_SPECS_QUEUE_FILE` | `.tom/prompt_queue.yaml` |
| `AgentProfileStore` | `TOM_SPECS_PROFILES_FILE` | `.tom/agent_profiles.yaml` |
| `ChatVariableStore` | `TOM_SPECS_CHATVARS_FILE` | `.tom/chat_variables.yaml` |
| `PromptTemplateStore` | `TOM_SPECS_PROMPT_TEMPLATES_FILE` | `.tom/prompt_templates.yaml` |
| `QueueTemplateStore` | `TOM_SPECS_QUEUE_TEMPLATES_FILE` | `.tom/queue_templates.yaml` |
| `ReminderTemplateStore` | `TOM_SPECS_REMINDER_TEMPLATES_FILE` | `.tom/reminder_templates.yaml` |
| `TimedRequestStore` | `TOM_SPECS_TIMED_FILE` | `.tom/timed_requests.yaml` |
| `PromptTrailStore` | `TOM_SPECS_TRAIL_FILE` | `.tom/prompt_trail.yaml` |
| `AgentSettingsStore` | `TOM_SPECS_AGENT_SETTINGS_FILE` | `.tom/agent_settings.yaml` |
| `BridgeChoiceStore` | `TOM_SPECS_BRIDGE_FILE` | `.tom/bridge_connection.yaml` |
| `SpecSessionStore` | `TOM_SPECS_SESSION_FILE` | `.tom/agent_session.yaml` |

The override is what makes the module testable and what lets one machine run
two editors over different workspaces; the `<cwd>` fallback is what makes it
work with no configuration at all. An override that is set but *empty* is
ignored — the fallback applies — so exporting the variable to the empty string
does not redirect a store to the current directory.

**The envelope.** Every file carries `version: 1` at the root and one key
holding the payload. The eight list stores differ only in that key and in the
field each entry is identified by:

| Store | Payload key | Entry identity |
| ----- | ----------- | -------------- |
| `PromptQueueStore` | `items` | `id` |
| `AgentProfileStore` | `profiles` | `id` |
| `ChatVariableStore` | `variables` | `name` |
| `PromptTemplateStore` | `templates` | `id` |
| `QueueTemplateStore` | `templates` | `id` |
| `ReminderTemplateStore` | `templates` | `id` |
| `TimedRequestStore` | `requests` | `id` |
| `PromptTrailStore` | `pairs` | `id` |

`AgentSettingsStore` holds a single mapping under `settings`,
`BridgeChoiceStore` a single mapping under `bridge`, and `SpecSessionStore` a
bare scalar under `sessionId` — the one sidecar with no model behind it, which
is why it reads the shared loader directly rather than through a decoder.

## How a damaged sidecar degrades

One promise, in one place: **a damaged file costs the user a reset, never a
crash.** `agent_sidecar.dart` holds it, so "they all degrade the same way" is a
property of one function rather than a claim about eleven bodies.

The promise has two halves, and they answer different damage:

**Parse damage costs the file.** `readAgentYamlFile` answers `null` for four
cases that a caller about to fall back on its defaults cannot tell apart — the
file is missing, it is empty, it cannot be read (`FileSystemException`), or it
does not parse (a `YamlException` is a `FormatException`, which is why two
catches answer three damage shapes).

**Shape damage costs one entry.** `decodeAgentYamlList` builds the models under
the payload key and skips an entry that is not a mapping, whose identity field
is not a non-empty string, or whose `fromYaml` throws a `TypeError` on a
hand-edited value of the wrong type. Skipping *per entry* is the valuable half:
one bad row costs one row rather than every good row beside it. Skipping rather
than defaulting the identity is the other: an entry with no id could not
afterwards be selected, edited or deleted, so materialising one under a
synthetic id would turn a recoverable data error into a permanent orphan.

`decodeAgentYamlValue` is the singleton counterpart. With nothing to skip *to*,
an unusable value falls back to the supplied default instead of dropping out —
which is why a hand-edited `bridge: port: "19900"` reads as the default port
rather than throwing.

## Bridge discovery and binding

The editor reaches Claude Code through a running VS Code CLI Integration
Server. Several VS Code windows can be open, each serving one workspace on its
own port, so binding is a discovery problem rather than a configuration one.

- **The range is 19900–19909 inclusive** (`bridgeScanMinPort` /
  `bridgeScanMaxPort`, from the transport package's own constants).
- `BridgeConnectionService.scan()` scans it and returns the responsive servers
  in ascending port order, each a `BridgeServer` carrying the port, the host,
  and the **workspace name** the window reported through the identity
  handshake. Every result is `BridgeServerStatus.available`; deciding which one
  is `bound` is the caller's business.
- The scanner is injected, so a test supplies fake bridges without opening a
  socket.
- The picked server is persisted as a `BridgeChoice` — host and port, nothing
  else — and restored on the next launch.

**Hosts compare as endpoints, not as strings.** `BridgeChoice.matches` requires
an equal port and a host naming the same endpoint: comparison is
case-insensitive, an IPv6 literal's brackets are stripped, and `localhost`,
`127.0.0.1` and `::1` are one endpoint. This matters because the two sides
reach the comparison from different places — the binding from the sidecar, the
server from a scan of `AgentSettings.bridgeHost` — so they can spell one
loopback endpoint differently while meaning the same bridge. `defaultBridgeHost`
(`127.0.0.1`) is what every default in the package points at, so the spellings
cannot diverge in the first place.

`matches` is deliberately **not** `operator ==`: equality is value equality on
the record that was persisted, and has to keep agreeing with `toMap`.

## Reconnect

When the bound bridge stops answering, the transport is gone — there is no way
to hold the socket or the in-flight exchange open. So what is preserved is the
user's *intent*, not the connection.

`ReconnectCoordinator.reconnect` waits, rescans, and classifies:

1. **Back off and rescan.** The default schedule is **10 s, 30 s, 60 s**
   (`defaultReconnectBackoff`). The delay is injected, so a test runs the
   protocol instantly. A scan that throws is swallowed as "no servers", so a
   transient scan error becomes another silent attempt rather than aborting
   recovery.
2. **Classify the first answer.** The first time a server answers on the bound
   endpoint, the attempt resolves — `sameWorkspace` when the workspace name
   still matches, `differentWorkspace` when it does not.
3. **Or give up.** If the endpoint stays silent across every back-off, the
   result is `stillGone`.

A `null` or empty `boundWorkspace` resolves as `sameWorkspace`: a binding
restored from persistence knows only host and port, so there is nothing to
contradict it.

The result carries the number of attempts — 1-based for a server that came
back, the full schedule length when still gone — and the server it found.

What each resolution *means* is the caller's to act on, and the intended
handling is: rebind silently and auto-resend for `sameWorkspace`; bind and
resend only after the user confirms for `differentWorkspace`; show the modal
and fail only if the user chooses to for `stillGone`.

The resend body is composed by `composeInterruptRetry`, which puts the active
profile's `interruptRetryPrefix` ahead of the original prompt, separated by a
blank line. An empty prefix yields the prompt unchanged, and composition never
stacks — repeated drops re-send one prefix rather than nesting them, because
the *original* prompt is what is composed each time.

## The send engine

`AgentSendEngine.send` is a **cold** stream: each listen runs one `query`.

The event lifecycle is exactly one `AgentSendStarted`, then zero or more
`AgentSendChunk`s — optionally with one `AgentSendSessionRefreshed` before the
retried attempt's chunks — then exactly one of `AgentSendCompleted` or
`AgentSendFailed`. Only `TextBlock` content becomes a chunk; thinking and tool
blocks are not answer text.

**The retry rule.** A failed turn is retried once with a fresh session, and only
when all four of these hold:

1. a stored session id was being resumed (`resumeId != null`);
2. this attempt has not already been retried;
3. **nothing has streamed yet**, so the retry cannot duplicate output;
4. the error text looks session-shaped.

The fourth test is deliberately broad: `specSessionLooksLikeError` matches any
error text containing `session`, `message` or `msg`, case-insensitively. Unlike
the brain's conservative matcher it does not require a separate failure cue —
the editor would rather drop and refresh a per-spec session id one extra time
than leave a stale id wedged in place. When the rule fires, the session sidecar
is cleared, `AgentSendSessionRefreshed` is emitted, and the query is re-issued
with no resume id.

An error that fails any of the four conditions ends the stream with
`AgentSendFailed`, as does a stream that ends with no terminal result message.
On success the returned session id is persisted so the next send resumes the
same conversation.

**Cancellation ends the stream silently.** Pass a `TomCancellationToken`
(`package:tom_basics/utilities.dart`); when it
signals, the active query is interrupted, which closes its stream so the loop
unwinds — and `send` then returns **without a terminal event**. No
`AgentSendCompleted`, no `AgentSendFailed`, because a user-driven stop is
neither. A consumer that waits for a terminal event to re-enable its UI must
therefore also watch the token.

Relying on the token rather than cancelling the returned subscription is
deliberate: cancelling an `async*` subscription parked on a stalled inner
stream does not resolve promptly, whereas interrupting the query closes it
eagerly.

## Core Components

- **`agent_sidecar.dart`** — the one read-and-decode path every sidecar shares,
  and therefore the one place the degradation promise lives.
- **`agent_yaml.dart`** — the YAML codec: stable key order and block style out,
  plain `Map` / `List` in, plus the type-testing `yamlValue<T>` leaf reader.
- **`bridge_connection.dart`** — the port scan, the picker model, the persisted
  binding and its endpoint-wise matching.
- **`reconnect.dart`** — the back-off loop, the three resolutions, and the
  prefix composition.
- **`agent_send.dart`** — the session sidecar, the assembled `Options`, the
  event types, and the engine.
- **The models** — `AgentProfile`, `AgentSettings`, `QueuedPrompt`,
  `ChatVariable`, `ChatMessage`, `PromptTemplate`, `QueueTemplate`,
  `ReminderTemplate`, `TimedRequest`, each with a `toYaml()` / `fromYaml()`
  pair.

## Dependencies

| Dependency | Kind | Imported by | For |
| ---------- | ---- | ----------- | --- |
| `dart:async` | dart | `agent_send.dart` | `unawaited`, so the cancellation future can be wired to the query's interrupt without the send awaiting it |
| `dart:io` | dart | 12 of 25 files | The sidecars are files: every store reads and writes one, and `Platform.environment` is where their path overrides come from |
| `path` | package | 11 of 25 files | Composing a sidecar's path from its root and file name |
| `tom_basics` | package | `agent_send.dart` | `TomCancellationToken`, the cooperative signal that interrupts an in-flight send |
| `tom_vscode_scripting_api` | package | `agent_send.dart`, `bridge_connection.dart` | The VS Code bridge client and its port scan, and the Agent SDK client the send engine streams through |
| `yaml` | package | `agent_yaml.dart` | Reading a sidecar document |
| `yaml_edit` | package | `agent_yaml.dart` | Writing one back with its formatting and comments intact |
| [placeholders](placeholders.md) | module | `editor_placeholder_bindings.dart` | The resolver the editor bindings register their placeholders into |

The module names no UI type and imports no Flutter. Everything in
`tom_forge_agentic` depends on this direction and nothing here depends back.

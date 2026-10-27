# LLM Module

The Anthropic Agent SDK as a provider, and the three strategies that decide
whether a call resumes a Claude session.

The provider contract it implements — `LlmProvider`, `LlmRequest`, the
`LlmEvent` union and the `LlmCallReport` every call is attributed by — is
`tom_llm`'s, documented in that package's
[`doc/contract.md`](../../../basics/tom_llm/doc/contract.md). This unit re-exports
it, so a caller of the Agent SDK provider names one import.

> **Looking for a signature?** This page explains the provider.
> [`doc/api/api_summary_llm.md`](api/api_summary_llm.md) is the symbol-level
> mirror of the unit's own types. `test/api_summary_test.dart` derives the
> required set from the barrel, so it cannot fall behind the code.

> **Want to run it?** [`example/llm/llm_example.dart`](../example/llm/llm_example.dart)
> is a complete `LlmProvider` in about fifty lines, driven through both entry
> points. It asserts the three invariants an implementer most easily breaks —
> the anchor stamp, the unmodified body, and one route announced once — and
> shows the two shapes a single failure takes depending on which entry point
> raised it. No network and no key: the provider echoes, because the seam is
> what is being demonstrated.

## Table of Contents

- [Overview](#overview)
- [`AgentSdkLlmProvider`](#agentsdkllmprovider)
  - [The control inversion](#the-control-inversion)
  - [Event translation](#event-translation)
  - [The anchor, through a backend with no channels](#the-anchor-through-a-backend-with-no-channels)
  - [One retry, and the four conditions on it](#one-retry-and-the-four-conditions-on-it)
  - [Failure classification](#failure-classification)
  - [The bridge client](#the-bridge-client)
- [Session strategies](#session-strategies)
- [Core Components](#core-components)
- [Dependencies](#dependencies)

## Overview

| Symbol | Kind | Purpose |
| ------ | ---- | ------- |
| `AgentSdkLlmProvider` | final class | The Anthropic Agent SDK as a provider |
| `AgentSdkSessionStrategy` | abstract interface class | Per-call decision: resume a Claude session, or start fresh |
| `NoSessionStrategy` | final class | Mode `none`: every call starts fresh |
| `BrainSessionStrategy` | final class | Mode `brain`: resumes from a store it also evicts from |
| `AgentSdkSessionStore` | final class | The session ids `BrainSessionStrategy` persists and caches |
| `QuestSessionStrategy` | final class | Mode `quest`: resumes the id recorded in a quest's history file, read-only |

## `AgentSdkLlmProvider`

### The control inversion

In the ordinary model the caller owns the loop: it asks for one completion,
then drives tools, recall and re-entry itself. The Agent SDK inverts that —
Claude Code owns the tool loop, the MCP loop and its own memory. The provider
hands it a prompt; it runs its own agentic loop and streams back assistant text
plus a terminal result.

That inversion is invisible at the seam. From the caller's side the Agent SDK
is one very capable black-box completion, so this provider implements
`LlmProvider` as any other provider does: it implements `run`, and `complete`
is the contract's buffering of it. What it costs is a dependency on
`tom_vscode_scripting_api` and a live VS Code bridge, which is why the provider
lives here and not beside the HTTP ones.

### Event translation

- one `LlmRunStarted` first, naming the call, the provider, the resolved model
  and the request's purpose;
- each assistant message's text blocks become `LlmTextDelta`s. **Thinking
  blocks are dropped** from the answer text — they are not part of the reply —
  but their token cost still counts, because the terminal usage figures already
  include them;
- the terminal result becomes `LlmRunCompleted` with a report whose tokens,
  cost and wall-clock come off the result message. Cost is the SDK's own
  `total_cost_usd`, never a price table, which has no Claude entries;
- any SDK failure becomes `LlmRunFailed`.

**`LlmToolCall` is never emitted.** Tool and MCP calls run
*inside* Claude Code, so the caller never sees them and there is nothing to
propose. That is a property of this provider, not a gap in it.

### The anchor, through a backend with no channels

The Agent SDK's `query` takes one string, so the provider sends
`wire.combined` unmodified and stamps `report.anchorHash = wire.anchorHash`,
exactly as a channel-aware provider would. Claude Code's own system prompt is
additive context, never a replacement for the anchor, so the SDK's
`systemPrompt` option is left at its append default and is never set to
override.

### One retry, and the four conditions on it

A resumed Claude session can be gone by the time the next call uses it. The
provider evicts the stored id and retries once — and only when all four of
these hold:

1. the call was resuming a stored session;
2. it has not already retried;
3. nothing has streamed yet, so the retry cannot duplicate output;
4. the failure message looks session-shaped.

The fourth test is `agentSdkLooksLikeSessionError`, and it is **conservative**:
the message must contain `session` *and* one of `not found`, `invalid`,
`no such`, `unknown`, `expired` or `does not exist`. Requiring a second cue is
what separates it from the editor's broader matcher in the `agent` unit — the
brain would rather not discard a working session on a message that merely
mentions one.

Each retry increments the report's `retries`, and the stopwatch keeps running
across it, so the report shows both that a retry happened and how long the
whole call took.

### Failure classification

Two shapes reach `LlmRunFailed` with different `classCode`s: a thrown or
costed backend error is `unknown` — the provider does not pretend to classify
what it cannot see, and the caller maps it onto its own taxonomy — while a
stream that ends with no terminal result message is `format`, which is the one
failure the provider can name from where it stands.

### The bridge client

`clientFactory` is memoised on first use, so the asynchronous bridge connect is
deferred to the first call and shared by every later one.
`rebindBridgePort(newPort)` drops that memo, which is how a caller follows a
bridge that moved. Tests inject a factory over a fake transport.

Through `complete`, a failed run surfaces as the contract's
`LlmTransportException` of kind `remote`, carrying the SDK's own error as its
`cause`.

## Session strategies

Claude Code owns its conversation memory, keyed by a session id. Whether a call
continues a prior conversation or starts fresh is the *only* thing that differs
between the three modes, so it sits behind one seam —
`AgentSdkSessionStrategy` — that the provider consults per call. The provider
never branches on the mode: it asks for a resume id, streams, and reports the
outcome back.

| Mode | Strategy | Resume id comes from | Writes |
| ---- | -------- | -------------------- | ------ |
| `none` | `NoSessionStrategy` | nothing — every call is a first call | no |
| `brain` | `BrainSessionStrategy` | a JSON store keyed by `LlmOptions.sessionId` | yes |
| `quest` | `QuestSessionStrategy` | the VS Code window's quest history file | no |

**No method may throw because the session state is damaged** — and that rule
covers the write, not just the read. `resumeIdFor` answers `null` for state it
cannot read; `record` and `evict` return normally for state they cannot write.
The provider awaits `record` on the success path, immediately before the
terminal event, so a strategy that threw there would not merely fail to persist
a session id: it would destroy the result of a call that has already been
billed. A degraded store costs at most one fresh call.

The quest strategy cannot fix a stale file, because the file is the editor's.
It remembers the id instead: once `evict` has seen the id it answered rejected,
that id is never offered again by the same strategy, and the next call starts
fresh at once. When the editor writes a new session id, that one is resumed.

## Core Components

- **`agent_sdk_llm_provider.dart`** — the Agent SDK provider.
- **`agent_sdk_session.dart`** — the three session strategies and the
  conservative session-error matcher.

## Dependencies

| Dependency | Kind | Imported by | For |
| ---------- | ---- | ----------- | --- |
| `dart:async` | dart | `agent_sdk_llm_provider.dart` | The `Stream` the provider returns and the `Future`s it awaits. `dart:core` re-exports both, so the import is a statement of which library declares them rather than a requirement |
| `dart:convert` | dart | `agent_sdk_session.dart` | JSON, for the session cache file and the quest history file the strategies read |
| `dart:io` | dart | `agent_sdk_session.dart` | The `brain` and `quest` strategies read and write those files |
| `tom_llm` | package | `agent_sdk_llm_provider.dart`, `agent_sdk_session.dart`, `llm.dart` | The provider contract the provider implements, the `LlmOptions` the strategies key off, and the contract the barrel re-exports |
| `tom_vscode_scripting_api` | package | `agent_sdk_llm_provider.dart` | The Agent SDK client the provider streams through, and the VS Code bridge under it |
| `prompt_sha256.dart` | module | `agent_sdk_llm_provider.dart` | `promptSha256`, the `sha256:<hex>` fingerprint every report is stamped with |

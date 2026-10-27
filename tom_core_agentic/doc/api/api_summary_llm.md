# Tom Core Agentic API Reference: LLM Module

The symbol-level mirror of `lib/src/llm/`: six types across two libraries and
one top-level function. The barrel also re-exports `tom_core_llm`, whose
provider contract these implement; that package mirrors its own symbols.

[`doc/llm.md`](../llm.md) explains the provider — the control inversion, why
the retry is bounded the way it is. This document is arranged
for lookup: one heading per symbol, grouped by the concern it belongs to.

## Table of Contents

- [Overview](#overview)
- [The Agent SDK provider](#the-agent-sdk-provider)
  - [AgentSdkLlmProvider](#agentsdkllmprovider)
  - [agentSdkLooksLikeSessionError](#agentsdklookslikesessionerror)
- [Session strategies](#session-strategies)
  - [AgentSdkSessionStrategy](#agentsdksessionstrategy)
  - [NoSessionStrategy](#nosessionstrategy)
  - [BrainSessionStrategy](#brainsessionstrategy)
  - [AgentSdkSessionStore](#agentsdksessionstore)
  - [QuestSessionStrategy](#questsessionstrategy)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

Sources: `lib/src/llm/agent_sdk_llm_provider.dart`, `lib/src/llm/agent_sdk_session.dart`, `lib/src/llm/llm.dart`.

The module `lib/src/llm/` is barrelled by `llm.dart`.

Two concerns, and the grouping below follows them:

- **The Agent SDK provider** — an `LlmProvider` over the VS Code bridge's
  Agent SDK client.
- **Session strategies** — the three ways it decides, per call, whether to
  resume a Claude session.

## The Agent SDK provider

### AgentSdkLlmProvider

`final class`. The Anthropic Agent SDK as an `LlmProvider`.

Constructed with `id`, `defaultModel`, an optional `maxTurns`, a
`permissionMode`, a `clientFactory` over the bridge port, an optional
`clientDisposer` and a `sessionStrategy`. The factory is **memoised** on first
use, so the asynchronous bridge connect is deferred to the first call and
shared by every later one; `rebindBridgePort(newPort)` drops that memo, which
is how a caller follows a bridge that moved.

`run` implements the contract, and `complete` is the contract's buffering of
it. The event translation: one `LlmRunStarted`; each assistant message's text
blocks become `LlmTextDelta`s, with thinking blocks dropped from the answer text
though their tokens still count; the terminal result becomes `LlmRunCompleted`
with tokens, cost and wall-clock read off it; any SDK failure becomes
`LlmRunFailed`.

**One retry, under four conditions together**: the call was resuming a stored
session, it has not already retried, nothing has streamed yet, and the message
looks session-shaped by `agentSdkLooksLikeSessionError`. Each retry increments
`retries`, and the stopwatch runs across it.

Two failure classes: a thrown or costed backend error is `unknown`, because the
provider does not classify what it cannot see; a stream ending with no terminal
result is `format`, the one failure it can name itself.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `bridgePort` | `int get bridgePort` | The bridge port the provider currently connects to. |

### agentSdkLooksLikeSessionError

```dart
bool agentSdkLooksLikeSessionError(String message)
```

The conservative session-error rule: the message must contain `session` **and**
one of `not found`, `invalid`, `no such`, `unknown`, `expired` or
`does not exist`. The second cue is what separates it from the editor's broader
matcher in the `agent` unit — this side would rather not discard a working
session on a message that merely mentions one.

## Session strategies

### AgentSdkSessionStrategy

`abstract interface class`. The per-call decision, in three methods:
`resumeIdFor(options)` answers the session id to resume or `null` for a fresh
one; `record(options, claudeSessionId)` stores what a successful call produced;
`evict(options)` forgets a stored id after a session-shaped failure.

**No method may throw because the session state is damaged** — write included.
The provider awaits `record` on the success path immediately before the terminal
event, so a strategy that threw there would destroy the result of a call that
has already been billed. A degraded store costs at most one fresh call.

### NoSessionStrategy

`final class`. Mode `none`: every call is a first call. Resolves no id, records
and evicts nothing. `const`-constructible.

### BrainSessionStrategy

`final class`. Mode `brain`: reads and writes the Claude session id through an
`AgentSdkSessionStore`, keyed by `LlmOptions.sessionId`. The only strategy
that writes.

### AgentSdkSessionStore

`final class`. The JSON-backed `session id → Claude-Code session id` map behind
`BrainSessionStrategy`: `lookup(brainSessionId)`, `put(brainSessionId,
claudeSessionId)` and `remove(brainSessionId)` over a `File`, with the contents
cached after first read.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The on-disk JSON file backing this store. |

### QuestSessionStrategy

`final class`. Mode `quest`: **read-only**. Resolves the session id from the VS
Code window's quest history file, located from `questHistoryRoot`, `questId`
and `sessionKey`. The file belongs to the editor, so nothing is ever written
to it: `record` does nothing, and `evict` remembers the id last answered as
rejected, in memory, for the strategy's lifetime. While the file still names a
rejected id `resumeIdFor` answers `null`, so a stale quest session costs one
failed resume rather than one per call; a file rewritten with a new id is
resumed again.

## Global Functions and Constants

| Name | Declaration | Description |
| ---- | ----------- | ----------- |
| `agentSdkLooksLikeSessionError` | `bool agentSdkLooksLikeSessionError(String message)` | True when [message] looks like a Claude-Code rejection of a stale / unknown session id, so the `brain`-mode provider should evict the stored id and retry once with a fresh session. |

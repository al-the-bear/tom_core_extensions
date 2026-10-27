# Standalone Agent SDK server

The no-VS-Code half of `tom_core_agentic`'s Agent SDK transports.
`StandaloneNodeAiTransport` starts it; you do not run it by hand.

## What it is

A small Node process that speaks the **VS Code CLI server's existing wire**
— JSON-RPC 2.0 in 4-byte-big-endian-length-prefixed frames over a loopback TCP
socket — and implements exactly four of its methods:

| Direction | Method | Purpose |
| --- | --- | --- |
| client → server | `agentSdk.queryVce` | start a streaming completion |
| client → server | `agentSdk.cancelVce` | abort a running completion |
| server → client | `agentSdk.chunk` | stream `SDKMessage`s back |
| server → client | `agentSdk.toolCall` | ask the app to run a tool it declared |

Nothing else exists here: no `workspace.*`, no `tom_todo.*`, no
`executeExpressionVcb`. That is the point — an app's AI needs a completion and
its own tools, not an editor.

`agentSdk.toolCall` is the extension's own reverse request, so a tool call
crosses both transports identically. A query whose `options.mcpServers` holds
`{type:'sdk'}` descriptors has each rebuilt into a real `createSdkMcpServer()`
(JSON Schema → Zod mechanically: string, integer, number, boolean, array,
object, string enums; `zod` is the SDK's peer). Each tool handler sends
`agentSdk.toolCall {streamId, server, tool, args}` back over the same socket
and awaits the app's `CallToolResult`. The tools run in the app; this process
only relays. A pending call is rejected when its query is cancelled or ends, or
the socket closes.

Speaking the *existing* protocol rather than a new one is deliberate. It means
the hosted path (a running VS Code) works with no extension change at all, and
it means "the same interface" is literal rather than approximate.

## Setup

```bash
cd tom_core_agentic/node
npm ci --omit=dev
```

`npm ci` rather than `npm install`, because what a user's Install produces has
to be reproducible from the committed `package-lock.json` — the app's
installer runs exactly this command from exactly this lockfile — rather than
from whatever the registry served that afternoon. The lockfile pins
`@anthropic-ai/claude-agent-sdk` **0.3.286**. Optional dependencies are *not*
omitted: since 0.3 the Claude Code CLI the SDK spawns is a native binary in a
per-platform optional package (`@anthropic-ai/claude-agent-sdk-darwin-arm64`
and seven siblings), and npm installs the one whose `os`/`cpu` match this
machine. Omitting optionals ships an SDK with nothing to spawn. The SDK's
peers — `@anthropic-ai/sdk`, `@modelcontextprotocol/sdk` and `zod` — are
installed with it by npm ≥ 7.

Install this way even for development, so a developer's tree is the one a
user's Install produces.
Measured on macOS/arm64, an install is **~274 MiB**, of which the native CLI
is ~216 MiB.

**Node ≥ 20 is a prerequisite the user supplies; the app bundles no runtime.**
The SDK is ESM-only and the server uses `AbortController`, so the floor is real
— but the reason it is a *prerequisite* rather than a payload is that this
transport's other prerequisite is an Anthropic credential, and there is no
population of users who hold one of those and no Node. When Node is absent —
**or present but below the floor**, which the Dart-side probe checks rather than
merely resolving a binary — the transport simply never becomes available: a
shut gate, not an error, and no offer to install the SDK (it would need Node
too). The floor is enforced
because the server and the Agent SDK run in it — the SDK declares `>=18`, and
a test holds our floor at or above whatever the locked SDK declares —
so a probe that accepted any runtime answering `--version` would report
available and then fail with an unreadable child error.

## Running

The Dart side does this for you. Started by hand, for debugging:

```bash
ANTHROPIC_API_KEY=sk-ant-… node agent_sdk_server.js
# AGENT_SDK_SERVER_READY {"port":54321}
```

It binds an **ephemeral** loopback port — never the 19900–19909 range the VS
Code CLI server uses, so both can run at once — and prints it on stdout.

## Lifecycle and security

- **Loopback only.** `listen(0, '127.0.0.1')`. Nothing is reachable off-box.
- **One client.** After the first connection, further connections are refused.
  The window in which another local process could reach it is the few
  milliseconds between bind and the app's own connect. Stated plainly: any
  process running as this user could in principle race for that window.
- **Stdin is the liveness channel.** When the app exits, our stdin closes and
  the server exits — it does not linger holding a credential.
- **The credential arrives in the environment** (`ANTHROPIC_API_KEY`), never on
  a command line, never through a shell. It is passed to the Agent SDK and is
  never logged, echoed, or sent to a client.
- **The SDK's own tools are off.** A plain completion arrives with
  `tools: []`, `allowedTools: []`, `maxTurns: 1`. A query that carries document
  tools has, whatever the caller sent, `tools: []`, `allowedTools` exactly the
  relayed `mcp__<server>__<tool>` names and `strictMcpConfig: true` set here —
  no file, shell or user-configured MCP tool is reachable.

## Packaging

**A packaged app ships this file, its `package.json` and its
`package-lock.json` — and no `node_modules`.** They go to
`<app-executable-dir>/ai/` (an application's packaging step, via
`stageAgentSdkServer`; `--verify` refuses a build that carries
`node_modules` or any part of the Agent SDK). The Agent SDK is proprietary
and is installed by the user, under Anthropic's terms, when they press
Install in the app's AI notice: `AgentSdkServerInstaller` runs
`npm ci --omit=dev` from this lockfile into `<app-data>/ai/` with the Node the
server will run on — so npm picks the Claude Code CLI package for that Node's
platform, which is the one the SDK looks for — and checks the tree before it
is used. The full explanation is the package README's section "Installing the
server".

`resolveDefaultServerScript()` — the path for a transport with no installer,
i.e. development — looks for `agent_sdk_server.js` in this order:

1. `$AGENT_SDK_SERVER_SCRIPT`
2. this `node/` folder, found by walking up from the working directory or the
   running script (source checkouts)

`node_modules` cannot be flattened into one file: the Claude Code CLI is a
native executable the SDK spawns as a grandchild process — a bundler
flattens an import graph, and an executable is not an import.

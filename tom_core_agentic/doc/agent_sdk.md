# Agent SDK Module

Anthropic's Claude Agent SDK as a `tom_llm` provider, imported as
`package:tom_core_agentic/agent_sdk.dart`, with `agent_sdk_live_probe.dart`
for live suites and `agent_sdk_testing.dart` for test doubles. The module's
sources are `lib/src/agent_sdk/`.

## Overview

`AgentSdkSessionProvider` serves every request from a session over the
transport an `AgentSdkTransportSelector` chose: `HostedCliServerAiTransport`
(a running VS Code with the Tom extension's CLI server) or
`StandaloneNodeAiTransport` (a Node server the application starts and owns,
`node/agent_sdk_server.js`). Each session runs in an isolate of its own under
an `AgentSdkSessionManager`; `boundedAiRun` abandons a run whose far end goes
quiet for longer than the stall gap; `AgentSdkServerInstaller` installs the
server's npm dependencies on request. The README's section "Agent SDK provider
(`agent_sdk.dart`)" describes each in full, with the example, the sessions,
the tools, the install, the live suites and the limits.

This module and the main barrel's `llm` module both provide an Agent SDK
provider over `tom_llm`; this one is the one with transport selection,
session isolates, the availability gate and the server install.

## Dependencies

| Dependency | Kind | Imported by | For |
| ---------- | ---- | ----------- | --- |
| `dart:async` | dart | 9 of 17 files | Streams, completers and timers: a run's events, the stall bound's timer, the session isolates' ports |
| `dart:convert` | dart | `server_payload.dart`, `testing/echo_ai_server.dart`, `testing/fake_ai_server.dart`, `transport/standalone_transport.dart` | JSON: the CLI-server wire, the server's `package.json` and `package-lock.json`, the stand-in servers' replies |
| `dart:io` | dart | `server_payload.dart`, `testing/echo_ai_server.dart`, `testing/fake_ai_server.dart`, `testing/fixture_scripts.dart`, `testing/node_runtime.dart`, `transport/standalone_transport.dart` | Starting the Node server and `npm ci`, reading the installed tree, the stand-in servers' sockets |
| `dart:isolate` | dart | `sessions/session_manager.dart`, `sessions/session_worker.dart`, `testing/fixture_scripts.dart`, `transport/standalone_transport.dart` | One isolate per session, and resolving `package:` URIs to the server script and the fixtures |
| `dart:typed_data` | dart | `testing/fake_ai_server.dart` | The bytes the fake CLI server frames |
| `meta` | package | `live_model_probe.dart`, `server_payload.dart`, `sessions/session_manager.dart`, `transport/cli_server_channel.dart`, `transport/standalone_transport.dart` | `@visibleForTesting` |
| `tom_basics` | package | `sessions/session_manager.dart` | The diagnostics port the session manager logs run starts and ends through |
| `tom_llm` | package | 12 of 17 files | The provider contract `AgentSdkSessionProvider` implements, the run events every transport streams, the trails and the Node search |
| `tom_vscode_scripting_api` | package | `transport/cli_server_channel.dart`, `transport/hosted_transport.dart`, `transport/sdk_trail_translator.dart`, `transport/standalone_transport.dart` | The CLI-server wire, its 19900–19909 port scan, and the mirror of the Agent SDK's messages |

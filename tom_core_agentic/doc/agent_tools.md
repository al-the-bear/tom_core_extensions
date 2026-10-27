# Agent Tools Module

The tool surface an LLM agent works through, imported as
`package:tom_core_agentic/agent_tools.dart`. The module's sources are
`lib/src/agent_tools/`; its import closure reaches no `dart:io`, so it links
into a browser build.

## Overview

`AgentTool` declares a tool and its argument schema (`AgentToolSchema`),
validated before the body runs; `AgentToolRegistry` holds a closed set and
narrows it with `where`; `AgentScope` and `agentGuard` pass every target
through a fixed gate order; `AgentInvocation` carries execution consent,
granted only against an `AgentExecutionGrant` statement; every call is
recorded in an `AgentAuditLog`; `AgentToolBinding` and
`AgentInProcessMcpServer` present the registry to a model; `AgentRun` and
`AgentPreviewThenApply` keep or discard an agent's work as one unit. The
README's section "Agent tools (`agent_tools.dart`)" describes each in full,
with the example.

## Dependencies

| Dependency | Kind | Imported by | For |
| ---------- | ---- | ----------- | --- |
| `dart:async` | dart | `audit.dart`, `binding.dart`, `preview_then_apply.dart`, `tool.dart` | The futures a tool body and an audit store return, and the zone a call's recording lives in |
| `dart:convert` | dart | `audit.dart`, `binding.dart` | JSON: an audit entry's file line and a tool call's arguments and result |
| `dart:math` | dart | `invocation.dart` | The secure random an invocation id is drawn from |
| `meta` | package | `binding.dart` | `@visibleForTesting` |
| `tom_llm` | package | `binding.dart` | `LlmToolBinding`, the per-request binding a tool-capable provider receives |

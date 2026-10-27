/// Anthropic's Claude Agent SDK as a `tom_llm` provider.
///
/// [AgentSdkSessionProvider] serves every request from a session over the
/// transport an [AgentSdkTransportSelector] chose: [HostedCliServerAiTransport]
/// (a running VS Code with the Tom extension's CLI server) or
/// [StandaloneNodeAiTransport] (a Node server the app starts and owns). The
/// run streams `tom_llm` events; a request's tools are relayed back to the
/// app through an in-process MCP server.
library;

export 'src/agent_sdk/server_payload.dart';
export 'src/agent_sdk/session_provider.dart';
export 'src/agent_sdk/sessions/session_manager.dart';
export 'src/agent_sdk/stall_bound.dart';
export 'src/agent_sdk/transport/cli_server_channel.dart';
export 'src/agent_sdk/transport/hosted_transport.dart';
export 'src/agent_sdk/transport/standalone_transport.dart';
export 'src/agent_sdk/transport/transport.dart';
export 'src/agent_sdk/transport_selector.dart';

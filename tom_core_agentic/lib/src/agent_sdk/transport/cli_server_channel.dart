/// The CLI-server wire, shared by both transports.
///
/// The hosted and standalone paths differ in **how they obtain an endpoint**
/// and **what they own** — not in what they say once connected. So the wire
/// lives here once, as a collaborator both transports hold, rather than in a
/// base class they extend or (worse) in two parallel copies.
///
/// The protocol is the CLI server's existing one, unchanged: JSON-RPC 2.0 in
/// 4-byte-big-endian-length-prefixed frames over a loopback TCP socket, with
/// `agentSdk.queryVce` starting a query, `agentSdk.cancelVce` aborting it,
/// `agentSdk.chunk` notifications carrying the `SDKMessage`s back, and — for a
/// request carrying tools — the server→client `agentSdk.toolCall`
/// request carrying each tool call back to the app. That choice
/// is deliberate: the standalone server then implements a **subset of a
/// protocol that already exists and already has a working peer**, so the
/// hosted path needs no extension change to be exercised, and "the same CLI
/// server interface" is literal rather than approximate.
///
/// Every JSON-RPC and Agent-SDK detail is delegated to
/// `tom_vscode_scripting_api`, which owns framing, discovery, stream-id
/// correlation, and the `SDKMessage` mirror. Reimplementing any of it here
/// would be exactly the downstream duplication the workspace rules forbid.
///
/// **The channel holds no stall bound.** It translates the wire into
/// [AgentSdkCompletionEvent]s — every event as [AgentSdkTrailed],
/// every other sign of life (a partial message's bookkeeping, a progress
/// event, a tool call being run) as [AgentSdkLiveness] — and the gap
/// bound is applied by the provider over that stream, as it is over every
/// transport's (`boundedAiRun`). A bound here would bind the two transports
/// that happen to hold a channel and leave a third free; a bound there binds
/// the seam. What stays here is what only the wire can know: that a
/// `system/api_retry` carrying a 401 is a stated credential rejection, which
/// ends the completion at once rather than feeding the bound ten retries.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_llm/tom_llm.dart';

import 'transport.dart';
import 'sdk_trail_translator.dart';

/// How many model turns a tool-using run may take before the SDK ends it.
///
/// Each tool call costs a turn, so a plain completion's `maxTurns: 1` would
/// end the run at the first call. Bounded all the same: a model that loops
/// on a refusal must end in an error result the user sees, not run until the
/// budget is gone. Twenty-four covers a read-modify-verify pass over a dozen
/// sections, which is more than one instruction in the agent dialog asks for.
const agentRunMaxTurns = 24;

/// The SDK name of the tool [name] declared on the in-process MCP server
/// [server].
String agentSdkMcpToolName(String server, String name) =>
    'mcp__${server}__$name';

/// A connected CLI-server endpoint, reduced to the one operation the AI
/// adapter needs.
final class CliServerAiChannel {
  /// The transport id reported in errors raised from this channel.
  final String transportId;

  /// The JSON-RPC client. Owned by this channel: [close] disconnects it.
  final VSCodeBridgeClient client;

  late final AgentSdkClient _agent = AgentSdkClient(
    VSCodeBridgeAgentSdkTransport(client),
  );

  CliServerAiChannel({required this.transportId, required this.client});

  /// Sees every Agent SDK message every channel receives, before translation,
  /// with the id of the transport it arrived on.
  ///
  /// For recording the fixtures from a live run through exactly the
  /// production path (`event_stream_live_test.dart`); null in
  /// every other run. Static because the transports build their channels
  /// themselves and a recording run must not need a second way to build one.
  @visibleForTesting
  static void Function(String transportId, Map<String, dynamic> raw)?
  debugMessageTap;

  /// Whether the underlying socket is connected.
  bool get isConnected => client.isConnected;

  /// Connects the socket, translating failure into the seam's error type.
  ///
  /// [VSCodeBridgeClient.connect] answers with a bool rather than throwing, so
  /// the falsehood is what gets translated here.
  Future<void> connect() async {
    if (!await client.connect()) {
      throw LlmTransportException(
        LlmErrorKind.unreachable,
        // Reached only after the server was found — the hosted scan saw it, or
        // the standalone child printed its ready line — so the likeliest cause
        // is that it went away in between. That is what the sentence says to
        // do something about.
        'Could not connect to the AI server on ${client.host}:${client.port}, '
        'which answered moments ago. Try again; if it keeps failing, restart '
        'what runs it — the VS Code window for the hosted server, this app '
        'for the standalone one.',
        transportId: transportId,
      );
    }
  }

  /// Runs one completion, mapping `SDKMessage`s to [AgentSdkCompletionEvent]s
  /// through an [SdkTrailTranslator]: the far end's start,
  /// thinking and text as they stream, each tool call and its result, every
  /// announced retry, and the result's usage and end. Everything else the far
  /// end sends is [AgentSdkLiveness]; the provider's gap bound counts it as
  /// evidence of life, so a model thinking for two minutes before its first
  /// token is never mistaken for one that has died.
  ///
  /// **Why this is a controller and not an `async*`.** The seam promises that
  /// cancelling the subscription aborts the remote completion, and an `async*`
  /// generator cannot keep that promise: while it is suspended at an `await`
  /// — which is exactly where it sits when the model is still thinking and no
  /// delta has arrived — cancellation cannot resume it, so `cancel` waits for
  /// an event that a cancelled request will never produce. A controller makes
  /// `onCancel` a first-class hook, so the abort happens the moment it is
  /// asked for, precisely in the case that matters most: a long completion the
  /// user has changed their mind about — or one the provider's bound has just
  /// abandoned.
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) {
    final controller = StreamController<AgentSdkCompletionEvent>();
    StreamSubscription<SdkMessage>? subscription;

    /// Ends the completion with [failure] and aborts the remote query.
    void abandon(LlmTransportException failure) {
      if (controller.isClosed) return;
      final sub = subscription;
      subscription = null;

      controller.addError(failure);
      unawaited(controller.close());

      // Reported first, cancelled second, and the cancel is not awaited. The
      // caller already has its answer, and a cancel that itself hung would
      // reinstate exactly the hang this path exists to end. Sending it at all
      // matters: without it every abandoned run leaves a Claude Code
      // grandchild still working for a caller that has stopped listening.
      if (sub != null) unawaited(sub.cancel());
    }

    /// Reports that the far end is alive without having produced text.
    void alive(String source) {
      if (!controller.isClosed) controller.add(AgentSdkLiveness(source));
    }

    controller.onListen = () {
      final tools = request.tools;
      final query = _agent.query(
        prompt: request.wirePrompt,
        options: Options(
          model: request.model,
          systemPrompt: request.systemPrompt == null
              ? null
              : SystemPromptText(request.systemPrompt!),
          // The SDK's own tools are off in every request: no file, no shell,
          // no web. A plain completion gets nothing else and one turn — it
          // must not be able to act on anything. An agent run gets exactly
          // the tools it was handed, declared on an in-process MCP
          // server whose calls come back to [tools] over this connection, and
          // only those are allowed; `strictMcpConfig` keeps every MCP server
          // from the far end's own settings out.
          tools: const ToolsList([]),
          allowedTools: tools == null
              ? const []
              : [
                  for (final declaration in tools.declarations)
                    agentSdkMcpToolName(tools.serverName, declaration.name),
                ],
          mcpServers: tools == null ? null : _toolOptions(tools, alive),
          strictMcpConfig: tools == null ? null : true,
          maxTurns: tools == null ? 1 : agentRunMaxTurns,
          // What makes the provider's gap bound a *gap* bound rather than a
          // disguised budget on model latency. Without this the only messages
          // in a run are `system/init`, the finished assistant message, and
          // the result — so a model that thinks for two minutes before its
          // first token is indistinguishable on this socket from one that has
          // died, and the bound would abandon exactly the completions worth
          // waiting for. The events are reported as liveness and otherwise
          // ignored: text is emitted from the assembled `SdkAssistantMessage`
          // alone, so nothing is delivered twice.
          includePartialMessages: true,
          // The trail shows the model's thinking, so the query asks
          // for it: adaptive, so the model decides how much a request needs,
          // and summarized, so what reaches the trail is readable.
          thinking: const ThinkingAdaptive(display: 'summarized'),
        ),
      );

      // every message as its trail events, the text included.
      final translator = SdkTrailTranslator(
        providerId: transportId,
        toolServerName: tools?.serverName,
      );

      subscription = query.listen(
        (message) {
          if (controller.isClosed) return;
          debugMessageTap?.call(transportId, message.raw);
          if ((message is SdkSystemEvent &&
                  _isCredentialRejection(message.raw)) ||
              (message is SdkAssistantMessage &&
                  message.error == 'authentication_failed')) {
            abandon(
              LlmTransportException(
                LlmErrorKind.remote,
                'The AI provider rejected the credential '
                '(HTTP ${message.raw['error_status'] ?? 401}). Check the API key '
                'or sign-in the AI server uses.',
                transportId: transportId,
              ),
            );
            return;
          }
          translator.translate(message).forEach(controller.add);
          if (message case SdkResultMessage(isError: true, :final result)) {
            controller.addError(
              LlmTransportException(
                LlmErrorKind.remote,
                result ?? 'The AI server reported a failed run.',
                transportId: transportId,
              ),
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          if (controller.isClosed) return;
          controller.addError(_translate(error), stack);
        },
        onDone: () {
          if (!controller.isClosed) unawaited(controller.close());
        },
      );
    };

    // Cancelling the underlying query is what sends `agentSdk.cancelVce`. The
    // controller is not closed here: it is already being torn down by the very
    // cancel we are servicing.
    controller.onCancel = () async {
      final sub = subscription;
      subscription = null;
      await sub?.cancel();
    };

    return controller.stream;
  }

  /// The in-process MCP server that declares [tools] to the model.
  ///
  /// It crosses the wire as a **descriptor** — name, version, and each tool's
  /// name, description and JSON Schema — and the far end rebuilds it into a
  /// real SDK server: the VS Code extension's `AgentSdkBridge` on the hosted
  /// path, `agent_sdk_server.js` on the standalone one. When the model calls
  /// a tool, the far end sends `agentSdk.toolCall {streamId, server, tool,
  /// args}` back over this same socket; `tom_vscode_scripting_api` routes it to
  /// the handler here by `streamId`, and the handler's answer is the reply.
  /// Nothing binds, listens or opens anything.
  ///
  /// A name the server does not declare has no handler, so the scripting API
  /// answers it with a JSON-RPC error and nothing reaches [tools]: the SDK only
  /// ever calls a tool it was given, so such a request is a defect in the far
  /// end, not a model choice to report as a refusal.
  ///
  /// A call is evidence of life, and the far end says nothing while the app
  /// runs one, so [alive] reports a call when it arrives and again when it
  /// has been answered — the provider's stall clock restarts on each.
  static Map<String, McpServerConfig> _toolOptions(
    AgentSdkToolSet tools,
    void Function(String source) alive,
  ) => {
    tools.serverName: McpSdkServerConfig(
      name: tools.serverName,
      tools: [
        for (final declaration in tools.declarations)
          SdkMcpTool(
            name: declaration.name,
            description: declaration.description,
            inputSchema: declaration.inputSchema,
            handler: (args) async {
              alive('tool call ${declaration.name}');
              final answer = await tools.call(
                declaration.name,
                args.cast<String, Object?>(),
              );
              alive('tool answered ${declaration.name}');
              return CallToolResult.text(answer.text, isError: answer.isError);
            },
          ),
      ],
    ),
  };

  /// Whether a `system` event is the SDK announcing that the API rejected the
  /// credential.
  ///
  /// The SDK reports a failed API call it intends to retry as a
  /// `system/api_retry` event carrying the HTTP status and a classification.
  /// Most of those are worth waiting through — an overloaded or failing server
  /// recovers, and the run then succeeds. A **401** does not: the SDK retries
  /// it all the same (measured on 0.3.284: ten attempts over about three
  /// minutes, then an error result), and every attempt is liveness that
  /// resets the provider's stall bound. Waiting would report after three
  /// minutes what the first event already said, so the first one is taken as
  /// the answer. It is detected here, not in the provider, because it is a
  /// fact about this wire: only the CLI-server protocol has a
  /// `system/api_retry` event to read it from.
  ///
  /// Deliberately narrow: only the status and classification a rejected key
  /// was *observed* to produce. Other non-recoverable classes the SDK may name
  /// are not guessed at; they still terminate, through the SDK's own error
  /// result.
  ///
  /// The pinned SDK can also state the rejection at once, as an assistant
  /// message whose `error` is `authentication_failed` (measured 2026-10-12,
  /// with an invalid key on the standalone server); the listener takes that
  /// as the same answer.
  static bool _isCredentialRejection(Map<String, dynamic> raw) =>
      raw['subtype'] == 'api_retry' &&
      (raw['error_status'] == 401 || raw['error'] == 'authentication_failed');

  /// Maps an error raised by the Agent SDK layer onto the seam's error type.
  Object _translate(Object error) => switch (error) {
    LlmTransportException() => error,
    AgentSdkQueryException() => LlmTransportException(
      LlmErrorKind.remote,
      error.message,
      transportId: transportId,
      cause: error,
    ),
    _ => LlmTransportException(
      LlmErrorKind.protocol,
      'The AI server sent something the adapter could not read: $error',
      transportId: transportId,
      cause: error,
    ),
  };

  /// How long [close] waits for the socket to finish closing.
  @visibleForTesting
  static const closeBound = Duration(seconds: 2);

  /// Disconnects, waiting at most [closeBound]. Idempotent.
  ///
  /// **Bounded, because the wait is not ours to finish**.
  /// `Socket.close` completes through a continuation queued in the zone the
  /// socket was last written in, and — measured — when that zone never runs
  /// again the close never returns. In the product that zone is the root zone
  /// and it always runs; in a widget test it is the fake-async zone the
  /// completion ran in, which nothing pumps once the test body has finished,
  /// and a far end that stops reading (a frozen editor window) stalls it the
  /// same way. The standalone transport kills its child *after* this returns,
  /// so an unbounded wait here also kept its SIGKILL backstop from ever
  /// running. Past the bound the socket is left to finish on its own; a
  /// disposal is not the place to wait on a peer.
  Future<void> close() async {
    if (client.isConnected) {
      await client.disconnect().timeout(closeBound, onTimeout: () {});
    }
  }
}

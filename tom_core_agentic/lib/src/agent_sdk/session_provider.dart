/// The Agent SDK session provider.
///
/// The provider is thin by
/// design: it holds no HTTP client, no credential, and no document. Everything
/// host-specific lives below the [AgentSdkServerTransport] seam, so "hosted" and
/// "standalone" are a startup choice rather than two code paths through this
/// class.
///
/// **Privacy is structural here, not procedural**.
/// The provider receives an [LlmRequest] whose system channel is text the
/// host's context assembler produced. It has no reference
/// to a document, no section accessor, and no way to obtain one — so there is
/// no code path by which a password field could reach the wire, and the rule
/// is enforced by the shape of the types rather than by a check someone has to
/// remember to write.
///
/// **Sending is explicit**. This class starts no timers, subscribes
/// to no document stream, and performs no work that is not the direct result of
/// a caller invoking [run]. Connecting a transport writes nothing to the
/// wire; only a completion does.
library;

import 'package:tom_llm/tom_llm.dart';

import 'sessions/session_manager.dart';
import 'stall_bound.dart';
import 'transport/transport.dart';
import 'transport_selector.dart';

/// Anthropic, reached indirectly through whichever transport was selected.
final class AgentSdkSessionProvider extends LlmProvider {
  /// Owns the availability verdict and the active transport.
  final AgentSdkTransportSelector selector;

  /// An optional system prompt sent with every completion. Feature-supplied
  /// configuration, never document-derived.
  final String? systemPrompt;

  /// An optional model override; null means the transport's default.
  final String? model;

  /// The agent-tools switch, read live — null for a build
  /// that has no such setting, which is the switch on.
  ///
  /// Off, this provider **reports no tool use** and refuses a request that
  /// carries a binding, so neither transport is ever handed a tool
  /// declaration: the switch is held here, below the shell, rather than by
  /// every affordance remembering to check it. A callback for the reason
  /// [selector] is not a settings store: the setting lives with the shell,
  /// which this package may not name.
  final bool Function()? agentToolsEnabled;

  /// The liveness bound: the longest silence a completion may
  /// contain before it is abandoned as
  /// [LlmErrorKind.timeout].
  ///
  /// Held **here**, above the transport seam, because this is the one place
  /// every completion passes: a transport cannot escape it by not
  /// constructing the CLI-server channel. A constant rather than a
  /// setting — it is a liveness threshold, not a preference, and a user has
  /// no way to know a good value for it; see [defaultAiStallTimeout] for the
  /// measurement behind the default. Settable only so a test can prove the
  /// bound with a fake transport in milliseconds rather than minutes.
  final Duration stallGap;

  const AgentSdkSessionProvider({
    required this.selector,
    this.systemPrompt,
    this.model,
    this.agentToolsEnabled,
    this.stallGap = defaultAiStallTimeout,
    required this.sessions,
    required this.toolServerName,
  });

  /// The in-process MCP server a request's tools are declared on; the model
  /// sees each tool as `mcp__<toolServerName>__<tool>`.
  final String toolServerName;

  /// The sessions every run is served from: the agent run in
  /// `chat`, the actions in `default`, each in its own isolate.
  final AgentSdkSessionManager sessions;

  /// The provider's name; a run's report names the transport that served it.
  @override
  String get id => 'anthropic';

  /// The sessions' consolidated trails, for the trail view.
  @override
  LlmTrails get trails => sessions.trails;

  /// The availability gate, delegated to the selector. Free to read; see
  /// [AgentSdkTransportSelector].
  @override
  bool get isAvailable => selector.isAvailable;

  /// The selector's retained explanation, so a disabled affordance can say why.
  @override
  String? get unavailableReason => selector.unavailableReason;

  /// The active transport's capabilities, or [LlmCapabilities.none] when
  /// there is none — so a UI that reads capabilities before checking
  /// availability still gets a correct "nothing is offered" answer.
  ///
  /// `canUseTools` is the transport's answer AND the `agentTools` switch.
  @override
  LlmCapabilities get capabilities {
    final reached = selector.active?.capabilities ?? LlmCapabilities.none;
    if (!reached.canUseTools || (agentToolsEnabled?.call() ?? true)) {
      return reached;
    }
    return LlmCapabilities(
      canComplete: reached.canComplete,
      canEmbed: reached.canEmbed,
      maxContextTokens: reached.maxContextTokens,
    );
  }

  /// The run: served from the request's session, where the
  /// transport's events are bounded by [stallGap] (see [boundedAiRun]) and
  /// streamed back here. Throws [LlmSessionBusyException] when that
  /// session already has a run. Cancelling the stream cancels the run.
  /// [complete] is derived from this.
  @override
  Stream<LlmEvent> run(LlmRequest request) {
    // a provider that reports no tool use never sees a tool
    // declaration. Reaching here with one is a caller that skipped the
    // capability check, and sending the prompt without the tools would run an
    // agent that cannot act while appearing to.
    if (request.toolBinding != null && !capabilities.canUseTools) {
      throw UnsupportedError(
        'This AI provider cannot use document tools; check '
        'capabilities.canUseTools before binding them.',
      );
    }
    final transport = selector.active;
    if (transport == null) {
      // Features are gated off, so reaching here is a caller bug rather
      // than a runtime condition to recover from.
      throw UnsupportedError(
        'No AI transport is available; check isAvailable before completing.',
      );
    }

    final binding = request.toolBinding;
    final completion = AgentSdkCompletionRequest(
      prompt: request.prompt.user,
      context: request.prompt.system,
      systemPrompt: systemPrompt,
      model: model ?? request.options.model,
      // the binding's registry, declared to the model for this
      // request only; each call is dispatched back into the binding.
      tools: binding == null
          ? null
          : AgentSdkToolSet.fromBinding(binding, serverName: toolServerName),
    );

    // in the request's session, which refuses when busy.
    return sessions.run(
      sessionId: request.options.sessionId ?? llmSessionFor(request.purpose),
      transport: transport,
      request: completion,
      prelude: llmRunPrelude(request, providerId: transport.id),
      stallGap: stallGap,
      // The backend is gone, not merely unhappy: close the gate and report
      // once, so the editor hides the affordance instead of failing again on
      // the next attempt.
      onFailure: (failure) {
        if (failure.kind == LlmErrorKind.unreachable) {
          selector.markLost(failure);
        }
      },
    );
  }

  /// Anthropic exposes no embeddings API, so this provider never supports
  /// embedding and semantic search degrades to lexical for as long as
  /// no transport embeds. Throwing [UnsupportedError] is the port's contract for a
  /// capability the provider does not have.
  @override
  Future<List<double>> embed(String text) async => throw UnsupportedError(
    'The Anthropic provider offers no embeddings; semantic search '
    'degrades to lexical search.',
  );
}

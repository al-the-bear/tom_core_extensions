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

import '../prompt_sha256.dart';
import 'resume.dart';
import 'sessions/session_manager.dart';
import 'stall_bound.dart';
import 'transport/transport.dart';
import 'transport_selector.dart';

/// What a run does when its session already has one.
enum AgentSdkWhenBusy {
  /// Refuses with [LlmSessionBusyException] — an app whose user started the
  /// run, and would otherwise see it start at a moment nobody chose.
  refuse,

  /// Waits for the session to be free — a backend serving many callers,
  /// for which a busy session is ordinary traffic.
  queue,
}

/// Whom a run names as the provider that answered it — in its
/// `LlmRunStarted` and its report.
enum AgentSdkRunAttribution {
  /// The transport that served it (`hosted`, `standalone`): an app with one
  /// AI provider, whose trail says how the run was reached.
  transport,

  /// This provider's [AgentSdkSessionProvider.id]: a backend that routes
  /// among many providers and attributes each run to the one it chose.
  provider,
}

/// Anthropic, reached indirectly through whichever transport was selected.
///
/// The one Agent SDK provider. An app's AI actions and its document agent use
/// it as configured by default: plain completions, the app's own tools only,
/// a busy session refused, the gate checked before any run. A backend that is
/// itself an agent — the brain — configures the rest: Claude Code's own loop
/// ([agentLoop]), conversations continued across requests ([resume]), busy
/// sessions queued ([whenBusy]), the transport reached on demand
/// ([connectOnDemand]) and runs attributed to this provider ([attribution]).
final class AgentSdkSessionProvider extends LlmProvider {
  /// Owns the availability verdict and the active transport.
  final AgentSdkTransportSelector selector;

  /// An optional system prompt sent with every completion, in place of the
  /// far end's own. Configuration, never document-derived.
  final String? systemPrompt;

  /// The model used when a request names none; null means the transport's
  /// default.
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

  /// Claude Code's own agent loop for every request, or null for none
  /// (plain completions and the request's own tools).
  ///
  /// With a loop, the tool calls Claude Code makes are recorded in the
  /// [trails] and left out of the run's stream: they are the far end's to
  /// run, and a caller reading `LlmToolCall`s as calls to make must not see
  /// them.
  final AgentSdkAgentLoop? agentLoop;

  /// Which conversation a request continues, or null for a fresh one every
  /// time.
  final AgentSdkResumeStrategy? resume;

  /// What a run does when its session is busy.
  final AgentSdkWhenBusy whenBusy;

  /// Whom a run is attributed to.
  final AgentSdkRunAttribution attribution;

  /// Whether a run with no active transport first tries to reach one.
  ///
  /// Off, the gate is the caller's to check ([isAvailable]) and a run without
  /// a transport is a caller bug. On, a run reaches for the transport itself
  /// and, when nothing answers, ends as a failed run whose reason is the
  /// selector's — what a backend wants, whose callers have no gate to read.
  final bool connectOnDemand;

  @override
  final String id;

  const AgentSdkSessionProvider({
    required this.selector,
    required this.sessions,
    required this.toolServerName,
    this.id = 'anthropic',
    this.systemPrompt,
    this.model,
    this.agentToolsEnabled,
    this.stallGap = defaultAiStallTimeout,
    this.agentLoop,
    this.resume,
    this.whenBusy = AgentSdkWhenBusy.refuse,
    this.connectOnDemand = false,
    this.attribution = AgentSdkRunAttribution.transport,
  });

  /// The in-process MCP server a request's tools are declared on; the model
  /// sees each tool as `mcp__<toolServerName>__<tool>`.
  final String toolServerName;

  /// The sessions every run is served from: the agent run in
  /// `chat`, the actions in `default`, a caller's own session by its id —
  /// each in its own isolate.
  final AgentSdkSessionManager sessions;

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
  /// streamed back here. A busy session refuses or queues ([whenBusy]).
  /// Cancelling the stream cancels the run. [complete] is derived from this.
  ///
  /// The far end receives the request's `WirePrompt.combined` unchanged, and
  /// the run's report carries the prompt's anchor hash, its body hash and its
  /// template — the attribution a caller wrapping an anchor relies on.
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
    if (!connectOnDemand && resume == null) {
      final transport = selector.active;
      if (transport == null) {
        // Features are gated off, so reaching here is a caller bug rather
        // than a runtime condition to recover from.
        throw UnsupportedError(
          'No AI transport is available; check isAvailable before completing.',
        );
      }
      return _attempt(request, transport, resumeId: null);
    }
    return _prepared(request);
  }

  /// A run that reaches for the transport or a conversation first.
  Stream<LlmEvent> _prepared(LlmRequest request) async* {
    var transport = selector.active;
    if (transport == null && connectOnDemand) {
      await selector.retry();
      transport = selector.active;
    }
    if (transport == null) {
      yield* _unreachable(request);
      return;
    }
    final strategy = resume;
    // The conversation the far end names, recorded once the run completes.
    String? conversation;
    void named(String id) => conversation = id;
    final resumeId = await strategy?.resumeIdFor(request.options);
    if (resumeId == null) {
      yield* _recorded(
        request,
        _attempt(request, transport, resumeId: null, onConversation: named),
        () => conversation,
      );
      return;
    }

    // A resumed conversation the far end does not know is retried once,
    // fresh — but only while nothing of the answer has been delivered, so the
    // retry cannot repeat text. Until then the first attempt's end is held
    // back: shown, it would end the caller's run.
    var sawText = false;
    final held = <LlmEvent>[];
    await for (final event in _attempt(
      request,
      transport,
      resumeId: resumeId,
      onConversation: named,
    )) {
      if (event is LlmTextDelta) sawText = true;
      if (!sawText && (event is LlmRunError || event is LlmRunFailed)) {
        held.add(event);
        continue;
      }
      if (event is LlmRunCompleted) {
        yield* _recordedEnd(request, event, conversation);
        continue;
      }
      yield event;
    }
    if (held.isEmpty) return;
    final error = held.whereType<LlmRunError>().firstOrNull;
    final ended = held.whereType<LlmRunFailed>().firstOrNull;
    final message = error?.message ?? ended?.failure.message ?? '';
    if (!agentSdkLooksLikeResumeError(message)) {
      yield* Stream.fromIterable(held);
      return;
    }
    await strategy!.evict(request.options);
    yield LlmRetry(attempt: 2, cause: message);
    conversation = null;
    yield* _recorded(
      request,
      _attempt(
        request,
        transport,
        resumeId: null,
        retries: 1,
        onConversation: named,
      ).where((e) => e is! LlmRunStarted && e is! LlmUserPrompt),
      () => conversation,
    );
  }

  /// [events], with a completed run's conversation recorded before its end
  /// is delivered.
  Stream<LlmEvent> _recorded(
    LlmRequest request,
    Stream<LlmEvent> events,
    String? Function() conversation,
  ) async* {
    await for (final event in events) {
      if (event is LlmRunCompleted) {
        yield* _recordedEnd(request, event, conversation());
      } else {
        yield event;
      }
    }
  }

  Stream<LlmEvent> _recordedEnd(
    LlmRequest request,
    LlmRunCompleted ended,
    String? conversation,
  ) async* {
    if (conversation != null) {
      await resume?.record(request.options, conversation);
    }
    yield ended;
  }

  /// No transport answered: the run opens, fails with the selector's reason,
  /// and ends.
  Stream<LlmEvent> _unreachable(LlmRequest request) {
    final reason =
        selector.unavailableReason ?? 'No AI server could be reached.';
    final account = _account(request, providerId: id);
    final prelude = llmRunPrelude(request, providerId: id);
    prelude.forEach(account.observe);
    final error = LlmRunError(LlmErrorKind.unreachable, reason);
    account.observe(error);
    return Stream.fromIterable([
      ...prelude,
      error,
      account.end(
        LlmRunOutcome.failed,
        duration: Duration.zero,
        failure: LlmFailure(classCode: 'unreachable', message: reason),
      ),
    ]);
  }

  /// One attempt in the request's session, its report attributed to the
  /// request's prompt.
  Stream<LlmEvent> _attempt(
    LlmRequest request,
    AgentSdkServerTransport transport, {
    required String? resumeId,
    int retries = 0,
    void Function(String id)? onConversation,
  }) {
    final binding = request.toolBinding;
    final completion = AgentSdkCompletionRequest(
      prompt: request.prompt.combined,
      systemPrompt: systemPrompt,
      model: request.options.model ?? model,
      // the binding's registry, declared to the model for this
      // request only; each call is dispatched back into the binding.
      tools: binding == null
          ? null
          : AgentSdkToolSet.fromBinding(binding, serverName: toolServerName),
      resume: resumeId,
      agentLoop: agentLoop,
    );
    final promptHash = promptSha256(request.prompt.combined);
    return sessions
        .run(
          sessionId:
              request.options.sessionId ?? llmSessionFor(request.purpose),
          transport: transport,
          request: completion,
          prelude: llmRunPrelude(
            request,
            providerId: attribution == AgentSdkRunAttribution.provider
                ? id
                : transport.id,
          ),
          stallGap: stallGap,
          queueWhenBusy: whenBusy == AgentSdkWhenBusy.queue,
          onConversation: onConversation,
          // The backend is gone, not merely unhappy: close the gate and report
          // once, so the editor hides the affordance instead of failing again
          // on the next attempt.
          onFailure: (failure) {
            if (failure.kind == LlmErrorKind.unreachable) {
              selector.markLost(failure);
            }
          },
        )
        // Claude Code's own tool calls are its loop's, not the caller's: the
        // trail records them, the caller's stream does not carry them — a
        // caller that runs the tool calls a provider reports would otherwise
        // try to run Claude Code's.
        .where(
          (event) =>
              agentLoop == null ||
              (event is! LlmToolCall && event is! LlmToolResult),
        )
        .map(
          (event) => event is LlmRunEnded
              ? _attributed(
                  event,
                  request.prompt,
                  promptHash,
                  retries,
                  providerId: attribution == AgentSdkRunAttribution.provider
                      ? id
                      : null,
                )
              : event,
        );
  }

  /// [ended], its report carrying [prompt]'s attribution, [retries] more
  /// retries than the attempt counted and, when given, [providerId].
  static LlmRunEnded _attributed(
    LlmRunEnded ended,
    WirePrompt prompt,
    String promptHash,
    int retries, {
    String? providerId,
  }) {
    final report = ended.report;
    final attributed = report == null
        ? null
        : LlmCallReport(
            providerId: providerId ?? report.providerId,
            modelId: report.modelId,
            anchorHash: prompt.anchorHash,
            promptHash: promptHash,
            tokensIn: report.tokensIn,
            tokensOut: report.tokensOut,
            retries: report.retries + retries,
            wallClockMs: report.wallClockMs,
            cost: report.cost,
            templateSha: prompt.templateSha,
          );
    return LlmRunEnded(
      ended.outcome,
      callId: ended.callId,
      rounds: ended.rounds,
      toolCalls: ended.toolCalls,
      duration: ended.duration,
      report: attributed,
      failure: ended.failure,
      wire: ended.wire,
    );
  }

  static LlmRunAccount _account(
    LlmRequest request, {
    required String providerId,
  }) => LlmRunAccount.of(
    request.prompt,
    providerId: providerId,
    promptHash: promptSha256(request.prompt.combined),
  );

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

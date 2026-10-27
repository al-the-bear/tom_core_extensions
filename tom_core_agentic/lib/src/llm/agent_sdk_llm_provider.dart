// AgentSdkLlmProvider — the Anthropic Agent SDK as an [LlmProvider].
//
// ── The control inversion, and why it still fits `LlmProvider` ──
//
// In the normal model a *caller* owns the loop: it requests one completion,
// then drives tools / recall / re-entry itself. The Agent SDK inverts this —
// Claude Code owns the tool loop, the MCP-server loop, and all of its own
// memory. We hand it a prompt; it runs its *own* agentic loop and streams back
// assistant text plus a terminal result. That inversion is invisible at the
// `LlmProvider` seam: from the caller's side the Agent SDK is a single very
// capable black-box completion. It depends on `tom_vscode_scripting_api` and a
// live VS Code bridge — a run-layer integration concern.
//
// ── Event translation ──
//
//   * one [LlmRunStarted] first, naming the call;
//   * each `SdkAssistantMessage`'s `TextBlock`s → [LlmTextDelta]
//     (`ThinkingBlock`s are dropped from the answer text — they are not part of
//     the assistant's reply — but their token cost is still counted, because the
//     terminal usage figures already include them);
//   * the terminal `SdkResultMessage` → [LlmRunCompleted] with an
//     [LlmCallReport] whose tokens / cost / wall-clock are read off the result
//     message (cost from `total_cost_usd` — never a price table, which has no
//     Claude entries);
//   * any SDK failure → [LlmRunFailed].
//
// **Deliberately NOT surfaced:** [LlmToolCall]. Tool / MCP calls run *inside*
// Claude Code; the caller never sees them, so the provider never emits a
// tool-call event.
//
// ── Anchor invariant ──
//
// The producer has already prepended the assistant-dedication anchor into
// `WirePrompt.system` (which leads `WirePrompt.combined`). The agent SDK has no
// native system/user channel split for the query input, so the provider sends
// `wire.combined` to Claude Code **unmodified** (as the `query` prompt) and
// stamps `report.anchorHash = wire.anchorHash` on every report, exactly like the
// HTTP providers. Claude Code's own system prompt is additive context, never a
// replacement for the anchor — so `Options.systemPrompt` is left at its
// append/preset default and is never set to `override`.

import 'dart:async';

import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';

import '../prompt_sha256.dart' show promptSha256;
import 'package:tom_llm/tom_llm.dart';

import 'agent_sdk_session.dart';

/// One Anthropic-Agent-SDK backend, exposed as an [LlmProvider].
///
/// The [clientFactory] is memoised on first use so the (async) bridge connect is
/// deferred until the first call and shared across every subsequent call. Tests
/// inject a factory over a fake `AgentSdkTransport`.
final class AgentSdkLlmProvider extends LlmProvider {
  @override
  final String id;

  /// Model id used when [LlmOptions.model] is null. The caller resolves
  /// `options.model` before invoking the provider; this is the route default.
  final String defaultModel;

  /// Claude Code's internal agentic-loop turn cap, or `null` for the SDK default.
  final int? maxTurns;

  /// The permission posture handed to Claude Code's own tool loop.
  final PermissionMode permissionMode;

  /// Builds (and connects) the [AgentSdkClient] for the given bridge port. The
  /// result is memoised in [_clientFuture] so the bridge socket is opened once
  /// and reused; [rebindBridgePort] evicts that memo so the next call rebuilds
  /// against a changed port. The port flows as an argument (not a captured
  /// closure value) precisely so a runtime rebind can pick a new one.
  final Future<AgentSdkClient> Function(int bridgePort) clientFactory;

  /// Disposes a memoised client when [rebindBridgePort] drops it — e.g.
  /// disconnecting the underlying bridge socket so the old port is released.
  /// `null` leaves the dropped client to be garbage-collected.
  final Future<void> Function(AgentSdkClient client)? clientDisposer;

  /// Decides, per call, whether to resume a stored Claude-Code session or start
  /// fresh, and records / evicts the session id. Defaults to
  /// [NoSessionStrategy] — session mode `none`, every call a first call.
  final AgentSdkSessionStrategy sessionStrategy;

  /// The VS Code bridge / CLI-server port the memoised client connects to.
  /// Mutable so `/cli_server_port` can rebind a live provider via
  /// [rebindBridgePort].
  int _bridgePort;

  Future<AgentSdkClient>? _clientFuture;

  AgentSdkLlmProvider({
    required this.id,
    required this.defaultModel,
    required this.clientFactory,
    required int bridgePort,
    this.clientDisposer,
    this.maxTurns,
    this.permissionMode = PermissionMode.default_,
    this.sessionStrategy = const NoSessionStrategy(),
  }) : _bridgePort = bridgePort;

  /// The bridge port the provider currently connects to.
  int get bridgePort => _bridgePort;

  /// The memoised client (one bridge connection shared across calls), built
  /// against the current [_bridgePort].
  Future<AgentSdkClient> _client() =>
      _clientFuture ??= clientFactory(_bridgePort);

  /// Rebinds the provider to [newPort]: drops the memoised client (disposing it
  /// via [clientDisposer], so the old bridge socket disconnects) and records the
  /// new port. The next call to [run] lazily reconnects on [newPort].
  ///
  /// Returns `true` when the port actually changed (a reconnect will happen),
  /// `false` when [newPort] equals the current port (a no-op). Disposal failures
  /// are swallowed — the old socket may already be dead, which is exactly the
  /// condition a rebind is recovering from.
  Future<bool> rebindBridgePort(int newPort) async {
    if (newPort == _bridgePort) return false;
    final Future<AgentSdkClient>? pending = _clientFuture;
    _clientFuture = null;
    _bridgePort = newPort;
    if (pending != null) {
      try {
        final AgentSdkClient client = await pending;
        final disposer = clientDisposer;
        if (disposer != null) await disposer(client);
      } catch (_) {
        // Best-effort: the old client may already be unusable; the new port is
        // already recorded so the next call reconnects regardless.
      }
    }
    return true;
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    final stopwatch = Stopwatch()..start();
    final modelId = options.model ?? defaultModel;
    final callId = _newCallId(prompt);

    yield LlmRunStarted(
      purpose: request.purpose,
      providerId: id,
      modelId: modelId,
      callId: callId,
    );

    // The session id to resume, or null for a fresh session. Mode `none` always
    // returns null; mode `brain` looks it up by the caller's session id; mode
    // `quest` reads it from the window's quest history. A session-shaped failure
    // on a resumed call evicts the stored id and retries exactly once fresh.
    String? resumeId = await sessionStrategy.resumeIdFor(options);
    // Counted, not flagged: this is the number the report's `retries` field
    // carries, so keeping it as an int is what stops the two drifting apart.
    var retries = 0;
    var emittedChunk = false;

    while (true) {
      final sdkOptions = Options(
        model: modelId,
        maxTurns: maxTurns,
        permissionMode: permissionMode,
        // `resume` is the only session knob set. When null, `Options.toJson`
        // omits the key, so mode `none` sends no session id at all.
        // `systemPrompt` is left at the SDK default so Claude Code's own system
        // prompt stays additive and never overrides the anchored prompt. The
        // agent SDK has no native system/user channel split for the query
        // input, so the whole anchored prompt is sent as one string via
        // `wire.combined` (the WirePrompt no-native-separation path).
        resume: resumeId,
      );

      SdkResultMessage? result;
      Object? caught;
      try {
        final client = await _client();
        // `wire.combined` carries the assistant-dedication anchor verbatim (the
        // anchor leads `wire.system`, which leads `combined`) and is handed to
        // Claude Code unmodified.
        final query = client.query(
          prompt: prompt.combined,
          options: sdkOptions,
        );
        await for (final message in query) {
          if (message is SdkAssistantMessage) {
            for (final block in message.content) {
              if (block is TextBlock && block.text.isNotEmpty) {
                emittedChunk = true;
                yield LlmTextDelta(block.text);
              }
              // ThinkingBlock / tool blocks are not part of the assistant reply.
            }
          } else if (message is SdkResultMessage) {
            result = message;
          }
        }
      } catch (e) {
        caught = e;
      }

      // ── Transport / exception failure ──
      if (caught != null) {
        final message = caught.toString();
        if (await _shouldRetryFresh(
          resumeId: resumeId,
          retries: retries,
          emittedChunk: emittedChunk,
          message: message,
          options: options,
        )) {
          resumeId = null;
          retries++;
          continue;
        }
        stopwatch.stop();
        yield LlmRunFailed(
          callId: callId,
          duration: stopwatch.elapsed,
          failure: LlmFailure(
            // Unclassified here; the caller maps onto its failure taxonomy.
            classCode: 'unknown',
            message: message,
            cause: caught,
          ),
          report: _buildReport(
            prompt: prompt,
            modelId: modelId,
            retries: retries,
            wallClockMs: stopwatch.elapsedMilliseconds,
          ),
        );
        return;
      }

      // ── Stream closed without a terminal `result` message ──
      if (result == null) {
        stopwatch.stop();
        yield LlmRunFailed(
          callId: callId,
          duration: stopwatch.elapsed,
          failure: const LlmFailure(
            classCode: 'format',
            message:
                'Agent SDK stream ended without a terminal result message.',
          ),
          report: _buildReport(
            prompt: prompt,
            modelId: modelId,
            retries: retries,
            wallClockMs: stopwatch.elapsedMilliseconds,
          ),
        );
        return;
      }

      final resolved = result;
      // The stopwatch, not `resolved.durationMs`: the SDK reports how long
      // *this attempt* took on the backend, which on a retry omits both the
      // failed first attempt and the wait between them. `wallClockMs` is the
      // caller's total, and the stopwatch has been running since submission.
      // Deliberately read without stopping it — the costed-error branch below
      // may still `continue` into a retry, and a stopped stopwatch would then
      // exclude everything that followed.
      final report = _buildReport(
        prompt: prompt,
        modelId: modelId,
        retries: retries,
        wallClockMs: stopwatch.elapsedMilliseconds,
        tokensIn: _usageTokens(resolved.usage, 'input_tokens'),
        tokensOut: _usageTokens(resolved.usage, 'output_tokens'),
        cost: resolved.totalCostUsd,
      );

      // ── Costed error result ──
      if (resolved.isError) {
        final message =
            resolved.result ?? 'Agent SDK reported an error result.';
        if (await _shouldRetryFresh(
          resumeId: resumeId,
          retries: retries,
          emittedChunk: emittedChunk,
          message: message,
          options: options,
        )) {
          resumeId = null;
          retries++;
          continue;
        }
        stopwatch.stop();
        yield LlmRunFailed(
          callId: callId,
          duration: stopwatch.elapsed,
          failure: LlmFailure(classCode: 'unknown', message: message),
          report: report,
        );
        return;
      }

      // ── Success ── record the Claude session id so a later call of the same
      // session (mode `brain`) can resume it. No-op in modes `none` / `quest`.
      stopwatch.stop();
      final claudeSessionId = resolved.sessionId;
      if (claudeSessionId != null && claudeSessionId.isNotEmpty) {
        await sessionStrategy.record(options, claudeSessionId);
      }
      yield LlmRunCompleted(
        callId: callId,
        duration: stopwatch.elapsed,
        report: report,
      );
      return;
    }
  }

  /// Whether a failed *resumed* call should evict its stored session id and be
  /// retried once with a fresh session. Only fires when a session id was being
  /// resumed, no chunk has yet streamed (so the retry cannot duplicate output),
  /// [retries] is still 0 (the retry is allowed once), and the failure looks
  /// session-shaped. Evicts the stored id as a side effect when it returns
  /// true.
  Future<bool> _shouldRetryFresh({
    required String? resumeId,
    required int retries,
    required bool emittedChunk,
    required String message,
    required LlmOptions options,
  }) async {
    if (resumeId == null ||
        retries > 0 ||
        emittedChunk ||
        !agentSdkLooksLikeSessionError(message)) {
      return false;
    }
    await sessionStrategy.evict(options);
    return true;
  }

  /// Builds an [LlmCallReport] with the provider-invariant fields filled:
  /// provenance (`providerId` = [id]), the anchor stamp
  /// (`anchorHash` = the prompt's), the body hash, and the prompt's
  /// `templateSha`.
  ///
  /// [retries] is required rather than defaulted, because a default is what let
  /// every report claim a first-shot success: the caller holds the count and is
  /// the only one that can tell a retried call from a fresh one.
  LlmCallReport _buildReport({
    required WirePrompt prompt,
    required String modelId,
    required int retries,
    required int wallClockMs,
    int tokensIn = 0,
    int tokensOut = 0,
    double? cost,
  }) {
    return LlmCallReport(
      providerId: id,
      modelId: modelId,
      anchorHash: prompt.anchorHash,
      promptHash: promptSha256(prompt.combined),
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      retries: retries,
      wallClockMs: wallClockMs,
      cost: cost,
      templateSha: prompt.templateSha,
    );
  }

  /// Reads an integer token count out of the SDK result's `usage` map; 0 when
  /// the field is absent or non-numeric.
  static int _usageTokens(Map<String, dynamic>? usage, String key) =>
      (usage?[key] as num?)?.toInt() ?? 0;

  /// A per-call id unique enough for trail correlation:
  /// `agentsdk-<id>-<micros>-<32-bit prompt hash>`.
  String _newCallId(WirePrompt prompt) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'agentsdk-$id-$now-${prompt.combined.hashCode.toUnsigned(32)}';
  }
}

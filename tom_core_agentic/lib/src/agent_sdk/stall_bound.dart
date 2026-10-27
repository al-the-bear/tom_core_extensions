/// The liveness bound, applied where **every** transport passes.
///
/// Held in `CliServerAiChannel`, which both transports hold, it would be true
/// of two classes, not of the seam: a third `AgentSdkServerTransport` that
/// never constructs a channel — one speaking HTTP to a hosted endpoint, one
/// wrapping a local model — would satisfy the interface completely and be
/// unbounded in the one dimension no completion may violate. So the bound is
/// here, as a function the provider
/// applies over whatever stream a transport returns. A transport cannot escape
/// it; it can only feed it, by emitting [AgentSdkLiveness] while its far end
/// is alive and silent. The channel keeps the wire framing and nothing else.
library;

import 'dart:async';

import 'package:tom_llm/tom_llm.dart';

import 'transport/transport.dart';

/// How long a completion may go without hearing anything at all before it is
/// declared stalled.
///
/// A **gap**, not a total budget — see [boundedAiRun] for why that
/// distinction is the whole design. The bound is reset by *any*
/// [AgentSdkCompletionEvent]: a delta, or the liveness a transport reports
/// for `system/init`, a partial message, a tool call or an announced retry.
///
/// **Measured, 2026-09-28.** The largest silence between two consecutive
/// messages of a real completion was **8.3 s**: a pause between
/// `thinking_delta` bursts of Opus 4.5 (Agent SDK 0.1.77, which the
/// standalone server pinned at the time) thinking on a 32k budget over a
/// 170k-token context — the size the context assembler is allowed to
/// reach. The other long silence is prefill, before `message_start`: 1.8 s at
/// 50k tokens, 7.8 s at 170k. Over the hosted path (Agent SDK 0.3.282, Opus
/// 5.5, 223k tokens, 16k thinking budget) the largest gap was 2.2 s, because
/// that SDK also emits `system/thinking_tokens` progress events while the
/// model thinks. A 188-second completion arrived with no gap above 8.3 s —
/// which is why this is a gap and not a budget: a one-minute budget would have
/// killed it.
///
/// **Re-measured, 2026-10-01**, with Agent SDK 0.3.286 and Opus 5.5 over a
/// ~170k-token context and a 32k thinking budget: largest gap 1.9 s over the
/// standalone server and 4.5 s over the hosted one (the prefill, before
/// `message_start`); prefill 4.7 s and 7.6 s. Well inside the margin below.
///
/// **Why 120 s.** Ten times the measured maximum is the floor (a test pins
/// it): the bound has to sit far enough above ordinary silence that API load
/// and larger thinking budgets do not read as death. The cost of the margin is
/// only how long a genuinely dead far end takes to be reported.
///
/// **Rechecking it.** The figure has to be re-measured whenever the SDK, the
/// model or a transport changes, and one command does it for both transports:
/// `AGENT_SDK_LIVE_MEASURE=1 AGENT_SDK_LIVE_HOSTED=1 dart test
/// test/agent_sdk/stall_gap_measure_live_test.dart`
/// (about 170k input tokens per transport; drop `AGENT_SDK_LIVE_HOSTED` to
/// measure the standalone server alone). It prints the largest gap and the
/// prefill, and fails when the largest gap exceeds a tenth of this bound.
///
/// All of that holds only because the CLI-server query sets
/// `includePartialMessages` — without it a thinking model is silent until its
/// answer is complete, and this constant would be a cap on model latency
/// wearing the name of a liveness bound.
const defaultAiStallTimeout = Duration(seconds: 120);

/// [events] as the run's trail: [prelude] first, then every
/// [AgentSdkTrailed] event in order, ending in exactly one
/// [LlmRunEnded] — the far end's, `completed` when the stream ends
/// without one, `failed` after a [LlmRunError] when it fails, and
/// `timeout` after a [LlmStall] when nothing at all arrives for
/// [stallGap]. The stream itself never errors: a failure is part of the
/// trail. [onFailure] observes a transport failure (the provider closes the
/// availability gate on `unreachable`); [onUnmapped] is told, once per run, of each
/// message type it does not map.
///
/// **Why a bound exists at all.** The far end can accept a query and then
/// stay silent far longer than any caller should wait. That is not
/// hypothetical: with an invalid credential Agent SDK 0.1.77 emitted
/// `system/init` and then said nothing for about three minutes while it
/// retried the 401 invisibly, reporting only afterwards a failure the
/// Anthropic API itself states in a fifth of a second. 0.3.286, which the
/// standalone server now pins, announces each retry instead (the channel acts
/// on a stated 401), but the bound does not exist for that one defect: any
/// far end can die mid-run. Without it the stream never closes, the caller
/// waits forever, and the availability gate — which reacts only to a
/// *reported* failure — never learns anything is wrong.
///
/// **Why a gap and not a total budget.** A total budget would cut off long
/// completions, which are exactly the ones worth waiting for; a gap bound
/// fires only when nothing at all has arrived, which is the condition we
/// actually mean. Every event resets it — [AgentSdkLiveness] as much as a
/// delta — so a model that is thinking out loud is never mistaken for one
/// that has died.
///
/// **Why it is not `unreachable`.** A stalled completion says nothing about
/// the server, which is up and answering; closing the availability gate would hide every
/// AI affordance in the app because one request went quiet.
///
/// **Why a controller and not an `async*`.** The seam promises that cancelling
/// the subscription aborts the remote completion, and that promise has to
/// survive this layer: the stall itself is a cancellation of the transport's
/// stream, and a caller's cancel must reach it while nothing is arriving —
/// precisely when an `async*` generator is suspended at an `await` it cannot
/// be resumed from. The abort on a stall is **not awaited**: a cancel that
/// itself hung would reinstate exactly the hang this bound exists to end.
Stream<LlmEvent> boundedAiRun(
  Stream<AgentSdkCompletionEvent> events, {
  required Duration stallGap,
  required String transportId,
  List<LlmEvent> prelude = const [],
  void Function(LlmTransportException failure)? onFailure,
  void Function(String messageType)? onUnmapped,
}) {
  final controller = StreamController<LlmEvent>();
  StreamSubscription<AgentSdkCompletionEvent>? subscription;
  Timer? stall;
  final clock = Stopwatch();
  final unmapped = <String>{};
  // The run's account, so the run it ends carries its report (and, failed,
  // the reason) whichever way it ends.
  final account = LlmRunAccount(providerId: transportId);
  prelude.forEach(account.observe);

  void stopClock() {
    stall?.cancel();
    stall = null;
  }

  /// Ends the run with [events] and aborts the remote query by cancelling the
  /// transport's stream. Reported first, cancelled second: the caller already
  /// has its answer, and a cancel that itself hung would reinstate the hang.
  void end(List<LlmEvent> events) {
    stopClock();
    if (controller.isClosed) return;
    events.forEach(controller.add);
    unawaited(controller.close());
    final sub = subscription;
    subscription = null;
    if (sub != null) unawaited(sub.cancel());
  }

  LlmRunEnded ended(LlmRunOutcome outcome, {LlmRunError? error}) => account.end(
    outcome,
    duration: clock.elapsed,
    failure: error == null
        ? null
        : LlmFailure(classCode: error.errorKind.name, message: error.message),
  );

  /// Ends the run because nothing has arrived for [stallGap].
  void abandonAsStalled() {
    final error = LlmRunError(
      LlmErrorKind.timeout,
      'The AI server accepted the request and then sent nothing for '
      '${_describe(stallGap)}.',
    );
    end([
      LlmStall(stallGap),
      error,
      ended(LlmRunOutcome.timeout, error: error),
    ]);
  }

  /// Restarts the silence clock. Called for **every** event, not only text.
  void noteLiveness() {
    stall?.cancel();
    stall = Timer(stallGap, abandonAsStalled);
  }

  controller.onListen = () {
    clock.start();
    prelude.forEach(controller.add);
    subscription = events.listen(
      (event) {
        if (controller.isClosed) return;
        noteLiveness();
        switch (event) {
          case AgentSdkTrailed(:final event):
            account.observe(event);
            if (event is LlmRunEnded) {
              // The far end's own end, with its turn count; nothing follows.
              end([event]);
              return;
            }
            controller.add(event);
          case AgentSdkLiveness(:final unmappedType?):
            if (unmapped.add(unmappedType)) onUnmapped?.call(unmappedType);
          case AgentSdkLiveness():
            break;
        }
      },
      onError: (Object error, StackTrace stack) {
        if (controller.isClosed) return;
        final failure = error is LlmTransportException
            ? error
            : LlmTransportException(
                LlmErrorKind.protocol,
                'The AI transport failed (${error.runtimeType}).',
                transportId: transportId,
                cause: error,
              );
        onFailure?.call(failure);
        final reported = LlmRunError(failure.kind, failure.message);
        end([reported, ended(LlmRunOutcome.failed, error: reported)]);
      },
      onDone: () => end([ended(LlmRunOutcome.completed)]),
    );
    // Armed only once the transport's stream is being listened to, so the
    // clock measures the far end's silence rather than our own setup.
    noteLiveness();
  };

  controller.onCancel = () async {
    stopClock();
    final sub = subscription;
    subscription = null;
    await sub?.cancel();
  };

  return controller.stream;
}

/// `120 s` for the production bound, `300 ms` for a test's.
String _describe(Duration gap) =>
    gap.inSeconds >= 1 ? '${gap.inSeconds} s' : '${gap.inMilliseconds} ms';

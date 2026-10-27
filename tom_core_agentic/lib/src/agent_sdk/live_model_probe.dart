/// The live-AI gate, stated once.
///
/// **A satisfied gate is not a credentialed backend.** `AGENT_SDK_LIVE` and
/// `AGENT_SDK_LIVE_HOSTED` mean "a transport should be reachable", and a
/// reachable transport can still have no model behind it: on 2026-09-22 a VS
/// Code CLI server with no Anthropic credential available accepted the query
/// and sent nothing, and the suite waited out the full stall bound (60–120 s)
/// to report a `timeout` — a red run that said the wrong thing.
///
/// So a live suite asks first, once: one tiny completion with a short bound.
/// Three answers:
///
/// - **answered** — a model replied; run the suite.
/// - **no model** — the transport connected and nothing answered within the
///  bound, or the far end refused on authentication. The suite SKIPS, with a
///  reason naming the credential and where each transport takes it from.
/// - **unreachable** — the transport itself could not be reached. That is what
///  the variable asked to be true, so it stays a FAILURE: a finding, not a
///  reason to skip.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tom_llm/tom_llm.dart';

import 'transport/transport.dart';

/// How long the probe waits for the first word of an answer.
///
/// Measured 2026-09-30, standalone over Node 20:
///
/// - credentialed (ambient Claude Code login): **answered after 2.3–2.6 s**,
///  start-up included — the whole cost a working run pays;
/// - an unusable key (the pinned Agent SDK retries the 401 silently):
///  **"no model" after exactly the bound**, 10.2 s at a 10 s bound; the
///  a test suite then skipped both tests after 30 s, where it had
///  failed after two 120 s stalls.
///
/// Thirty seconds is an order of magnitude over the answered case and a
/// quarter of the stall bound the uncredentialed run used to wait out.
const agentSdkProbeBound = Duration(seconds: 30);

enum AgentSdkProbeOutcome { answered, noModel, unreachable }

/// What the probe found, and how long finding it took.
final class AgentSdkProbe {
  final AgentSdkProbeOutcome outcome;
  final Duration elapsed;

  /// The sentence a skip or a failure carries.
  final String detail;

  const AgentSdkProbe(this.outcome, this.elapsed, this.detail);

  bool get answered => outcome == AgentSdkProbeOutcome.answered;

  @override
  String toString() => '$outcome after ${elapsed.inMilliseconds} ms: $detail';
}

/// Where each transport takes its credential from, for the skip reason.
const _credentialHint =
    'the hosted transport uses the Anthropic credential of the VS Code '
    'extension running the CLI server; the standalone one uses '
    'the key it is given and nothing else, or, with none, ANTHROPIC_API_KEY '
    'or the ambient Claude Code login';

/// Runs one tiny completion through [transport] and closes it.
///
/// [transport] must be a fresh instance: the probe owns it and closes it, so a
/// suite builds its own for the real tests. [bound] limits the wait for the
/// first text of the answer — the probe asks whether a model is there, not
/// how well it writes.
@visibleForTesting
Future<AgentSdkProbe> probeAgentSdkModel(
  AgentSdkServerTransport transport, {
  Duration bound = agentSdkProbeBound,
}) async {
  final clock = Stopwatch()..start();
  try {
    try {
      await transport.connect();
    } on LlmTransportException catch (e) {
      return AgentSdkProbe(
        AgentSdkProbeOutcome.unreachable,
        clock.elapsed,
        e.message,
      );
    }
    try {
      final first = await transport
          .complete(
            const AgentSdkCompletionRequest(
              prompt: 'Reply with the single word OK.',
            ),
          )
          .map(
            (event) => switch (event) {
              AgentSdkTrailed(event: LlmTextDelta(:final text)) => text,
              _ => '',
            },
          )
          .where((text) => text.trim().isNotEmpty)
          .first
          .timeout(bound);
      return AgentSdkProbe(
        AgentSdkProbeOutcome.answered,
        clock.elapsed,
        'a model answered ("${first.trim()}")',
      );
    } on TimeoutException {
      return AgentSdkProbe(
        AgentSdkProbeOutcome.noModel,
        clock.elapsed,
        'the ${transport.id} transport connected, but no model answered within '
        '${bound.inSeconds} s — usually no Anthropic credential is available '
        'to it ($_credentialHint)',
      );
    } on StateError {
      // The stream ended with no text at all.
      return AgentSdkProbe(
        AgentSdkProbeOutcome.noModel,
        clock.elapsed,
        'the ${transport.id} transport connected and ended its answer empty — '
        'usually no Anthropic credential is available to it '
        '($_credentialHint)',
      );
    } on LlmTransportException catch (e) {
      if (e.kind == LlmErrorKind.unreachable) {
        return AgentSdkProbe(
          AgentSdkProbeOutcome.unreachable,
          clock.elapsed,
          e.message,
        );
      }
      return AgentSdkProbe(
        AgentSdkProbeOutcome.noModel,
        clock.elapsed,
        'the ${transport.id} transport connected, but the model did not '
        'answer (${e.kind.name}: ${e.message}) — check the Anthropic '
        'credential ($_credentialHint)',
      );
    }
  } finally {
    await transport.close();
  }
}

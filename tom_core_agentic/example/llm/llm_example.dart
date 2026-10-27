// Runnable demo of the LLM provider seam, written from the implementer's side.
//
// The unit is a contract other people implement, so the useful demo is not
// "call a provider" — it is "write one, and see what the contract actually
// demands". `EchoProvider` below is a complete, correct implementation in
// about fifty lines: it streams, it reports, and it obeys the three invariants
// an implementer most easily breaks.
//
//   1. **The anchor stamp.** Every report carries the prompt's `anchorHash`
//      unchanged, so a conformance check can prove from reports alone that the
//      anchor was present on every emitted prompt.
//   2. **No prompt mutation.** The body goes to the backend as it arrived. A
//      provider translates the shape, never the text.
//   3. **One route, announced once.** `LlmRunStarted` carries the same
//      `providerId` and `modelId` as the terminal report, because consumers log
//      the route from the first event and a stream that opens on one route and
//      completes on another makes the two disagree.
//
// The demo then drives the provider through both entry points and shows the
// third thing an implementer gets wrong: `complete()` surfaces a failure as an
// **exception**, while `run()` surfaces the same failure as a terminal
// `LlmRunFailed` event carrying a report. A provider implements `run` only:
// `complete` is the contract's own buffering of it.
//
// No network and no API key: the provider echoes. That is the point — the
// seam is what is being demonstrated, and a real backend would only add noise
// to it.
//
// Run with:
//   dart run --enable-asserts example/llm/llm_example.dart

import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../require_asserts.dart';

Future<void> main() async {
  requireAsserts();
  await _demoStreaming();
  await _demoComplete();
  await _demoFailure();
  _demoWirePrompt();

  print('\nllm demo completed.');
}

// ---------------------------------------------------------------------------
// A complete provider. Everything below the constructor is contract.
// ---------------------------------------------------------------------------
final class EchoProvider extends LlmProvider {
  EchoProvider({this.id = 'echo', this.defaultModel = 'echo-1', this.fail});

  @override
  final String id;

  /// The route default, used when the call does not override it. The *resolved*
  /// id — not this field — is what every event and the report must carry.
  final String defaultModel;

  /// When set, every call fails with this message instead of echoing. A real
  /// provider fails because its backend did; this one fails on request, so the
  /// demo can show both terminal shapes.
  final String? fail;

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    final stopwatch = Stopwatch()..start();
    // Resolved once and used everywhere: the started event, the report, and —
    // in a real provider — the backend request. Resolving it twice is how the
    // opening event and the report come to disagree.
    final modelId = options.model ?? defaultModel;
    final callId = 'echo-${DateTime.now().microsecondsSinceEpoch}';

    yield LlmRunStarted(callId: callId, providerId: id, modelId: modelId);

    if (fail == null) {
      // The body goes out unchanged. `combined` is what a backend with no
      // channel separation sends, and it begins with the anchor because
      // `system` leads it.
      for (final line in prompt.combined.split('\n')) {
        yield LlmTextDelta('$line\n');
      }
    }

    stopwatch.stop();
    final report = _report(prompt, modelId, stopwatch.elapsedMilliseconds);

    if (fail != null) {
      yield LlmRunFailed(
        callId: callId,
        // `unknown` because this provider cannot classify what its backend
        // meant; the caller maps it onto its own taxonomy.
        failure: LlmFailure(classCode: 'unknown', message: fail!),
        // A failed call is still attributable: the report says which route
        // burned the wall-clock.
        report: report,
      );
      return;
    }

    yield LlmRunCompleted(callId: callId, report: report);
  }

  LlmCallReport _report(WirePrompt prompt, String modelId, int elapsedMs) =>
      LlmCallReport(
        providerId: id,
        modelId: modelId,
        // The two stamps a conformance check reads.
        anchorHash: prompt.anchorHash,
        promptHash: promptSha256(prompt.combined),
        tokensIn: 0,
        tokensOut: 0,
        // No retry happened. A provider that retried would say so here, and
        // `wallClockMs` would span the wait.
        retries: 0,
        wallClockMs: elapsedMs,
        // Null, not zero: no price is known for this route, and a zero would
        // read as a free call.
        cost: null,
        templateSha: prompt.templateSha,
      );
}

/// A prompt shaped the way a producer hands one over: anchor-first `system`,
/// call-specific `user`, and the anchor's hash carried beside them.
WirePrompt _prompt() => const WirePrompt(
  system: 'ANCHOR-BLOCK\n\nYou answer briefly.',
  user: 'What is the seam for?',
  anchorHash: 'sha256:anchor',
  roleId: 'demo_role',
  templateSha: 'abc123',
);

// ---------------------------------------------------------------------------
// run: the event contract, asserted.
// ---------------------------------------------------------------------------
Future<void> _demoStreaming() async {
  print('== run ==');

  final provider = EchoProvider();
  final prompt = _prompt();
  // A per-call model override, deliberately: under default options the route
  // default and the resolved id are the same string, so a provider that
  // resolved the model twice — once for the opening event, once for the
  // report — would look correct here. The override is what makes the
  // agreement below mean something.
  final events = await provider
      .run(
        LlmRequest(
          prompt: prompt,
          options: const LlmOptions(model: 'echo-2'),
        ),
      )
      .toList();

  // Exactly one Started, first.
  assert(events.first is LlmRunStarted);
  assert(events.whereType<LlmRunStarted>().length == 1);

  // Exactly one terminal event, last.
  final terminal = events.last;
  assert(terminal is LlmRunCompleted);
  assert(events.whereType<LlmRunCompleted>().length == 1);
  assert(events.whereType<LlmRunFailed>().isEmpty);

  final started = events.first as LlmRunStarted;
  final completed = terminal as LlmRunCompleted;

  // The route is announced once and does not change under the caller.
  assert(started.providerId == completed.report.providerId);
  assert(started.modelId == completed.report.modelId);
  assert(started.callId == completed.callId);
  assert(started.modelId == 'echo-2');
  print(
    '  route: ${started.providerId}/${started.modelId} '
    '(${events.whereType<LlmTextDelta>().length} chunks, '
    'route default is ${provider.defaultModel})',
  );

  // The body came back unchanged — no provider prepended or reordered it.
  final echoed = events
      .whereType<LlmTextDelta>()
      .map((c) => c.text)
      .join()
      .trimRight();
  assert(echoed == prompt.combined);

  // The anchor stamp, which is what a conformance check reads.
  assert(completed.report.anchorHash == prompt.anchorHash);
  assert(completed.report.promptHash == promptSha256(prompt.combined));
  assert(completed.report.templateSha == prompt.templateSha);
  assert(completed.report.cost == null);
  print(
    '  report: anchor ${completed.report.anchorHash}, '
    'retries ${completed.report.retries}, cost ${completed.report.cost}',
  );
}

// ---------------------------------------------------------------------------
// complete: the same call, buffered.
// ---------------------------------------------------------------------------
Future<void> _demoComplete() async {
  print('\n== complete ==');

  final provider = EchoProvider();
  final prompt = _prompt();

  // A per-call model override. The resolved id — not the route default — is
  // what the report must carry.
  final report = await provider.complete(
    LlmRequest(
      prompt: prompt,
      options: const LlmOptions(model: 'echo-2'),
    ),
  );

  assert(report.providerId == 'echo');
  assert(report.modelId == 'echo-2');
  assert(report.anchorHash == prompt.anchorHash);
  print('  resolved model: ${report.modelId} (route default is echo-1)');
}

// ---------------------------------------------------------------------------
// The two failure shapes. One contract, two entry points.
// ---------------------------------------------------------------------------
Future<void> _demoFailure() async {
  print('\n== failure ==');

  final provider = EchoProvider(fail: 'backend refused the request');
  final prompt = _prompt();

  // Streaming: a terminal event, carrying the failure *and* a report. The call
  // is attributable even though it produced no answer.
  final events = await provider
      .run(LlmRequest(prompt: prompt, options: LlmOptions.empty))
      .toList();
  final failed = events.last as LlmRunFailed;
  assert(events.whereType<LlmTextDelta>().isEmpty);
  assert(failed.failure.classCode == 'unknown');
  assert(failed.report!.anchorHash == prompt.anchorHash);
  print(
    '  run      -> ${failed.failure.classCode}: '
    '${failed.failure.message}',
  );

  // Buffered: the same failure, as an exception.
  Object? thrown;
  try {
    await provider.complete(
      LlmRequest(prompt: prompt, options: LlmOptions.empty),
    );
  } catch (e) {
    thrown = e;
  }
  assert(thrown != null);
  print('  complete -> threw ${thrown.runtimeType}');
}

// ---------------------------------------------------------------------------
// Why `combined` is safe to send: the anchor leads it.
// ---------------------------------------------------------------------------
void _demoWirePrompt() {
  print('\n== wire prompt ==');

  const anchored = WirePrompt(
    system: 'ANCHOR-BLOCK\n\nframing',
    user: 'inputs',
    anchorHash: 'sha256:anchor',
    roleId: 'demo_role',
  );
  // Two channels, joined with a blank line, system first.
  assert(anchored.combined == 'ANCHOR-BLOCK\n\nframing\n\ninputs');
  assert(anchored.combined.startsWith('ANCHOR-BLOCK'));

  // A system-only role carries no user channel, and `combined` drops the empty
  // part rather than leaving a trailing separator.
  const systemOnly = WirePrompt(
    system: 'ANCHOR-BLOCK\n\nframing',
    anchorHash: 'sha256:anchor',
    roleId: 'demo_role',
  );
  assert(systemOnly.user.isEmpty);
  assert(systemOnly.combined == 'ANCHOR-BLOCK\n\nframing');

  // `templateSha` is optional and stays null rather than becoming "unknown" —
  // the report copies whatever the prompt carried.
  assert(systemOnly.templateSha == null);
  print('  combined starts with the anchor, empty channels dropped');
}

/// The liveness bound holds for a transport that never
/// constructs a channel.
///
/// Held in `CliServerAiChannel`, which both transports hold, the bound would
/// be true of two classes, not of the seam. These tests drive
/// `AgentSdkSessionProvider` over a fake `AgentSdkServerTransport` that owns no
/// socket, no channel and no child — the shape a future HTTP or local-model
/// transport would have — and prove that the provider's clock abandons it,
/// counts its liveness, measures gaps rather than runs, and leaves the availability gate
/// open. "No completion is unbounded" is a statement about every completion;
/// this is the test that makes it one.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';
import 'support/requests.dart';
import 'support/sessions.dart';

/// A transport with no wire behind it: [complete] returns whatever stream the
/// test scripted, and records whether that stream was cancelled.
class _ScriptedTransport implements AgentSdkServerTransport {
  /// Lives only where it was made: its state is the test's.
  @override
  AgentSdkServerTransport Function()? get sessionCopy => null;

  _ScriptedTransport(this.script);

  /// Builds the completion's stream; called once per [complete].
  final Stream<AgentSdkCompletionEvent> Function(void Function() onCancel)
  script;

  int cancels = 0;
  bool _connected = false;

  @override
  String get id => 'scripted';

  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    maxContextTokens: 1000,
  );

  @override
  bool get isConnected => _connected;

  @override
  String? get unavailableReason => null;

  @override
  String? get selectionNotice => null;

  @override
  Future<bool> probe() async => true;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) =>
      script(() => cancels++);

  @override
  Future<void> close() async => _connected = false;
}

/// A stream that emits [events] at [every], then closes; a cancellation that
/// arrives **before** the stream has finished — an abort — is reported to
/// [onCancel]. (A controller's `onCancel` also runs when the listener is
/// released after `done`, which is not an abort.)
Stream<AgentSdkCompletionEvent> _drip(
  List<AgentSdkCompletionEvent> events,
  Duration every,
  void Function() onCancel,
) {
  final controller = StreamController<AgentSdkCompletionEvent>();
  Timer? timer;
  var index = 0;
  var finished = false;
  controller.onListen = () {
    timer = Timer.periodic(every, (t) {
      if (index == events.length) {
        t.cancel();
        finished = true;
        unawaited(controller.close());
        return;
      }
      controller.add(events[index++]);
    });
  };
  controller.onCancel = () {
    timer?.cancel();
    if (!finished) onCancel();
  };
  return controller.stream;
}

/// A stream that accepts the listener and then says nothing, ever.
Stream<AgentSdkCompletionEvent> _silence(void Function() onCancel) {
  final controller = StreamController<AgentSdkCompletionEvent>();
  controller.onCancel = onCancel;
  return controller.stream;
}

Future<AgentSdkSessionProvider> _providerOver(
  AgentSdkServerTransport transport, {
  Duration? stallGap,
}) async {
  final selector = AgentSdkTransportSelector([transport]);
  await selector.initialize();
  expect(selector.isAvailable, isTrue);
  return stallGap == null
      ? AgentSdkSessionProvider(
          sessions: testSessions(inProcess: true),
          selector: selector,
          toolServerName: 'tools',
        )
      : AgentSdkSessionProvider(
          sessions: testSessions(inProcess: true),
          selector: selector,
          stallGap: stallGap,
          toolServerName: 'tools',
        );
}

final _request = testRequest(purpose: 'generate', instruction: 'x');

void main() {
  test(
    'a transport that accepts and never speaks is abandoned '
    'as timeout, with no channel anywhere, and the abort reaches it',
    () async {
      final transport = _ScriptedTransport(_silence);
      final provider = await _providerOver(
        transport,
        stallGap: const Duration(milliseconds: 200),
      );

      final started = DateTime.now();
      await expectLater(
        llmAnswerText(provider.run(_request)).toList(),
        throwsA(
          isA<LlmTransportException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.timeout)
              .having((e) => e.transportId, 'transportId', 'scripted')
              .having((e) => e.message, 'message', contains('200 ms')),
        ),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
      );
      expect(
        transport.cancels,
        1,
        reason:
            'giving up locally must cancel the transport\'s stream — that '
            'is how the seam aborts the remote completion',
      );
    },
  );

  test('a stall leaves the availability gate open', () async {
    final transport = _ScriptedTransport(_silence);
    final provider = await _providerOver(
      transport,
      stallGap: const Duration(milliseconds: 100),
    );

    await expectLater(
      llmAnswerText(provider.run(_request)).toList(),
      throwsA(isA<LlmTransportException>()),
    );
    expect(
      provider.isAvailable,
      isTrue,
      reason:
          'a stalled completion says nothing about the server; only '
          '`unreachable` closes the gate',
    );
    expect(provider.unavailableReason, isNull);
  });

  test('liveness without text keeps a completion alive past the '
      'gap several times over', () async {
    // Five beats of thinking at 100 ms, then the answer: the run outlasts a
    // 250 ms gap three times, and no single silence reaches it.
    final transport = _ScriptedTransport(
      (onCancel) => _drip(
        [
          for (var i = 0; i < 5; i++) const AgentSdkLiveness('stream_event'),
          const AgentSdkTrailed(LlmTextDelta('thought it through.')),
        ],
        const Duration(milliseconds: 100),
        onCancel,
      ),
    );
    final provider = await _providerOver(
      transport,
      stallGap: const Duration(milliseconds: 250),
    );

    final deltas = await llmAnswerText(provider.run(_request)).toList();
    expect(deltas, [
      'thought it through.',
    ], reason: 'liveness is counted and dropped; only text is delivered');
    expect(transport.cancels, 0);
  });

  test('the bound measures the gap between events, not the run', () async {
    // Ten deltas at 100 ms: a whole run of ~1 s under a 300 ms bound. A total
    // budget would cut it off; a gap bound never fires.
    final transport = _ScriptedTransport(
      (onCancel) => _drip(
        [for (var i = 0; i < 10; i++) AgentSdkTrailed(LlmTextDelta('$i '))],
        const Duration(milliseconds: 100),
        onCancel,
      ),
    );
    final provider = await _providerOver(
      transport,
      stallGap: const Duration(milliseconds: 300),
    );

    final deltas = await llmAnswerText(provider.run(_request)).toList();
    expect(deltas.join().trim(), '0 1 2 3 4 5 6 7 8 9');
  });

  test('a far end that goes quiet after speaking is abandoned, '
      'and what it said is kept', () async {
    final transport = _ScriptedTransport((onCancel) {
      final controller = StreamController<AgentSdkCompletionEvent>();
      controller.onListen = () =>
          controller.add(const AgentSdkTrailed(LlmTextDelta('Hel')));
      controller.onCancel = onCancel;
      return controller.stream;
    });
    final provider = await _providerOver(
      transport,
      stallGap: const Duration(milliseconds: 150),
    );

    final deltas = <String>[];
    Object? failure;
    final done = Completer<void>();
    llmAnswerText(provider.run(_request)).listen(
      deltas.add,
      onError: (Object e) => failure = e,
      onDone: done.complete,
    );
    await done.future.timeout(const Duration(seconds: 2));
    expect(deltas, ['Hel']);
    expect(
      failure,
      isA<LlmTransportException>().having(
        (e) => e.kind,
        'kind',
        LlmErrorKind.timeout,
      ),
    );
    expect(transport.cancels, 1);
  });

  test('cancelling the provider\'s stream cancels the '
      'transport\'s, and the clock with it', () async {
    final transport = _ScriptedTransport(_silence);
    final provider = await _providerOver(
      transport,
      stallGap: const Duration(milliseconds: 200),
    );

    var errors = 0;
    final subscription = llmAnswerText(
      provider.run(_request),
    ).listen((_) {}, onError: (_) => errors++);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await subscription.cancel();
    expect(transport.cancels, 1);

    // Past the gap: a clock that outlived the cancel would now report a stall
    // to nobody — or worse, cancel the transport a second time.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(errors, 0);
    expect(transport.cancels, 1);
  });

  test('the provider\'s default gap is the measured constant', () async {
    final provider = await _providerOver(_ScriptedTransport(_silence));
    expect(provider.stallGap, defaultAiStallTimeout);
    expect(defaultAiStallTimeout, const Duration(seconds: 120));
  });
}

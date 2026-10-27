/// Graceful degradation.
///
///  makes `isAvailable` the single gate and requires that an unreachable
/// backend produce a hidden or disabled affordance, **never a failing call**.
/// That is two obligations, and they pull in opposite directions:
///
/// - the app stays fully usable with nothing reachable, so selection must not
///  throw and the gate must answer honestly; and
/// - the user is told once, not once per keystroke, so the notice must be tied
///  to a state transition rather than to a read of the gate.
///
/// The second is the one a naive implementation gets wrong, so it is tested by
/// hammering the gate the way a Flutter rebuild would and counting notices.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/requests.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/sessions.dart';

/// A transport that is never reachable, and counts how often it was asked.
class _DeadTransport implements AgentSdkServerTransport {
  /// Lives only where it was made: its state is the test's.
  @override
  AgentSdkServerTransport Function()? get sessionCopy => null;

  @override
  final String id;

  /// How many times [probe] was called — the cost of asking, made visible.
  int probes = 0;
  int connects = 0;
  int closes = 0;

  _DeadTransport(this.id);

  @override
  LlmCapabilities get capabilities => LlmCapabilities.none;
  @override
  bool get isConnected => false;

  /// **Silent by default**, which is the point for the fallback tests: this
  /// double exercises what the selector says for a transport that records no
  /// reason of its own. Settable so a test can also check what it says
  /// when there IS one.
  @override
  String? unavailableReason;
  @override
  String? get selectionNotice => null;

  @override
  Future<bool> probe() async {
    probes++;
    return false;
  }

  @override
  Future<void> connect() async {
    connects++;
    throw LlmTransportException(
      LlmErrorKind.unreachable,
      'nothing is listening',
      transportId: id,
    );
  }

  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) =>
      Stream.error(
        LlmTransportException(
          LlmErrorKind.unreachable,
          'nothing is listening',
          transportId: id,
        ),
      );

  @override
  Future<void> close() async => closes++;
}

/// Reachable on probe, but fails on connect — the "server went away between
/// the scan and the handshake" case, which must degrade like any other.
class _FlakyTransport extends _DeadTransport {
  _FlakyTransport(super.id);

  @override
  Future<bool> probe() async {
    probes++;
    return true;
  }
}

/// A transport that can be switched between failing and working.
///
/// The flip is what makes the retained-reason tests non-vacuous: a reason can
/// only be shown to be CLEARED if it was set first, and a second failure can
/// only be shown to refresh it if its sentence differs from the first.
class _SwitchableTransport implements AgentSdkServerTransport {
  /// Lives only where it was made: its state is the test's.
  @override
  AgentSdkServerTransport Function()? get sessionCopy => null;

  @override
  String get id => 'switchable';

  bool available = false;
  @override
  String? unavailableReason;

  /// Starts unavailable: every test needs a reason to exist before
  /// it can assert anything about one, so "off" is the only useful default.
  _SwitchableTransport({this.unavailableReason});

  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    canUseTools: false,
    maxContextTokens: 1000,
  );
  @override
  bool get isConnected => available;
  @override
  String? get selectionNotice => null;
  @override
  Future<bool> probe() async => available;
  @override
  Future<void> connect() async {
    if (!available) {
      throw LlmTransportException(
        LlmErrorKind.unreachable,
        unavailableReason ?? 'not reachable',
        transportId: id,
      );
    }
  }

  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) =>
      const Stream<AgentSdkCompletionEvent>.empty();
  @override
  Future<void> close() async {}
}

/// A transport that works and has something to tell the user.
class _TalkativeTransport implements AgentSdkServerTransport {
  /// Lives only where it was made: its state is the test's.
  @override
  AgentSdkServerTransport Function()? get sessionCopy => null;

  @override
  String get id => 'talkative';

  /// Settable, because the interesting behaviour is what happens when it
  /// STOPS having something to say.
  String? notice;

  _TalkativeTransport(this.notice);

  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    canUseTools: false,
    maxContextTokens: 1000,
  );
  @override
  bool get isConnected => true;
  @override
  String? get unavailableReason => null;
  @override
  String? get selectionNotice => notice;
  @override
  Future<bool> probe() async => true;
  @override
  Future<void> connect() async {}
  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) =>
      const Stream<AgentSdkCompletionEvent>.empty();
  @override
  Future<void> close() async {}
}

/// A live transport that is unreachable *after* it was selected.
class _DropsMidUseTransport implements AgentSdkServerTransport {
  /// Lives only where it was made: its state is the test's.
  @override
  AgentSdkServerTransport Function()? get sessionCopy => null;

  @override
  String get id => 'drops-mid-use';
  @override
  LlmCapabilities get capabilities => const LlmCapabilities(
    canComplete: true,
    canEmbed: false,
    canUseTools: false,
    maxContextTokens: 1000,
  );
  @override
  bool get isConnected => true;
  @override
  String? get unavailableReason => null;
  @override
  String? get selectionNotice => null;
  @override
  Future<bool> probe() async => true;
  @override
  Future<void> connect() async {}
  @override
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request) =>
      Stream.error(
        LlmTransportException(
          LlmErrorKind.unreachable,
          'the server went away',
          transportId: 'drops-mid-use',
        ),
      );
  @override
  Future<void> close() async {}
}

void main() {
  group('nothing reachable — the app stays usable', () {
    test('initialize does not throw and leaves the gate closed', () async {
      final selector = AgentSdkTransportSelector([
        _DeadTransport('a'),
        _DeadTransport('b'),
      ]);
      await selector.initialize();
      addTearDown(selector.dispose);

      expect(selector.isAvailable, isFalse);
      expect(selector.active, isNull);
    });

    test('the provider reports unavailable and offers no capability', () async {
      final selector = AgentSdkTransportSelector([_DeadTransport('a')]);
      await selector.initialize();
      addTearDown(selector.dispose);

      final provider = AgentSdkSessionProvider(
        sessions: testSessions(inProcess: true),
        selector: selector,
        toolServerName: 'tools',
      );
      expect(provider.isAvailable, isFalse);
      expect(provider.capabilities.canComplete, isFalse);
      expect(provider.capabilities.canEmbed, isFalse);
      expect(provider.capabilities.canUseTools, isFalse);
      expect(provider.capabilities.maxContextTokens, 0);
    });

    test(
      'completing anyway is a caller error, not a crash mid-stream',
      () async {
        final selector = AgentSdkTransportSelector([_DeadTransport('a')]);
        await selector.initialize();
        addTearDown(selector.dispose);

        final provider = AgentSdkSessionProvider(
          sessions: testSessions(inProcess: true),
          selector: selector,
          toolServerName: 'tools',
        );
        expect(
          () => provider.complete(
            testRequest(purpose: 'generate', instruction: 'x'),
          ),
          throwsUnsupportedError,
        );
      },
    );

    test(
      'every candidate is probed, then given up on — no retry storm',
      () async {
        final a = _DeadTransport('a');
        final b = _FlakyTransport('b');
        final selector = AgentSdkTransportSelector([a, b]);
        await selector.initialize();
        addTearDown(selector.dispose);

        expect(a.probes, 1);
        expect(
          a.connects,
          0,
          reason:
              'a candidate that failed to probe is not '
              'then connected anyway',
        );
        expect(b.probes, 1);
        expect(b.connects, 1);
        expect(selector.isAvailable, isFalse);
      },
    );

    test('dispose closes candidates that were never selected', () async {
      final a = _DeadTransport('a');
      final b = _FlakyTransport('b');
      final selector = AgentSdkTransportSelector([a, b]);
      await selector.initialize();
      await selector.dispose();

      // b started nothing here, but a real standalone candidate that failed
      // after spawning would have a child to reap; the contract is that every
      // candidate is closed, selected or not.
      expect(a.closes, 1);
      expect(b.closes, 1);
    });
  });

  group('reported once, not per keystroke', () {
    test('a failed initialize emits exactly one notice', () async {
      final selector = AgentSdkTransportSelector([_DeadTransport('a')]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();

      expect(notices, hasLength(1));
      expect(notices.single.message, contains('unavailable'));
      expect(notices.single.message, contains('not reachable'));
    });

    test('a root with no transports is silent, not unreachable', () async {
      // Configuring none is a build decision, not an episode: the message
      // "no AI server could be reached" would be false, and a notice on every
      // launch of an AI-less build is noise about something nobody can fix.
      // The gate is shut either way, which is all the gate has to say.
      final selector = AgentSdkTransportSelector(const []);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();

      expect(selector.isAvailable, isFalse);
      expect(notices, isEmpty);
    });

    test('reading the gate 10,000 times emits nothing further', () async {
      final selector = AgentSdkTransportSelector([_DeadTransport('a')]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();
      notices.clear();

      // This is what a Flutter rebuild does: ask, cheaply, constantly.
      for (var i = 0; i < 10000; i++) {
        expect(selector.isAvailable, isFalse);
      }
      await pumpEventQueue();

      expect(notices, isEmpty);
    });

    test('the notice carries no credential and no document text', () async {
      final selector = AgentSdkTransportSelector([_DeadTransport('a')]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();

      // Diagnostics never leak a secret. The notice is assembled
      // from transport ids and transport messages, neither of which can carry
      // one — this asserts the assembled result rather than the intent.
      final rendered = notices.single.message;
      expect(rendered, isNot(contains('sk-ant')));
      expect(rendered, isNot(contains('ANTHROPIC_API_KEY')));
    });

    test('an explicit retry reports again, because the user asked', () async {
      final selector = AgentSdkTransportSelector([_DeadTransport('a')]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();
      expect(notices, hasLength(1));

      expect(await selector.retry(), isFalse);
      await pumpEventQueue();
      expect(
        notices,
        hasLength(2),
        reason:
            'silence in answer to a deliberate question is a bug, not '
            'restraint',
      );
    });

    test('a transport lost mid-use closes the gate and reports once', () async {
      final selector = AgentSdkTransportSelector([_DropsMidUseTransport()]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();
      expect(selector.isAvailable, isTrue);
      expect(notices, isEmpty);

      final provider = AgentSdkSessionProvider(
        sessions: testSessions(inProcess: true),
        selector: selector,
        toolServerName: 'tools',
      );
      await expectLater(
        llmAnswerText(
          provider.run(testRequest(purpose: 'generate', instruction: 'x')),
        ).toList(),
        throwsA(isA<LlmTransportException>()),
      );
      await pumpEventQueue();

      expect(
        selector.isAvailable,
        isFalse,
        reason: 'the affordance must now be hidden, not merely failing',
      );
      expect(notices, hasLength(1));

      // A second attempt cannot happen through the gate; if something tries
      // anyway, it is a caller error and still emits no second notice.
      expect(notices, hasLength(1));
    });
  });

  group('an unavailable gate can say why', () {
    test('the retained reason is the transport\'s own sentence, not '
        '"not reachable"', () async {
      // The gate is a boolean and the explanation is not. Before this, the
      // reason existed on the transport, was flattened into a one-shot notice,
      // and the disabled control said "no provider is reachable" — true of a
      // missing Node runtime, an unstarted CLI server and a build with no AI,
      // and actionable for none of them.
      final transport = _DeadTransport('hosted')
        ..unavailableReason =
            'VS Code is not serving AI: the CLI server does not start '
            'with the editor';
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      expect(
        selector.unavailableReason,
        isNull,
        reason: 'nothing has been asked yet',
      );
      await selector.initialize();

      expect(selector.isAvailable, isFalse);
      expect(selector.unavailableReason, contains('CLI server does not start'));
    });

    test('a successful selection clears a reason it had set', () async {
      // The first draft of this test put a dead transport in front of a live
      // one and asserted null afterwards — which passed with the clearing
      // REMOVED, because the loop returns on success before it ever records a
      // failure. The reason has to be set first for the clearing to be the
      // thing under test.
      final transport = _SwitchableTransport(
        unavailableReason: 'the CLI server is not started',
      );
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      await selector.initialize();
      expect(
        selector.unavailableReason,
        contains('not started'),
        reason: 'the precondition this test exists to then undo',
      );

      transport.available = true;
      expect(await selector.retry(), isTrue);
      expect(
        selector.unavailableReason,
        isNull,
        reason:
            'a stale explanation beside a working backend is worse than '
            'none — it would explain a control that is not disabled',
      );
    });

    test('no candidates is "not configured", not "nothing answered"', () async {
      // A build that ships without AI has not FAILED to reach anything. The
      // selector already declines to emit a notice for it; the reason has to
      // draw the same distinction or the user is told a backend let them down.
      final selector = AgentSdkTransportSelector([]);
      addTearDown(selector.dispose);

      await selector.initialize();
      expect(selector.unavailableReason, contains('not configured'));
      expect(selector.unavailableReason, isNot(contains('reach')));
    });

    test('the reason outlives the notice, which is consumed once', () async {
      // The two have different lifetimes on purpose: a notice interrupts and
      // is rate-limited, a reason only answers when asked and must stay
      // current for as long as the affordance is greyed out.
      final transport = _SwitchableTransport(
        unavailableReason: 'server not started',
      );
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      final seen = <AgentSdkNotice>[];
      final sub = selector.notices.listen(seen.add);
      addTearDown(sub.cancel);

      await selector.initialize();
      await pumpEventQueue();
      expect(seen, hasLength(1));

      // The second failure carries a DIFFERENT sentence, inside the same
      // episode. Asserting only that a reason survives three identical
      // failures would pass with the reason rate-limited alongside the notice,
      // because the first report sets it before the guard can matter.
      transport.unavailableReason = 'Node 16 is below the floor of 20';
      await selector.initialize();
      await pumpEventQueue();

      expect(
        seen,
        hasLength(1),
        reason: 'still one notice — the episode has not ended',
      );
      expect(
        selector.unavailableReason,
        contains('below the floor'),
        reason:
            'but the reason is current, because it is read on demand '
            'rather than pushed at the user',
      );
    });

    test('a transport that records nothing still yields a sentence', () async {
      // `_DeadTransport` is deliberately silent by default. The fallback has
      // to be a whole sentence rather than an empty string, because it is
      // rendered in a tooltip.
      final selector = AgentSdkTransportSelector([_DeadTransport('quiet')]);
      addTearDown(selector.dispose);

      await selector.initialize();
      expect(selector.unavailableReason, isNotNull);
      expect(selector.unavailableReason, isNotEmpty);
    });
  });

  group('a working transport with something to say', () {
    test('the notice reaches the shell AND the gate stays open', () async {
      // The whole reason this does not travel on the unavailability path: the
      // shell's response to a notice is to show a sentence, and a sentence
      // delivered while `isAvailable` is false would be read as "AI is off".
      // Here AI is on and the sentence is a footnote to that.
      final transport = _TalkativeTransport('two windows report "alpha"');
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      final seen = <AgentSdkNotice>[];
      final sub = selector.notices.listen(seen.add);
      addTearDown(sub.cancel);

      await selector.initialize();
      await pumpEventQueue();

      expect(
        selector.isAvailable,
        isTrue,
        reason: 'an ambiguity resolved is not a degradation',
      );
      expect(selector.active, same(transport));
      expect(seen, hasLength(1));
      expect(seen.single.message, contains('alpha'));
    });

    test('said once per episode, not once per initialize', () async {
      final transport = _TalkativeTransport('two windows report "alpha"');
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      final seen = <AgentSdkNotice>[];
      final sub = selector.notices.listen(seen.add);
      addTearDown(sub.cancel);

      await selector.initialize();
      await selector.initialize();
      await selector.initialize();
      await pumpEventQueue();

      expect(
        seen,
        hasLength(1),
        reason:
            'the same discipline the unavailability notice has — a '
            'standing condition is worth one sentence, not one per probe',
      );
    });

    test('a transport that falls silent re-arms the notice', () async {
      // The flag is cleared by having nothing to say, not only by `retry`.
      // Without that, a user who closed the duplicate window and later opened
      // it again would never hear about the second collision.
      final transport = _TalkativeTransport('two windows report "alpha"');
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      final seen = <AgentSdkNotice>[];
      final sub = selector.notices.listen(seen.add);
      addTearDown(sub.cancel);

      await selector.initialize();
      transport.notice = null;
      await selector.initialize();
      transport.notice = 'two windows report "alpha"';
      await selector.initialize();
      await pumpEventQueue();

      expect(
        seen,
        hasLength(2),
        reason:
            'the collision came back, so it is a new fact and must be '
            'reported again',
      );
    });

    test('an explicit retry re-reports, because the user asked', () async {
      // The mirror of the unavailability rule: `initialize` is the app
      // deciding to look, and a standing condition is worth one sentence;
      // `retry` is the USER deciding to look, and they are waiting for an
      // answer. Saying nothing would read as "nothing happened".
      final transport = _TalkativeTransport('two windows report "alpha"');
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      final seen = <AgentSdkNotice>[];
      final sub = selector.notices.listen(seen.add);
      addTearDown(sub.cancel);

      await selector.initialize();
      expect(await selector.retry(), isTrue);
      await pumpEventQueue();

      expect(seen, hasLength(2));
    });

    test('a silent transport emits nothing', () async {
      // Anti-vacuity for the three above.
      final transport = _TalkativeTransport(null);
      final selector = AgentSdkTransportSelector([transport]);
      addTearDown(selector.dispose);

      final seen = <AgentSdkNotice>[];
      final sub = selector.notices.listen(seen.add);
      addTearDown(sub.cancel);

      await selector.initialize();
      await pumpEventQueue();

      expect(selector.isAvailable, isTrue);
      expect(seen, isEmpty);
    });
  });

  group('recovery', () {
    test('a retry that succeeds opens the gate and stays quiet', () async {
      final server = await FakeAiServer.start();
      addTearDown(server.stop);

      // First candidate is dead; the second only becomes reachable once the
      // fixture exists, which it already does — so the point here is that
      // retry after a failure genuinely re-runs selection rather than
      // caching the verdict.
      final dead = _DeadTransport('dead');
      final live = HostedCliServerAiTransport(
        minPort: server.port,
        maxPort: server.port,
      );
      final selector = AgentSdkTransportSelector([dead, live]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();
      expect(selector.isAvailable, isTrue);
      expect(notices, isEmpty);

      // And the whole thing still works end to end.
      final provider = AgentSdkSessionProvider(
        sessions: testSessions(inProcess: true),
        selector: selector,
        toolServerName: 'tools',
      );
      final deltas = await llmAnswerText(
        provider.run(testRequest(purpose: 'generate', instruction: 'hello')),
      ).toList();
      expect(deltas.join(), isNotEmpty);
    });

    test('after everything fails, a later retry can still succeed', () async {
      // A port held but not yet served, which is exactly "VS Code is not
      // running" — and which no other process can take before it starts.
      final reserved = await ReservedPort.bind();
      addTearDown(reserved.release);
      final port = reserved.port;

      final transport = HostedCliServerAiTransport(
        minPort: port,
        maxPort: port,
      );
      final selector = AgentSdkTransportSelector([transport]);
      final notices = <AgentSdkNotice>[];
      selector.notices.listen(notices.add);
      addTearDown(selector.dispose);

      await selector.initialize();
      await pumpEventQueue();
      expect(selector.isAvailable, isFalse);
      expect(notices, hasLength(1));

      // Now VS Code starts, on the port the transport was aimed at.
      reserved.serve();

      expect(await selector.retry(), isTrue);
      await pumpEventQueue();
      expect(selector.isAvailable, isTrue);
      expect(
        notices,
        hasLength(1),
        reason:
            'a successful retry announces itself by working, not by '
            'another notice',
      );
    });
  });
}

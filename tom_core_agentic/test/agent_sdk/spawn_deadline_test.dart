/// The two deadlines that bound a spawning test, and the error a
/// close during startup produces.
///
/// The flake this closes was three symptoms from one cause: two tests timing
/// out on the 30s startup wait, one reporting *"the standalone AI server exited
/// with code -15 before it was ready"*, and a privacy guard in another file
/// then refusing to claim a pass because its fixture was unreachable.
///
/// The cause is that `startupTimeout` and `dart test`'s default per-test
/// timeout were **both 30s**, and the harness timer starts earlier — it covers
/// `setUp`, the fixture server's bind, and the two `node --version` spawns that
/// `probe` and `connect` each perform before the server is spawned at all.
/// So the harness bound was reached first, always, and the transport's own
/// bound could essentially never fire. When the harness fires it **abandons the
/// body mid-`connect`**, leaving a live child; `tearDown` then calls `close`
/// which SIGTERMs it; and the in-flight `_awaitReadyPort`, whose timer is still
/// running, reports the exit as the child dying on its own. One slow start,
/// three failures, and the loudest of them naming a crash that never happened.
///
/// Both halves are fixed and both are asserted: the deadlines are ordered, and
/// a close during startup says it was a close. That **every** spawning test
/// file orders its deadlines is checked for the whole product by the package
/// seam audit of its consumers (TEST-DEADLINE);
/// what is here is the contract suite's own pair of constants and the
/// transport's behaviour.
///
/// **Deadline.** this file spawns children of its own, so it lives under the same rule it checks.
@Timeout(Duration(seconds: 90))
library;

import 'package:test/test.dart';

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/stand_in.dart';

void main() {
  group('the two deadlines are ordered', () {
    test('the startup bound is strictly below the harness bound '
        '', () {
      // The whole bug in one comparison. Equal deadlines are not a tie: the
      // harness timer starts earlier, so equality means the transport's bound
      // is unreachable and every slow start is reported by the layer that
      // knows least about why.
      expect(spawnDeadlinesAreOrdered, isTrue);
      expect(
        spawnStartupTimeout,
        const Duration(seconds: 30),
        reason:
            'unchanged — the load at which a start is judged too slow is '
            'exactly where it was; this is not "raise it until it passes"',
      );
      expect(
        spawnTestTimeout.inSeconds,
        greaterThanOrEqualTo(spawnStartupTimeout.inSeconds * 2),
        reason:
            'the margin has to cover what the body does outside the '
            'startup wait: two `node --version` spawns and a socket bind',
      );
    });
  });

  group('a close during startup reports the close', () {
    test('closing a connecting transport names the close, not the '
        "child's exit code [0918]", () async {
      // Exactly the shape the harness produced when it abandoned a body: a
      // `close` arrives while `connect` is still waiting for the ready
      // line. Before this fix the child's SIGTERM exit won the race and the
      // error read "exited with code -15 before it was ready" — blaming the
      // child for a signal we sent.
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        // A fixture that starts a VM and then waits for stdin without ever
        // printing a ready line: the startup wait is live and open.
        serverScript: 'test/agent_sdk/support/never_ready_server.dart',
        startupTimeout: spawnStartupTimeout,
      );

      final connecting = transport.connect();
      // Long enough for the child to be spawned and the wait to be in
      // progress, short enough to be nowhere near the startup bound.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await transport.close();

      await expectLater(
        connecting,
        throwsA(
          isA<LlmTransportException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('closed while its server was starting'),
              isNot(contains('exited with code')),
            ),
          ),
        ),
      );
      expect(transport.isConnected, isFalse);
    });

    test('a child that dies on its own still reports its exit '
        'code', () async {
      // The other side of the same discrimination. Collapsing the two would
      // have been the easy fix and the wrong one: a real failure to start must
      // still name the exit code, because that is the one number a reader can
      // act on.
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        serverScript: 'test/agent_sdk/support/dying_server.dart',
        startupTimeout: spawnStartupTimeout,
      );
      addTearDown(transport.close);

      await expectLater(
        transport.connect(),
        throwsA(
          isA<LlmTransportException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('exited with code'),
              contains('before it was ready'),
              isNot(contains('closed while')),
            ),
          ),
        ),
      );
    });

    test('a startup that exceeds its bound fails as a timeout and '
        'reaps the child', () async {
      // The bound the tests always had, exercised for real at a size a test can
      // afford. What matters is the kind — `timeout`, not `unreachable` — and
      // that nothing is left running: a leaked child was the second half of the
      // original flake.
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        serverScript: 'test/agent_sdk/support/never_ready_server.dart',
        startupTimeout: const Duration(milliseconds: 700),
      );

      await expectLater(
        transport.connect(),
        throwsA(
          isA<LlmTransportException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.timeout)
              .having(
                (e) => e.message,
                'message',
                contains(
                  'did not become '
                  'ready',
                ),
              ),
        ),
      );
      // `connect` closes on its own failure path, so there is nothing left to
      // close — and nothing left running.
      expect(transport.isConnected, isFalse);
      await transport.close();
    });
  });
}

/// The [AgentSdkServerTransport] contract, run **once per transport**.
///
/// The whole point of the seam is that the hosted and standalone paths are two
/// implementations of one thing. A test suite that tested them separately would
/// let them drift apart while both stayed green, so the contract is written
/// once and parameterized over the two constructions.
///
/// **Deadlines.** Every test here that spawns a child is bounded
/// twice: by the transport's `startupTimeout` and by the harness. Those two
/// were both 30s — `dart test`'s default — and the harness timer starts
/// earlier, covering `setUp`, two `node --version` spawns and the server
/// spawn, so it always reached zero first. A slow start therefore abandoned
/// the body mid-`connect` and left a live child for `tearDown` to SIGTERM,
/// which the in-flight connect then reported as the child crashing. The
/// harness bound is now three times the startup bound; see
/// `support/spawn_timings.dart` for the rule, why it is not "raise the
/// timeout until it passes", and the test that keeps the literal below in
/// step with it — `package:test` parses this annotation itself and accepts
/// only a literal, so the number cannot be the shared constant and is checked
/// against it instead.
@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/requests.dart';
import 'support/completion_events.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/stand_in.dart';
import 'support/path_ai_server.dart' show pathReportPrefix;
import 'support/sessions.dart';

/// Builds a transport bound to an already-running fixture, plus a name.
typedef TransportUnderTest = ({
  String name,
  Future<AgentSdkServerTransport> Function(FakeAiServer server) build,
});

/// The hosted transport reaches an *existing* server; the fixture stands in
/// for the CLI server of a running VS Code, and the port range is narrowed to
/// the fixture's port so the real discovery scan runs over a range of one.
Future<AgentSdkServerTransport> _hosted(FakeAiServer server) async =>
    HostedCliServerAiTransport(minPort: server.port, maxPort: server.port);

/// The standalone transport *starts* its server, so the fixture it is given is
/// ignored: it spawns `fake_ai_server.dart` under the Dart VM exactly the way
/// production spawns `agent_sdk_server.js` under Node.
Future<AgentSdkServerTransport> _standalone(FakeAiServer _) async =>
    StandaloneNodeAiTransport(
      node: llmNodeAt(standInExecutable),
      serverScript: agentSdkFixtureScript('fake_ai_server'),
      startupTimeout: spawnStartupTimeout,
    );

final transports = <TransportUnderTest>[
  (name: 'hosted (VS Code CLI server)', build: _hosted),
  (name: 'standalone (own Node process)', build: _standalone),
];

void main() {
  for (final under in transports) {
    group('AgentSdkServerTransport contract — ${under.name}', () {
      late FakeAiServer server;
      late AgentSdkServerTransport transport;

      setUp(() async {
        server = await FakeAiServer.start(replies: const ['Hello, ', 'world.']);
        transport = await under.build(server);
      });

      tearDown(() async {
        await transport.close();
        await server.stop();
      });

      test('probes true, connects, and streams a completion', () async {
        expect(await transport.probe(), isTrue);
        await transport.connect();
        expect(transport.isConnected, isTrue);

        final deltas = await textOf(
          transport.complete(
            const AgentSdkCompletionRequest(prompt: 'Say hello.'),
          ),
        ).toList();

        // Both fixtures stream more than one delta, so this also proves the
        // stream is a stream rather than one buffered answer.
        expect(deltas.length, greaterThan(1));
        expect(deltas.join(), isNotEmpty);
      });

      test('reports the same static capabilities on both paths', () {
        expect(transport.capabilities.canComplete, isTrue);
        // Anthropic exposes no embeddings API, so semantic search degrades to
        // lexical for as long as no transport embeds.
        expect(transport.capabilities.canEmbed, isFalse);
        // Both carry a tool call back as `agentSdk.toolCall`.
        expect(transport.capabilities.canUseTools, isTrue);
        expect(transport.capabilities.maxContextTokens, greaterThan(0));
      });

      test(
        'completing before connect fails as unreachable, not as a crash',
        () async {
          expect(
            () => transport
                .complete(const AgentSdkCompletionRequest(prompt: 'x'))
                .toList(),
            throwsA(
              isA<LlmTransportException>().having(
                (e) => e.kind,
                'kind',
                LlmErrorKind.unreachable,
              ),
            ),
          );
        },
      );

      test(
        'close is idempotent and leaves the transport disconnected',
        () async {
          await transport.connect();
          await transport.close();
          await transport.close();
          expect(transport.isConnected, isFalse);
        },
      );
    });
  }

  group('hosted transport specifics', () {
    test(
      'discovery identifies the workspace and rejects a non-match',
      () async {
        final server = await FakeAiServer.start(workspaceName: 'alpha');
        addTearDown(server.stop);

        final match = HostedCliServerAiTransport(
          workspaceName: 'alpha',
          minPort: server.port,
          maxPort: server.port,
        );
        expect(await match.probe(), isTrue);
        await match.connect();
        expect(match.isConnected, isTrue);
        await match.close();

        final mismatch = HostedCliServerAiTransport(
          workspaceName: 'beta',
          minPort: server.port,
          maxPort: server.port,
        );
        expect(await mismatch.probe(), isFalse);
        await expectLater(
          mismatch.connect(),
          throwsA(
            isA<LlmTransportException>().having(
              (e) => e.kind,
              'kind',
              LlmErrorKind.unreachable,
            ),
          ),
        );
      },
    );

    // ─── ────────────────────────────────────────────────────
    //
    // `workspaceName` distinguishes windows by WHAT THEY HAVE OPEN, and two
    // windows on one workspace answer identically. The resolution is to pick
    // deterministically and SAY SO, rather than to refuse: every such server
    // reaches the same Anthropic account, so refusing would break a working
    // case to prevent nothing.
    test('a pin matching two windows takes the lower port and '
        'says that it did', () async {
      final (first, second) = await _twoWindowsReporting('alpha');
      addTearDown(first.stop);
      addTearDown(second.stop);

      final transport = HostedCliServerAiTransport(
        workspaceName: 'alpha',
        minPort: first.port,
        maxPort: second.port,
      );
      addTearDown(transport.close);

      expect(
        await transport.probe(),
        isTrue,
        reason: 'an ambiguous pin is not a failure — both windows serve',
      );

      final notice = transport.selectionNotice;
      expect(
        notice,
        isNotNull,
        reason:
            'THE POINT: resolving this quietly is what left a user '
            'unable to learn their pin had not disambiguated anything',
      );
      expect(notice, contains('${first.port}'));
      expect(
        notice,
        contains('${second.port}'),
        reason:
            'both candidates, or the user cannot tell which windows '
            'collided',
      );
      expect(notice, contains('alpha'));
      expect(
        notice,
        contains('workspace, not a window'),
        reason:
            'the cause, which is the part a user cannot deduce from '
            'the symptom',
      );

      await transport.connect();
      expect(transport.isConnected, isTrue);
    });

    test('one window reporting the pin produces no notice at all', () async {
      // Anti-vacuity for C83-1: without this, a notice hard-wired to "always"
      // would pass it. The quiet case has to stay quiet.
      final server = await FakeAiServer.start(workspaceName: 'alpha');
      addTearDown(server.stop);

      final transport = HostedCliServerAiTransport(
        workspaceName: 'alpha',
        minPort: server.port,
        maxPort: server.port,
      );
      addTearDown(transport.close);

      expect(await transport.probe(), isTrue);
      expect(transport.selectionNotice, isNull);
    });

    test('with no pin, two windows are not an ambiguity to report', () async {
      // Deliberate, and the reason is the design: the unpinned rule is
      // "lowest responding port", documented and honest. The user expressed no
      // intent to choose between windows, so there is nothing that failed to
      // happen. Only a PIN can fail to do what it was asked.
      final (first, second) = await _twoWindowsReporting('alpha');
      addTearDown(first.stop);
      addTearDown(second.stop);

      final transport = HostedCliServerAiTransport(
        minPort: first.port,
        maxPort: second.port,
      );
      addTearDown(transport.close);

      expect(await transport.probe(), isTrue);
      expect(transport.selectionNotice, isNull);
      await transport.connect();
      expect(transport.isConnected, isTrue);
    });

    test('the notice is recomputed, so closing the second window '
        'clears it', () async {
      // Latching it would mean a user who acted on the notice kept being told
      // about a collision they had already fixed, for the life of the process.
      final (first, second) = await _twoWindowsReporting('alpha');
      addTearDown(first.stop);

      final transport = HostedCliServerAiTransport(
        workspaceName: 'alpha',
        minPort: first.port,
        maxPort: second.port,
      );
      addTearDown(transport.close);

      expect(await transport.probe(), isTrue);
      expect(transport.selectionNotice, isNotNull);

      await second.stop();
      expect(await transport.probe(), isTrue);
      expect(
        transport.selectionNotice,
        isNull,
        reason: 'the collision is gone, so the sentence about it must be',
      );
    });

    test(
      'never starts anything: with no server, it is simply unavailable',
      () async {
        // A port nothing answers on stands in for "VS Code is closed". Held
        // rather than released, so a concurrent run cannot bind it meanwhile.
        final reserved = await ReservedPort.bind();
        addTearDown(reserved.release);

        final transport = HostedCliServerAiTransport(
          minPort: reserved.port,
          maxPort: reserved.port,
        );
        expect(await transport.probe(), isFalse);
        await expectLater(
          transport.connect(),
          throwsA(
            isA<LlmTransportException>().having(
              (e) => e.message,
              'message',
              // The message must name the remedy, not just the symptom: the server
              // is a separate thing from the editor, so "VS Code is running" is
              // exactly the wrong conclusion for a user to draw here.
              contains('Start CLI Server'),
            ),
          ),
        );
      },
    );

    test('refuses a non-loopback host at construction', () {
      expect(
        () => HostedCliServerAiTransport(host: '10.0.0.5'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('uses the CLI server default port range', () {
      final transport = HostedCliServerAiTransport();
      expect(transport.minPort, defaultVSCodeBridgePort);
      expect(transport.maxPort, maxVSCodeBridgePort);
    });
  });

  group('standalone transport specifics', () {
    test(
      'a missing script is unreachable, with the path in the message',
      () async {
        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(standInExecutable),
          serverScript: 'test/agent_sdk/support/does_not_exist.dart',
        );
        expect(await transport.probe(), isFalse);
        await expectLater(
          transport.connect(),
          throwsA(
            isA<LlmTransportException>()
                .having((e) => e.kind, 'kind', LlmErrorKind.unreachable)
                .having(
                  (e) => e.message,
                  'message',
                  contains('does_not_exist.dart'),
                ),
          ),
        );
      },
    );

    test(
      'a missing runtime is unreachable, not an unhandled ProcessException',
      () async {
        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt('definitely-not-a-real-node-binary'),
          serverScript: agentSdkFixtureScript('fake_ai_server'),
        );
        expect(await transport.probe(), isFalse);
        await expectLater(
          transport.connect(),
          throwsA(
            isA<LlmTransportException>().having(
              (e) => e.kind,
              'kind',
              LlmErrorKind.unreachable,
            ),
          ),
        );
      },
    );

    test(
      'a Node below the floor is refused by version, not left to fail later',
      () async {
        // The failure this forbids is the one was filed about: a
        // machine whose PATH `node` is v16 probes *available*, connects happily
        // (v16 does start the server), and then dies as an unexplained grandchild
        // — the Agent SDK spawns the Claude Code CLI under the bare name `node`
        // and v16 cannot parse its bundle. The user is shown "exited with code 1"
        // for what is really "your Node is too old". The probe's message already
        // promised Node $requiredNodeMajorVersion or newer; only the check did
        // not enforce it.
        final dir = Directory.systemTemp.createTempSync(
          'agent_sdk_node_floor_',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final shim = File('${dir.path}${Platform.pathSeparator}node')
          ..writeAsStringSync('#!/bin/sh\necho v16.17.0\n');
        Process.runSync('chmod', ['+x', shim.path]);

        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(shim.path),
          serverScript: agentSdkFixtureScript('fake_ai_server'),
        );

        expect(await transport.probe(), isFalse);
        expect(
          transport.unavailableReason,
          contains('16'),
          reason:
              'the reason must name the version found, or the user cannot '
              'tell which of their several Nodes was chosen',
        );
        expect(
          transport.unavailableReason,
          contains('$requiredNodeMajorVersion'),
          reason: 'and the floor, or they do not know what to upgrade to',
        );

        // A permanent condition, so `unreachable` — closing the availability gate is
        // correct here in a way it is not for a stalled completion.
        await expectLater(
          transport.connect(),
          throwsA(
            isA<LlmTransportException>().having(
              (e) => e.kind,
              'kind',
              LlmErrorKind.unreachable,
            ),
          ),
        );
      },
      skip: Platform.isWindows ? 'the shim is a POSIX shell script' : null,
    );

    test(
      'a runtime that reports no Node version is not judged by the floor',
      () async {
        // The floor catches a *known-too-old Node*; it does not gatekeep
        // identity. The contract group above substitutes the Dart VM for Node
        // precisely because the wire is what is under test, and a check that
        // refused everything it could not recognise would refuse that too — the
        // suite would then be testing the check rather than the transport.
        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(standInExecutable),
          serverScript: agentSdkFixtureScript('fake_ai_server'),
          startupTimeout: spawnStartupTimeout,
        );
        expect(await transport.probe(), isTrue);
        expect(transport.unavailableReason, isNull);
      },
    );

    test('the chosen runtime leads the child\'s PATH', () async {
      // Load-bearing rather than tidy: the Agent SDK spawns the Claude Code CLI
      // as a *grandchild* under the bare name `node`, so the grandchild's
      // interpreter comes from PATH and not from `nodeExecutable`. On a machine
      // whose PATH node predates the CLI bundle's syntax the grandchild dies
      // with a parse error while the server it was launched from runs fine —
      // measured, and reported only as "exited with code 1".
      final reported = <String>[];
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        serverScript: 'test/agent_sdk/support/path_ai_server.dart',
        startupTimeout: spawnStartupTimeout,
        onStderr: reported.add,
      );
      await transport.connect();
      addTearDown(transport.close);

      final line = reported.firstWhere(
        (l) => l.startsWith(pathReportPrefix),
        orElse: () => '',
      );
      expect(line, isNotEmpty, reason: 'the child did not report its PATH');

      final childPath = line.substring(pathReportPrefix.length);
      final runtimeDir = File(standInExecutable).parent.path;
      final separator = Platform.isWindows ? ';' : ':';
      expect(
        childPath.split(separator).first,
        runtimeDir,
        reason: 'the chosen runtime must win over whatever PATH already had',
      );
      // Prepended, not replaced: everything else the SDK looks up must stay
      // reachable.
      expect(childPath, contains(Platform.environment['PATH'] ?? ''));
    });

    test('a bare runtime name leaves PATH untouched', () async {
      // A name was itself resolved through PATH, so the grandchild would find
      // the same one anyway; rewriting PATH there would be a change with no
      // effect but a real chance of surprising someone reading the environment.
      final reported = <String>[];
      // `dart` is on PATH wherever this suite runs — it is what ran it.
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt('dart'),
        serverScript: 'test/agent_sdk/support/path_ai_server.dart',
        startupTimeout: spawnStartupTimeout,
        onStderr: reported.add,
      );
      await transport.connect();
      addTearDown(transport.close);

      final line = reported.firstWhere((l) => l.startsWith(pathReportPrefix));
      expect(
        line.substring(pathReportPrefix.length),
        Platform.environment['PATH'] ?? '',
      );
    });

    test('close terminates the child process it started', () async {
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        serverScript: agentSdkFixtureScript('fake_ai_server'),
        startupTimeout: spawnStartupTimeout,
      );
      await transport.connect();
      expect(transport.isConnected, isTrue);
      // If the child outlived close, the next connect would find its port
      // still bound; instead a fresh connect starts a fresh child.
      await transport.close();
      expect(transport.isConnected, isFalse);
    });
  });

  group('error mapping', () {
    test('a remote failure is remote, not unreachable', () async {
      final server = await FakeAiServer.start(
        behaviour: FakeAiServerBehaviour.failWithError,
      );
      addTearDown(server.stop);

      final transport = HostedCliServerAiTransport(
        minPort: server.port,
        maxPort: server.port,
      );
      await transport.connect();
      addTearDown(transport.close);

      await expectLater(
        transport
            .complete(const AgentSdkCompletionRequest(prompt: 'x'))
            .toList(),
        throwsA(
          isA<LlmTransportException>().having(
            (e) => e.kind,
            'kind',
            LlmErrorKind.remote,
          ),
        ),
      );
    });

    test('cancelling the subscription aborts the remote completion', () async {
      final server = await FakeAiServer.start(
        behaviour: FakeAiServerBehaviour.hang,
      );
      addTearDown(server.stop);

      final transport = HostedCliServerAiTransport(
        minPort: server.port,
        maxPort: server.port,
      );
      await transport.connect();
      addTearDown(transport.close);

      final subscription = transport
          .complete(const AgentSdkCompletionRequest(prompt: 'x'))
          .listen((_) {});
      // Let the query reach the fixture, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await subscription.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        server.cancelled,
        isNotEmpty,
        reason: 'cancelling the subscription must send agentSdk.cancelVce',
      );
    });

    test(
      'a far end that accepts and then goes quiet is a timeout, not a hang',
      () async {
        // Measured against the real Agent SDK 0.1.77: given a syntactically
        // plausible but invalid credential it emits `system/init` and then says
        // **nothing for about three minutes** — no result, no error, no CLI
        // stderr — while it retries the 401 invisibly, whereas the same key put
        // to api.anthropic.com by curl is rejected in 0.2s. A far end can
        // likewise accept a query and never terminate it at all, and
        // without a bound of our own the caller waits forever: the stream never
        // closes, `complete` never returns, and the availability gate — which reacts only
        // to a *reported* failure — never learns anything is wrong. The `timeout`
        // kind exists for exactly this ("the far end accepted the request and
        // then went quiet past the deadline") and had no way to be raised.
        //
        // The bound is the provider's, so this drives the hosted
        // transport through it: what is proved is that the provider's clock
        // reaches the wire — the abandonment cancels the query on the socket.
        final server = await FakeAiServer.start(
          behaviour: FakeAiServerBehaviour.hang,
        );
        addTearDown(server.stop);

        final transport = HostedCliServerAiTransport(
          minPort: server.port,
          maxPort: server.port,
        );
        final provider = await _providerOver(
          transport,
          stallGap: const Duration(milliseconds: 300),
        );
        addTearDown(transport.close);

        await expectLater(
          llmAnswerText(
            provider.run(testRequest(purpose: 'generate', instruction: 'x')),
          ).toList(),
          throwsA(
            isA<LlmTransportException>().having(
              (e) => e.kind,
              'kind',
              // Not `unreachable`: the server is up and answering. Degrading the
              // availability gate here would hide every AI affordance because one completion
              // stalled.
              LlmErrorKind.timeout,
            ),
          ),
        );
        expect(
          provider.isAvailable,
          isTrue,
          reason:
              'a stall says nothing about the server; the availability gate stays '
              'open',
        );

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(
          server.cancelled,
          isNotEmpty,
          reason:
              'giving up locally must also abort the query remotely — '
              'otherwise every stall leaks a CLI grandchild that goes on '
              'thinking for a caller that has stopped listening',
        );
      },
    );

    test(
      'a credential the API rejects is a remote failure, reported at once',
      () async {
        // Measured against the real Agent SDK (0.3.284, 2026-09-28): an invalid
        // key produces `system/api_retry` events carrying `error_status: 401` and
        // `error: authentication_failed` within a quarter of a second, and the
        // SDK then retries the 401 ten times over about three minutes before
        // concluding. Every retry resets the stall bound, so a channel that
        // treated them as mere liveness would sit through all ten to report
        // what the first one already said — and a short bound would report it
        // as `timeout`, which names the wrong remedy. The rejection is stated;
        // the channel acts on the statement.
        final server = await FakeAiServer.start(
          behaviour: FakeAiServerBehaviour.rejectCredential,
          dripInterval: const Duration(milliseconds: 100),
        );
        addTearDown(server.stop);

        final transport = HostedCliServerAiTransport(
          minPort: server.port,
          maxPort: server.port,
        );
        await transport.connect();
        addTearDown(transport.close);

        // Driven without any bound at all: an answer arriving proves it came
        // from the channel reading the rejection, not from a stall clock.
        final started = DateTime.now();
        await expectLater(
          transport
              .complete(const AgentSdkCompletionRequest(prompt: 'x'))
              .toList(),
          throwsA(
            isA<LlmTransportException>()
                .having((e) => e.kind, 'kind', LlmErrorKind.remote)
                .having((e) => e.message, 'message', contains('401')),
          ),
        );
        expect(
          DateTime.now().difference(started),
          lessThan(const Duration(seconds: 5)),
          reason:
              'the first rejection is the answer; waiting out the retries '
              'learns nothing',
        );

        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          server.cancelled,
          isNotEmpty,
          reason:
              'the SDK would go on retrying a key that cannot succeed '
              'for a caller that has its answer',
        );
      },
    );

    test('a transient retry is liveness, not a failure', () async {
      // The narrow half of the test above: `api_retry` is also how the SDK
      // reports an overloaded or failing server it expects to recover from,
      // and those runs do recover. Only a credential rejection is terminal.
      final server = await FakeAiServer.start(
        behaviour: FakeAiServerBehaviour.retryThenAnswer,
        replies: const ['recovered.'],
        dripInterval: const Duration(milliseconds: 200),
        thinkingBeats: 5,
      );
      addTearDown(server.stop);

      // Below the whole run (~1200ms) and above one gap (200ms): the retries
      // themselves must keep the completion alive — the channel reports each
      // as liveness, and the bound counts it.
      final transport = HostedCliServerAiTransport(
        minPort: server.port,
        maxPort: server.port,
      );
      await transport.connect();
      addTearDown(transport.close);

      final deltas = await _bounded(
        transport,
        const Duration(milliseconds: 700),
      ).toList();
      expect(deltas.join(), 'recovered.');
    });

    test(
      'the stall bound measures the gap between messages, not the whole run',
      () async {
        // The distinction is the design. A total budget would cut off a long but
        // perfectly healthy completion — exactly the ones worth waiting for —
        // whereas a gap bound only fires when nothing at all has arrived. Every
        // SdkMessage counts as liveness, `system/init` included, so a model that
        // is thinking out loud is never mistaken for one that has died.
        final server = await FakeAiServer.start(
          behaviour: FakeAiServerBehaviour.slowDrip,
          replies: const ['one ', 'two ', 'three ', 'four ', 'five'],
          dripInterval: const Duration(milliseconds: 200),
        );
        addTearDown(server.stop);

        // Comfortably above the 200ms gap and comfortably below the ~1000ms the
        // whole completion takes, so a total-budget implementation fails here.
        final transport = HostedCliServerAiTransport(
          minPort: server.port,
          maxPort: server.port,
        );
        await transport.connect();
        addTearDown(transport.close);

        final deltas = await _bounded(
          transport,
          const Duration(milliseconds: 700),
        ).toList();
        expect(deltas.join(), 'one two three four five');
      },
    );

    test(
      'the query asks for partial messages, so silence means silence',
      () async {
        // The stall bound is a *gap* bound, and a gap bound is only honest if the
        // far end reports liveness while it works. `SDKPartialAssistantMessage`
        // is emitted **only** when `includePartialMessages` is set; without it
        // the sole messages in a run are `system/init`, the finished assistant
        // message, and the result — so between accepting the query and producing
        // its first token an extended-thinking model says *nothing*, and the
        // bound would abandon it. Requesting partial messages is what makes
        // "nothing at all for two minutes" mean a dead far end rather than a
        // busy one.
        final server = await FakeAiServer.start();
        addTearDown(server.stop);

        final transport = HostedCliServerAiTransport(
          minPort: server.port,
          maxPort: server.port,
        );
        await transport.connect();
        addTearDown(transport.close);

        await textOf(
          transport.complete(const AgentSdkCompletionRequest(prompt: 'x')),
        ).toList();

        // Asserted against the bytes that actually crossed the socket, in the
        // same style as the privacy test: what the adapter intended to send is
        // not the question.
        expect(server.receivedText, contains('"includePartialMessages":true'));
      },
    );

    test('a far end that only thinks aloud is alive, not stalled', () async {
      // The behavioural half of the test above. Here the fixture produces no
      // assistant message for five beats — exactly what a thinking model does
      // — and the run outlasts the stall bound several times over. It must
      // still complete: partial-message events are evidence of life, which the
      // channel reports as `AgentSdkLiveness` and the bound counts.
      final server = await FakeAiServer.start(
        behaviour: FakeAiServerBehaviour.thinkAloudThenAnswer,
        replies: const ['thought it through.'],
        dripInterval: const Duration(milliseconds: 200),
        thinkingBeats: 5,
      );
      addTearDown(server.stop);

      final transport = HostedCliServerAiTransport(
        minPort: server.port,
        maxPort: server.port,
      );
      await transport.connect();
      addTearDown(transport.close);

      final events = await transport
          .complete(const AgentSdkCompletionRequest(prompt: 'x'))
          .toList();
      expect(
        events.whereType<AgentSdkLiveness>(),
        isNotEmpty,
        reason:
            'thinking must reach the bound as liveness, or the bound '
            'measures model latency',
      );

      // Below the ~1000ms the run takes, above the 200ms between beats.
      final deltas = await _bounded(
        transport,
        const Duration(milliseconds: 700),
      ).toList();
      expect(
        deltas.join(),
        'thought it through.',
        reason: 'a thinking model must not be mistaken for a dead one',
      );
    });

    test('the default stall bound keeps an order of magnitude over the '
        'largest gap a real completion was measured to leave', () {
      // The largest silence observed between two consecutive messages of a
      // real completion (2026-09-28): 8.3 s, a pause between `thinking_delta`
      // bursts of Opus 4.5 thinking on a 32k budget over a 170k-token context,
      // through the standalone server. The prefill before `message_start` at
      // that context size was 7.8 s. The bound is a liveness test, so it has
      // to sit far enough above ordinary silence that variance under API load
      // does not read as death — ten times the measured maximum is the floor.
      const largestMeasuredGap = Duration(milliseconds: 8300);
      expect(
        defaultAiStallTimeout,
        greaterThanOrEqualTo(largestMeasuredGap * 10),
      );
    });

    test('a hung standalone child is abandoned by the same bound', () async {
      // The bound is the provider's and reaches every transport by
      // construction, but the rest of this group drives the hosted path only,
      // and the long silent retry was *measured* on the standalone path,
      // against the real Agent SDK. So the one place a stream that never ends
      // must not go unexercised is here: a hung child gives the bound nothing
      // to count, and the abandonment names this transport.
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(standInExecutable),
        serverScript: 'test/agent_sdk/support/fake_ai_server_hang.dart',
        startupTimeout: spawnStartupTimeout,
      );
      await transport.connect();
      addTearDown(transport.close);

      await expectLater(
        _bounded(transport, const Duration(milliseconds: 300)).toList(),
        throwsA(
          isA<LlmTransportException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.timeout)
              .having((e) => e.transportId, 'transportId', 'standalone-node'),
        ),
      );
    });
  });
}

/// A provider over [transport] alone, with the stall gap a test chooses.
Future<AgentSdkSessionProvider> _providerOver(
  AgentSdkServerTransport transport, {
  required Duration stallGap,
}) async {
  final selector = AgentSdkTransportSelector([transport]);
  await selector.initialize();
  expect(
    selector.isAvailable,
    isTrue,
    reason:
        'the fixture transport must be reachable for this test to mean '
        'anything',
  );
  return AgentSdkSessionProvider(
    sessions: testSessions(),
    selector: selector,
    stallGap: stallGap,
    toolServerName: 'tools',
  );
}

/// One completion over [transport], under the provider's bound at [gap].
Stream<String> _bounded(AgentSdkServerTransport transport, Duration gap) =>
    llmAnswerText(
      boundedAiRun(
        transport.complete(const AgentSdkCompletionRequest(prompt: 'x')),
        stallGap: gap,
        transportId: transport.id,
        prelude: [LlmRunStarted(purpose: 'generate', providerId: transport.id)],
      ),
    );

/// Two fixture servers on ADJACENT ports, both reporting [workspaceName].
///
/// Adjacent because the transport scans an inclusive range and a test must not
/// probe the hundreds of ports an ephemeral pair can be apart. Ephemeral
/// allocation gives no adjacency guarantee, so this asks for one explicitly and
/// retries: bind the first anywhere, try to take the port above it, and start
/// over with a fresh pair if something else already holds it.
Future<(FakeAiServer, FakeAiServer)> _twoWindowsReporting(String name) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final first = await FakeAiServer.start(workspaceName: name);
    try {
      final second = await FakeAiServer.start(
        workspaceName: name,
        port: first.port + 1,
      );
      return (first, second);
    } on SocketException {
      await first.stop();
    }
  }
  throw StateError(
    'could not bind two adjacent loopback ports in 20 attempts — the test '
    'needs a contiguous pair, not a busy machine excuse',
  );
}

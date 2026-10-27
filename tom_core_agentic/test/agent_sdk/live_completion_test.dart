/// A **real Anthropic completion** through each transport.
///
/// The offline suites prove the mechanics against fixtures that do exactly what
/// we told them to. This proves the *assumptions*: that the Agent SDK really
/// does stream assistant text blocks the way the mirror expects, that a real
/// server's `done` really does terminate the stream, and that the standalone
/// child really does start, hold a credential, and answer. A fixture cannot
/// establish any of that — it can only encode what we believe.
///
/// Each half is gated separately, because the two halves need different things
/// present, and a developer usually has one of them:
///
/// **Standalone** — needs Node ≥ 20, the installed server, and a credential the
/// Agent SDK can reach:
///
/// ```bash
/// cd tom_core_agentic/node && npm install
/// export ANTHROPIC_API_KEY=sk-ant-… # optional — see below
/// export AGENT_SDK_LIVE=1
/// dart test test/agent_sdk/live_completion_test.dart
/// ```
///
/// The key is optional because it is not the only credential the SDK accepts:
/// with none set it falls back to the ambient Claude Code login, and the
/// completion then reports `apiKeySource: "none"` and succeeds anyway. The gate
/// is therefore [_liveVar] alone — the opt-in to spend real tokens — and the
/// key, when present, is simply passed through. Gating on the key would have
/// made this suite unrunnable on a machine that can in fact run it.
///
/// **Hosted** — needs a running VS Code with the Tom extension, which is
/// already holding its own credential:
///
/// ```bash
/// export AGENT_SDK_LIVE_HOSTED=1
/// dart test test/agent_sdk/live_completion_test.dart
/// ```
///
/// The CLI server is **not** running merely because VS Code is: start it with
/// the extension's "Start CLI Server" command (`tomAi.cliServer.start`), whose
/// autostart is off by default. `AGENT_SDK_LIVE_WORKSPACE` is optional and,
/// when given, must be the identity the *server* reports rather than the folder
/// name — see [_workspaceVar].
///
/// A plain `dart test` runs neither, so the default run needs no network, no
/// credential, and no editor.
///
/// **Either live half probes first**: one tiny completion with a
/// short bound, through `probeAgentSdkModel`. A model answering runs the
/// tests; a transport that connects with no model behind it — the ordinary
/// uncredentialed case — SKIPS them with a sentence naming the credential,
/// rather than waiting out the stall bound to report a `timeout`; a transport
/// that cannot be reached fails, because the variable asked for it.
///
/// A third group sits between the two: it spawns the **real**
/// `agent_sdk_server.js` with a deliberately invalid key. That needs Node and
/// `npm install`, but no credential and no network round-trip worth the name,
/// and it establishes the half of the standalone assumption that a fixture
/// genuinely cannot — that the shipped server starts, announces its port in the
/// agreed form, accepts a framed request, and routes a terminal chunk back on
/// the right stream id. Only the model's *answer* needs a real key; everything
/// under it is provable without one.
///
/// **Deadline.** the live tests reach Anthropic and allow the server 60s to start; their per-test bounds already exceed this, and the file-level one is here so a test added without its own bound is still ordered.
@Timeout(Duration(seconds: 180))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_core_agentic/agent_sdk_live_probe.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/requests.dart';
import 'support/completion_events.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/sessions.dart';

const _liveVar = 'AGENT_SDK_LIVE';
const _liveHostedVar = 'AGENT_SDK_LIVE_HOSTED';
const _keyVar = 'ANTHROPIC_API_KEY';

/// Pins the hosted scan to one workspace. The value is the **normalized**
/// identity a server reports — for a window that has a `.code-workspace` file
/// open that is the file's basename without its extension (so `agent_sdk`, not
/// the containing folder's name), which is rarely the same string a developer
/// would guess from the path.
const _workspaceVar = 'AGENT_SDK_LIVE_WORKSPACE';

/// The identity the second responder claims, and the line only it can answer
/// with — the evidence that discovery reached past the editor.
/// The provider's stall gap, shortened for a far end whose silence is known
/// to be permanent.
const _liveStallGap = Duration(seconds: 10);

const _secondWindowName = 'agent-sdk-second-window';
const _fixtureAnswer = 'ANSWERED-BY-THE-SECOND-WINDOW';

/// A prompt whose correct answer is one unmistakable token, so the assertion
/// is about the pipeline rather than about the model's prose.
const _prompt =
    'Reply with exactly the word AGENTSDK and nothing else. No punctuation.';

/// The one rule for a live AI test: run when a model answered,
/// SKIP naming the credential when the transport connected and no model did,
/// and FAIL when the transport itself was unreachable — the variable asked
/// for it to be reachable, so that is a finding.
bool _skipWithoutModel(AgentSdkProbe probe) {
  switch (probe.outcome) {
    case AgentSdkProbeOutcome.answered:
      return false;
    case AgentSdkProbeOutcome.noModel:
      markTestSkipped(probe.detail);
      return true;
    case AgentSdkProbeOutcome.unreachable:
      fail('the live transport could not be reached: ${probe.detail}');
  }
}

bool _enabled(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty;
}

/// Runs a completion through [transport] and asserts it is a real answer.
Future<void> _expectRealCompletion(AgentSdkServerTransport transport) async {
  final selector = AgentSdkTransportSelector([transport]);
  await selector.initialize();
  expect(
    selector.isAvailable,
    isTrue,
    reason: 'the live transport did not become available',
  );

  final provider = AgentSdkSessionProvider(
    sessions: testSessions(),
    selector: selector,
    toolServerName: 'tools',
  );
  expect(provider.capabilities.canComplete, isTrue);

  final deltas = await llmAnswerText(
    provider.run(testRequest(purpose: 'generate', instruction: _prompt)),
  ).toList();

  final answer = deltas.join().trim();
  expect(answer, isNotEmpty, reason: 'a live completion returned no text');
  expect(
    answer.toUpperCase(),
    contains('AGENTSDK'),
    reason:
        'the model answered "$answer", which suggests the prompt did not '
        'arrive intact',
  );

  await selector.dispose();
}

void main() {
  group('the probe tells a missing model from a missing server', () {
    final node = findNodeForTests();
    final script = resolveDefaultServerScript();
    final installed = Directory(
      '${File(script).parent.path}/node_modules',
    ).existsSync();
    if (node == null || !installed) {
      test(
        'skipped — needs Node >= 20 and `npm install` '
        '',
        () {},
        skip: 'no Node >= 20 or no npm install',
      );
      return;
    }

    test('a reachable server with an unusable credential is '
        '"no model" within the bound, not a two-minute timeout', () async {
      // An invalid key: the server starts, the transport connects, and the
      // pinned Agent SDK retries the 401 silently — the exact shape of the
      // 2026-09-22 run that waited out the stall bound. On a machine logged
      // in to Claude Code this is also the check: the explicit
      // key is the only credential the child has, so the login cannot answer
      // in its place.
      const bound = Duration(seconds: 10);
      final probe = await probeAgentSdkModel(
        StandaloneNodeAiTransport(
          node: llmNodeAt(node),
          serverScript: script,
          apiKey: 'sk-ant-invalid-live-probe',
          startupTimeout: const Duration(seconds: 60),
        ),
        bound: bound,
      );
      // ignore: avoid_print
      print('probe: $probe');
      expect(probe.outcome, AgentSdkProbeOutcome.noModel);
      expect(probe.detail, contains('credential'));
      expect(
        probe.elapsed,
        lessThan(bound + const Duration(seconds: 30)),
        reason: 'startup plus the bound, and nothing like the stall bound',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('an unreachable transport is not "no model"', () async {
      final probe = await probeAgentSdkModel(
        StandaloneNodeAiTransport(
          node: llmNodeAt(node),
          serverScript: '${Directory.systemTemp.path}/no-such-server.js',
        ),
      );
      expect(
        probe.outcome,
        AgentSdkProbeOutcome.unreachable,
        reason:
            'a live run asked for a reachable transport; not finding one '
            'is a failure, never a skip',
      );
    });
  });

  group('the shipped server speaks the wire (no credential needed)', () {
    final node = findNodeForTests();
    final script = resolveDefaultServerScript();
    final installed = Directory(
      '${File(script).parent.path}/node_modules',
    ).existsSync();

    if (node == null || !installed) {
      test(
        'skipped — needs Node >= 20 and `npm install` in '
        'tom_core_agentic/node',
        () {},
        skip: node == null
            ? 'no Node >= 20 found'
            : 'run `npm install` in tom_core_agentic/node',
      );
      return;
    }

    /// The real server, held to the contract the Dart fixture only imitates.
    ///
    /// The key is syntactically plausible and certainly invalid, so the run
    /// reaches the SDK. Under **Agent SDK 0.3.286** — the version
    /// `node/package-lock.json` pins — each retry of the 401 is announced as a
    /// `system/api_retry` event with `error_status: 401`, the first within a
    /// fraction of a second, and the channel takes that first one as the
    /// answer: `remote`, in a few seconds, with the query cancelled. (The SDK
    /// itself still retries the 401 for about three minutes before concluding
    /// — the part worth reporting upstream.)
    ///
    /// 0.1.77, which the server pinned before, emitted `system/init` and then
    /// nothing for about 180 s while it retried invisibly, so the same run
    /// ended as `timeout`, which named the wrong thing. The stall bound stays:
    /// it is what catches a far end that goes quiet for any other reason.
    ///
    /// Getting this far exercises the whole transport path except the model's
    /// opinion: the server accepted the framed request, found the stream id,
    /// and stayed live enough to be cancelled on the right one.
    test(
      'starts, accepts a query, and terminates it rather than hanging',
      () async {
        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(node),
          serverScript: script,
          apiKey: 'sk-ant-invalid-key-for-a-wire-test',
          startupTimeout: const Duration(seconds: 60),
          onStderr: (line) => printOnFailure('[server] $line'),
        );

        // Starting at all proves the ready line was printed in the agreed shape
        // and parsed — a server that never announced a port could not connect.
        await transport.connect();
        addTearDown(transport.close);
        expect(transport.isConnected, isTrue);

        await expectLater(
          // The provider's bound, short on purpose: the silence here is
          // permanent, so waiting the production two minutes would only spend
          // them learning that.
          llmAnswerText(
            boundedAiRun(
              transport.complete(
                const AgentSdkCompletionRequest(prompt: 'ping'),
              ),
              stallGap: _liveStallGap,
              transportId: transport.id,
              prelude: [
                LlmRunStarted(purpose: 'generate', providerId: transport.id),
              ],
            ),
          ).toList(),
          throwsA(
            isA<LlmTransportException>().having(
              (e) => e.kind,
              'kind',
              LlmErrorKind.remote,
            ),
          ),
          reason:
              'a rejected credential is the far end answering, so it is '
              '`remote` — not a stream that never ends, not a `timeout` after '
              'the stall bound, and not an empty but successful completion',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'an invalid credential does not read as "backend unreachable"',
      () async {
        // The distinction is load-bearing: closes the availability gate only
        // for `unreachable`. If a rejected key were reported that way, one bad
        // key would hide every AI affordance until restart, and the user would
        // be told the server is down when it is running and answering.
        //
        // Under the pinned SDK it arrives as `remote` (see the test above); the
        // line this test draws is the one the availability gate depends on — the server is up, and
        // one failed completion must not close the gate on it.
        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(node),
          serverScript: script,
          apiKey: 'sk-ant-invalid-key-for-a-wire-test',
          startupTimeout: const Duration(seconds: 60),
        );
        await transport.connect();
        addTearDown(transport.close);

        try {
          await llmAnswerText(
            boundedAiRun(
              transport.complete(
                const AgentSdkCompletionRequest(prompt: 'ping'),
              ),
              stallGap: _liveStallGap,
              transportId: transport.id,
              prelude: [
                LlmRunStarted(purpose: 'generate', providerId: transport.id),
              ],
            ),
          ).toList();
          fail(
            'an invalid credential must not produce a successful completion',
          );
        } on LlmTransportException catch (e) {
          expect(e.kind, isNot(LlmErrorKind.unreachable));
          expect(
            e.toString(),
            isNot(contains('sk-ant')),
            reason:
                'the credential must not survive into a '
                'diagnostic message',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'the credential never reaches the child\'s command line',
      () async {
        // The key travels in the environment precisely so it cannot be read out
        // of the process table by any local process. Asserting on the argument
        // vector is the cheap, direct way to keep that true.
        //
        // A sentinel is used rather than a real key, and it belongs here rather
        // than in the credentialled group for two reasons. The code path cannot
        // tell the two apart — whatever string arrives as `apiKey` goes to the
        // same place — so the sentinel proves the same property; and putting a
        // *real* key into a machine's process table in order to check that it is
        // not in the process table is precisely the exposure the rule forbids.
        // Sitting here, it also runs on every machine that can run the server
        // instead of only on one that has exported a key.
        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(node),
          serverScript: script,
          apiKey: 'sk-ant-hygiene-sentinel-never-a-real-key',
          startupTimeout: const Duration(seconds: 60),
        );
        await transport.connect();
        addTearDown(transport.close);

        final ps = await Process.run('ps', ['-o', 'args=', '-ax']);
        expect(ps.stdout.toString(), isNot(contains('sk-ant')));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('standalone (own Node process)', () {
    // Only the live opt-in gates this: see the library doc for why the key does
    // not. A credential the SDK cannot use is found by the probe below and
    // SKIPS with a sentence naming it: what the variable asserts
    // is a reachable transport, and a transport that is reachable but has no
    // model behind it used to fail after the full stall bound with a
    // `timeout`, which named the wrong thing. An unreachable one still fails.
    if (!_enabled(_liveVar)) {
      test(
        'skipped — set $_liveVar to run a real '
        'Anthropic completion through the standalone server',
        () {},
        skip: 'set $_liveVar=1 to enable',
      );
      return;
    }

    // The Agent SDK's grandchild resolves `node` from PATH, so the transport
    // must be given an interpreter it can hand on; the default bare `node` is
    // frequently an older one. Picking it here is the same choice the
    // credential-free group makes, for the same reason.
    final node = findNodeForTests();
    final script = resolveDefaultServerScript();

    if (node == null) {
      test('skipped — needs Node >= 20', () {}, skip: 'no Node >= 20 found');
      return;
    }

    // One tiny completion first, so a reachable server with no
    // model behind it is a skip naming the credential rather than minutes of
    // waiting for a `timeout`.
    late final AgentSdkProbe probe;
    setUpAll(() async {
      probe = await probeAgentSdkModel(
        StandaloneNodeAiTransport(
          node: llmNodeAt(node),
          serverScript: script,
          apiKey: Platform.environment[_keyVar],
          startupTimeout: const Duration(seconds: 60),
        ),
      );
      // ignore: avoid_print
      print('standalone probe: $probe');
    });

    test(
      'returns a real Anthropic completion',
      () async {
        if (_skipWithoutModel(probe)) return;
        expect(
          File(script).existsSync(),
          isTrue,
          reason:
              'the standalone server was not found at "$script"; run '
              '`npm install` in tom_core_agentic/node',
        );

        await _expectRealCompletion(
          StandaloneNodeAiTransport(
            node: llmNodeAt(node),
            serverScript: script,
            // Null when no key is exported, which is not a hole: the child then
            // inherits the environment and the SDK authenticates from the ambient
            // Claude Code login.
            apiKey: Platform.environment[_keyVar],
            startupTimeout: const Duration(seconds: 60),
            onStderr: (line) => printOnFailure('[server] $line'),
          ),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  group('hosted (VS Code CLI server)', () {
    if (!_enabled(_liveHostedVar)) {
      test(
        'skipped — set $_liveHostedVar with VS Code '
        'running to run a real Anthropic completion through the CLI server '
        '',
        () {},
        skip: 'set $_liveHostedVar=1 with VS Code running to enable',
      );
      return;
    }

    late final AgentSdkProbe probe;
    setUpAll(() async {
      probe = await probeAgentSdkModel(
        HostedCliServerAiTransport(
          workspaceName: Platform.environment[_workspaceVar],
        ),
      );
      // ignore: avoid_print
      print('hosted probe: $probe');
    });

    test(
      'returns a real Anthropic completion',
      () async {
        if (_skipWithoutModel(probe)) return;
        await _expectRealCompletion(
          HostedCliServerAiTransport(
            // Optional: pin the scan to one workspace when several VS Code windows
            // are open, so the test does not talk to whichever answered first.
            workspaceName: Platform.environment[_workspaceVar],
          ),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'the app never learns the hosted credential',
      () async {
        // On the hosted path the editor owns the key and the app must not
        // copy it. The structural proof is that the transport has nowhere to put
        // one — there is no apiKey to pass.
        final transport = HostedCliServerAiTransport(
          workspaceName: Platform.environment[_workspaceVar],
        );
        await transport.connect();
        addTearDown(transport.close);
        expect(transport.isConnected, isTrue);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('hosted discovery with more than one server answering', () {
    // The reason `workspaceName` exists is the case a
    // single-window developer never reaches: several servers answer, and the
    // right one is not necessarily the first. Unpinned discovery takes the
    // lowest port, so the only way to prove the pin *does* something is to make
    // the wanted server the one that is NOT lowest.
    //
    // The real VS Code CLI server supplies the server that must be **skipped**,
    // which is the harder half and the half a fixture cannot fake: the scan
    // really does connect to it, really does ask it who it is, and really does
    // move on. The second responder is a fixture rather than a second editor
    // window because a second window would not start a CLI server on its own
    // (autostart is off by default) and cannot be driven to start one from
    // outside — and because what it would add, that VS Code names two windows
    // differently, is a property of VS Code, not of this discovery code.
    if (!_enabled(_liveHostedVar)) {
      test(
        'skipped — set $_liveHostedVar with VS Code '
        'running to exercise multi-server discovery',
        () {},
        skip: 'set $_liveHostedVar=1 with VS Code running to enable',
      );
      return;
    }

    late int realPort;
    late String realName;
    late FakeAiServer second;

    setUp(() async {
      final responders = await scanBridgePorts();
      expect(
        responders,
        isNotEmpty,
        reason:
            'no VS Code CLI server is listening on '
            '$defaultVSCodeBridgePort–$maxVSCodeBridgePort; start one with '
            'the "Tom AI: Start CLI Server" command',
      );
      realPort = (responders.keys.toList()..sort()).first;
      realName = normalizeWorkspaceName(responders[realPort]!);

      // Somewhere above the real server, still inside the scan range, so the
      // scan must pass over the real one to reach it.
      FakeAiServer? bound;
      for (var port = realPort + 1; port <= maxVSCodeBridgePort; port++) {
        try {
          bound = await FakeAiServer.start(
            port: port,
            workspaceName: _secondWindowName,
            replies: const [_fixtureAnswer],
          );
          break;
        } on SocketException {
          continue;
        }
      }
      expect(
        bound,
        isNotNull,
        reason: 'no free port above $realPort in the scan range',
      );
      second = bound!;
    });

    tearDown(() => second.stop());

    test(
      'a pin selects by identity, not by port order',
      () async {
        final transport = HostedCliServerAiTransport(
          workspaceName: _secondWindowName,
        );
        await transport.connect();
        addTearDown(transport.close);

        final answer = (await textOf(
          transport.complete(const AgentSdkCompletionRequest(prompt: 'ping')),
        ).toList()).join();

        // The fixture's scripted reply is the evidence: only the second server
        // could have produced it, so the scan reached it past the real one.
        expect(answer, contains(_fixtureAnswer));
        expect(
          second.requests.any((r) => r['method'] == 'agentSdk.queryVce'),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'a pin on the editor still reaches the editor',
      () async {
        // The mirror image, and not redundant: it would also pass if the pin were
        // ignored, so it is asserted together with the case above rather than on
        // its own. What it rules out is a pin that matches too eagerly.
        await _expectRealCompletion(
          HostedCliServerAiTransport(workspaceName: realName),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'an unpinned scan takes the lowest responder',
      () async {
        final transport = HostedCliServerAiTransport();
        await transport.connect();
        addTearDown(transport.close);
        // Whatever the editor answers, it is not the fixture's line — and the
        // fixture was never asked to run a query.
        final answer = (await textOf(
          transport.complete(const AgentSdkCompletionRequest(prompt: _prompt)),
        ).toList()).join();
        expect(answer, isNot(contains(_fixtureAnswer)));
        expect(
          second.requests.any((r) => r['method'] == 'agentSdk.queryVce'),
          isFalse,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a pin that matches nothing is unreachable, not the first responder',
      () async {
        // The failure mode this forbids is the dangerous one: silently answering
        // from *some* workspace when the requested one is absent. Two servers are
        // answering, so a transport that fell back to the scan would connect.
        final transport = HostedCliServerAiTransport(
          workspaceName: 'no-window-is-called-this',
        );
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
        expect(transport.isConnected, isFalse);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

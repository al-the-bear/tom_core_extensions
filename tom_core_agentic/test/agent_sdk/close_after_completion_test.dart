/// Closing an AI transport returns promptly, whether or not a
/// completion has run and whatever zone that completion ran in.
///
/// The live reproduction: a test drives completions through the widget
/// surface — inside `testWidgets`' fake-async zone — and its teardown's
/// dispose never returned. The cause, pinned here offline against the fixture
/// server: `Socket.close` completes through a continuation queued in the zone
/// the socket was last written in, and a zone that is never pumped again never
/// runs it (D112-M). The product's zone always runs, so an app quitting after
/// AI was not affected; the channel's close is now bounded all the same, since
/// a far end that stops reading stalls it the same way.
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

import 'support/requests.dart';
import 'support/completion_events.dart';
import 'package:tom_core_agentic/agent_sdk_testing.dart';
import 'support/sessions.dart';

/// A zone like `testWidgets`' fake-async one: microtasks scheduled in it run
/// only while it is pumped, and never again once the "test" is over.
class _PumpedZone {
  final List<void Function()> _queued = [];
  late final Zone zone = Zone.current.fork(
    specification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, f) => _queued.add(f),
    ),
  );

  void pump() {
    while (_queued.isNotEmpty) {
      final next = _queued.removeAt(0);
      zone.run(next);
    }
  }
}

void main() {
  Future<CliServerAiChannel> connected(FakeAiServer server) async {
    final channel = CliServerAiChannel(
      transportId: 'probe',
      client: VSCodeBridgeClient(port: server.port),
    );
    await channel.connect();
    return channel;
  }

  /// Runs one completion inside [zone] to its end, pumping it meanwhile.
  Future<String> completeIn(
    _PumpedZone zone,
    CliServerAiChannel channel,
  ) async {
    final done = Completer<String>();
    zone.zone.run(() {
      unawaited(
        textOf(
          channel.complete(const AgentSdkCompletionRequest(prompt: 'hi')),
        ).join().then(done.complete),
      );
    });
    while (!done.isCompleted) {
      zone.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return done.future;
  }

  test('the cause — a socket written in a zone that is never pumped '
      'again cannot finish closing, and pumping it releases the close '
      '', () async {
    final server = await FakeAiServer.start(replies: const ['one']);
    addTearDown(server.stop);
    final client = VSCodeBridgeClient(port: server.port);
    final channel = CliServerAiChannel(transportId: 'probe', client: client);
    await channel.connect();
    final zone = _PumpedZone();
    expect(await completeIn(zone, channel), contains('one'));

    var closed = false;
    // The library's own disconnect, not the channel's bounded close.
    unawaited(client.disconnect().then((_) => closed = true));
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(closed, isFalse, reason: 'the continuation is queued in the zone');
    for (var i = 0; i < 20 && !closed; i++) {
      zone.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(closed, isTrue, reason: 'pumping that zone once more finishes it');
  });

  test('the channel closes within its bound after a completion run in '
      'such a zone', () async {
    final server = await FakeAiServer.start(replies: const ['one', 'two']);
    addTearDown(server.stop);
    final channel = await connected(server);
    expect(await completeIn(_PumpedZone(), channel), contains('one'));

    final clock = Stopwatch()..start();
    await channel.close().timeout(const Duration(seconds: 10));
    expect(
      clock.elapsed,
      lessThan(CliServerAiChannel.closeBound + const Duration(seconds: 1)),
    );
  });

  test('and at once when no completion has run', () async {
    final server = await FakeAiServer.start();
    addTearDown(server.stop);
    final channel = await connected(server);
    final clock = Stopwatch()..start();
    await channel.close();
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('the selector over a fixture transport disposes after a '
      'completion in such a zone', () async {
    final server = await FakeAiServer.start(replies: const ['one']);
    addTearDown(server.stop);
    final selector = AgentSdkTransportSelector([
      HostedCliServerAiTransport(
        channelFactory: (host, port) => CliServerAiChannel(
          transportId: 'hosted',
          client: VSCodeBridgeClient(port: server.port),
        ),
        resolve: (host, minPort, maxPort, workspace) async =>
            HostedServerResolution(server.port),
      ),
    ]);
    await selector.initialize();
    expect(selector.isAvailable, isTrue);
    final provider = AgentSdkSessionProvider(
      sessions: testSessions(inProcess: true),
      selector: selector,
      toolServerName: 'tools',
    );
    final zone = _PumpedZone();
    final done = Completer<String>();
    zone.zone.run(() {
      unawaited(
        llmAnswerText(
          provider.run(testRequest(purpose: 'generate', instruction: 'hi')),
        ).join().then(done.complete),
      );
    });
    while (!done.isCompleted) {
      zone.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final clock = Stopwatch()..start();
    await selector.dispose().timeout(const Duration(seconds: 10));
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
  });
}

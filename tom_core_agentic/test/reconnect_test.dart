// Tests for the reconnect protocol: the back-off retry
// loop, same/different/still-gone classification, and the interrupt-retry
// prefix composition. The scan service is faked and the back-off delay is made
// instant, so the whole protocol runs without sockets or real waits.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

/// A real [BridgeConnectionService] behind a scripted scanner: each scan
/// returns the next scripted result, so a test can model "gone, gone, then
/// back" across the three back-off attempts. The scanner is the service's own
/// seam, which reports ports and workspaces; the host comes from the service,
/// so every server in one script must share it.
final class _ScriptedScan {
  _ScriptedScan(this._results);

  final List<List<BridgeServer>> _results;
  int calls = 0;

  late final BridgeConnectionService service = BridgeConnectionService(
    host: _host,
    scanner: _scan,
  );

  String get _host {
    final hosts = {
      for (final result in _results)
        for (final server in result) server.host,
    };
    expect(hosts.length, lessThanOrEqualTo(1), reason: 'one host per script');
    return hosts.isEmpty ? defaultBridgeHost : hosts.single;
  }

  Future<Map<int, String>> _scan({
    required String host,
    required int minPort,
    required int maxPort,
  }) async {
    final i = calls < _results.length ? calls : _results.length - 1;
    calls++;
    return {for (final server in _results[i]) server.port: server.workspace};
  }
}

BridgeServer _server(int port, String workspace) =>
    BridgeServer(port: port, workspace: workspace);

ReconnectCoordinator _coordinator(BridgeConnectionService service) {
  final delays = <Duration>[];
  return ReconnectCoordinator(
    service: service,
    delay: (d) async => delays.add(d),
  );
}

const _bound = BridgeChoice(host: '127.0.0.1', port: 19900);

void main() {
  group('composeInterruptRetry', () {
    test('prepends the prefix with a blank line', () {
      expect(
        composeInterruptRetry('Interrupted.', 'do the thing'),
        'Interrupted.\n\ndo the thing',
      );
    });

    test('an empty prefix leaves the prompt unchanged', () {
      expect(composeInterruptRetry('', 'do the thing'), 'do the thing');
    });
  });

  group('ReconnectCoordinator.reconnect', () {
    test(
      'same workspace returns on the first back-off → sameWorkspace',
      () async {
        final service = _ScriptedScan([
          [_server(19900, 'tomspecs')],
        ]);
        final result = await _coordinator(
          service.service,
        ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

        expect(result.resolution, ReconnectResolution.sameWorkspace);
        expect(result.server, _server(19900, 'tomspecs'));
        expect(result.attempts, 1);
      },
    );

    test(
      'comes back only on the third attempt after two empty scans',
      () async {
        final service = _ScriptedScan([
          const [],
          const [],
          [_server(19900, 'tomspecs')],
        ]);
        final result = await _coordinator(
          service.service,
        ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

        expect(result.resolution, ReconnectResolution.sameWorkspace);
        expect(result.attempts, 3);
        expect(service.calls, 3);
      },
    );

    test(
      'a different workspace on the bound port → differentWorkspace',
      () async {
        final service = _ScriptedScan([
          [_server(19900, 'some-other-project')],
        ]);
        final result = await _coordinator(
          service.service,
        ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

        expect(result.resolution, ReconnectResolution.differentWorkspace);
        expect(result.server!.workspace, 'some-other-project');
      },
    );

    test('an unknown bound workspace accepts any server on the port', () async {
      final service = _ScriptedScan([
        [_server(19900, 'whatever')],
      ]);
      final result = await _coordinator(
        service.service,
      ).reconnect(bound: _bound, boundWorkspace: null);

      expect(result.resolution, ReconnectResolution.sameWorkspace);
    });

    test(
      'a server on a different port does not count as the bound one',
      () async {
        final service = _ScriptedScan([
          [_server(19901, 'tomspecs')],
        ]);
        final result = await _coordinator(
          service.service,
        ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

        expect(result.resolution, ReconnectResolution.stillGone);
        expect(result.attempts, defaultReconnectBackoff.length);
      },
    );

    // The bound choice and the discovered server reach the match from
    // different places — the sidecar (or its `127.0.0.1` default) on one side,
    // a scan of `AgentSettings.bridgeHost` on the other. A user who retypes
    // the host in settings makes those two disagree on spelling while still
    // naming one endpoint, and a textual match would then report a bridge
    // that is up and answering as gone: the still-gone modal for a working
    // bridge, and no auto-resend.
    test('a localhost server satisfies a 127.0.0.1 binding', () async {
      final service = _ScriptedScan([
        [BridgeServer(port: 19900, host: 'localhost', workspace: 'tomspecs')],
      ]);
      final result = await _coordinator(service.service).reconnect(
        bound: const BridgeChoice(host: '127.0.0.1', port: 19900),
        boundWorkspace: 'tomspecs',
      );

      expect(result.resolution, ReconnectResolution.sameWorkspace);
      expect(result.attempts, 1);
    });

    test('a 127.0.0.1 server satisfies a localhost binding', () async {
      final service = _ScriptedScan([
        [_server(19900, 'tomspecs')],
      ]);
      final result = await _coordinator(service.service).reconnect(
        bound: const BridgeChoice(host: 'localhost', port: 19900),
        boundWorkspace: 'tomspecs',
      );

      expect(result.resolution, ReconnectResolution.sameWorkspace);
    });

    test('an IPv6 loopback server satisfies a 127.0.0.1 binding', () async {
      final service = _ScriptedScan([
        [BridgeServer(port: 19900, host: '::1', workspace: 'tomspecs')],
      ]);
      final result = await _coordinator(
        service.service,
      ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

      expect(result.resolution, ReconnectResolution.sameWorkspace);
    });

    test('the workspace check still applies across host spellings', () async {
      // Normalising the host must not weaken the workspace classification:
      // a different workspace on the bound port still needs confirmation.
      final service = _ScriptedScan([
        [
          BridgeServer(
            port: 19900,
            host: 'localhost',
            workspace: 'some-other-project',
          ),
        ],
      ]);
      final result = await _coordinator(
        service.service,
      ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

      expect(result.resolution, ReconnectResolution.differentWorkspace);
    });

    test('a non-loopback host on the bound port does not match', () async {
      // The other half of the guard: loopback spellings converge, but a real
      // remote host must stay distinct or a binding could silently follow a
      // scan onto a different machine.
      final service = _ScriptedScan([
        [BridgeServer(port: 19900, host: '10.8.0.9', workspace: 'tomspecs')],
      ]);
      final result = await _coordinator(
        service.service,
      ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

      expect(result.resolution, ReconnectResolution.stillGone);
    });

    test('still gone after all three back-offs → stillGone', () async {
      final service = _ScriptedScan([const []]);
      final result = await _coordinator(
        service.service,
      ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

      expect(result.resolution, ReconnectResolution.stillGone);
      expect(result.server, isNull);
      expect(result.attempts, 3);
      expect(service.calls, 3);
    });

    test('a thrown scan error is swallowed as an empty attempt', () async {
      final service = _ThrowingScan();
      final result = await _coordinator(
        service.service,
      ).reconnect(bound: _bound, boundWorkspace: 'tomspecs');

      expect(result.resolution, ReconnectResolution.stillGone);
    });

    test('uses the 10/30/60 s back-off by default', () {
      expect(defaultReconnectBackoff, const [
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(seconds: 60),
      ]);
    });
  });
}

/// A real [BridgeConnectionService] whose scanner always throws, to exercise
/// the swallow-and-continue path.
final class _ThrowingScan {
  final service = BridgeConnectionService(
    scanner: ({required host, required minPort, required maxPort}) async =>
        throw StateError('scan blew up'),
  );
}

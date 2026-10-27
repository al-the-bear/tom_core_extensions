import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('BridgeConnectionService.scan', () {
    test('maps a fake port table to ascending BridgeServers', () async {
      final service = BridgeConnectionService(
        scanner: ({required host, required minPort, required maxPort}) async =>
            {19902: 'other_workspace', 19900: 'tom_agent_container'},
      );

      final servers = await service.scan();

      expect(servers.map((s) => s.port), [19900, 19902]);
      expect(servers.first.workspace, 'tom_agent_container');
      expect(
        servers.every((s) => s.status == BridgeServerStatus.available),
        isTrue,
      );
    });

    test('scans the full 19900–19909 range by default', () async {
      late int seenMin;
      late int seenMax;
      final service = BridgeConnectionService(
        scanner: ({required host, required minPort, required maxPort}) async {
          seenMin = minPort;
          seenMax = maxPort;
          return const {19900: 'tom_agent_container'};
        },
      );

      await service.scan();

      expect(seenMin, 19900);
      expect(seenMax, 19909);
    });
  });

  // `matches` answers "is this discovered server the one I am bound to?",
  // which is not the same question as string equality. The binding and the
  // scan reach the comparison from different places — the sidecar (or its
  // default) on one side, `AgentSettings.bridgeHost` on the other — so they
  // can legitimately spell one loopback endpoint two ways.
  group('BridgeChoice.matches', () {
    BridgeServer serverOn(String host) =>
        BridgeServer(host: host, port: 19900, workspace: 'ws');

    test('matches a server with the identical host spelling', () {
      const bound = BridgeChoice(host: '127.0.0.1', port: 19900);
      expect(bound.matches(serverOn('127.0.0.1')), isTrue);
    });

    test('treats every spelling of loopback as the same endpoint', () {
      for (final boundHost in ['127.0.0.1', 'localhost', '::1', '[::1]']) {
        final bound = BridgeChoice(host: boundHost, port: 19900);
        for (final serverHost in ['127.0.0.1', 'localhost', '::1', '[::1]']) {
          expect(
            bound.matches(serverOn(serverHost)),
            isTrue,
            reason: 'bound $boundHost should match server $serverHost',
          );
        }
      }
    });

    test('compares host names case-insensitively', () {
      const bound = BridgeChoice(host: 'LocalHost', port: 19900);
      expect(bound.matches(serverOn('localhost')), isTrue);
      expect(
        const BridgeChoice(
          host: 'Build-Box',
          port: 19900,
        ).matches(serverOn('build-box')),
        isTrue,
      );
    });

    test('does not match a genuinely different host', () {
      const bound = BridgeChoice(host: '127.0.0.1', port: 19900);
      expect(bound.matches(serverOn('10.8.0.9')), isFalse);
      expect(bound.matches(serverOn('bomber')), isFalse);
      // Not a loopback address, despite the prefix — a substring test would
      // wrongly accept this one.
      expect(bound.matches(serverOn('127.0.0.1.example.com')), isFalse);
    });

    test('does not match a different port however the host is spelled', () {
      const bound = BridgeChoice(host: 'localhost', port: 19900);
      expect(bound.matches(serverOn('127.0.0.1')), isTrue);
      expect(
        bound.matches(
          const BridgeServer(host: '127.0.0.1', port: 19901, workspace: 'ws'),
        ),
        isFalse,
      );
    });

    test('== still distinguishes the two spellings', () {
      // Deliberate: `==` is value equality on the record that was persisted,
      // and must keep agreeing with `toMap()`. Endpoint identity is the
      // separate question `matches` answers.
      expect(
        const BridgeChoice(host: 'localhost', port: 19900),
        isNot(const BridgeChoice(host: '127.0.0.1', port: 19900)),
      );
    });
  });

  group('defaultBridgeHost', () {
    test('is the one spelling every default in the package uses', () {
      expect(defaultBridgeHost, '127.0.0.1');
      expect(
        const BridgeServer(port: 19900, workspace: 'ws').host,
        defaultBridgeHost,
      );
      expect(BridgeConnectionService().host, defaultBridgeHost);
      expect(BridgeChoice.fromMap(const {}).host, defaultBridgeHost);
      expect(const AgentSettings().bridgeHost, defaultBridgeHost);
    });
  });

  group('BridgeChoiceStore', () {
    test('round-trips the bound choice through YAML', () {
      final dir = Directory.systemTemp.createTempSync('bridge_choice_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = BridgeChoiceStore(File('${dir.path}/bridge.yaml'));

      expect(store.load(), isNull);

      store.save(const BridgeChoice(host: '127.0.0.1', port: 19900));
      final loaded = store.load();
      expect(loaded, isNotNull);
      expect(loaded!.host, '127.0.0.1');
      expect(loaded.port, 19900);

      store.clear();
      expect(store.load(), isNull);
    });

    // The sidecar is the one a user is most likely to edit by hand — it is the
    // file you open to check which port the editor bound to. `load()` degrades
    // like the other nine stores: missing, empty, unreadable and malformed all
    // yield `null`, and nothing propagates to the caller.

    test('returns null for a syntactically damaged file', () {
      final dir = Directory.systemTemp.createTempSync('bridge_choice_bad_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/bridge.yaml')
        ..writeAsStringSync('version: 1\nbridge: {port: 19900\n  broken: [\n');

      // `loadYaml` throws a `YamlException` here. It is a `FormatException`,
      // which is why catching that one type covers YAML damage as well.
      expect(BridgeChoiceStore(file).load(), isNull);
    });

    test('returns null for a file whose root is not a mapping', () {
      final dir = Directory.systemTemp.createTempSync('bridge_choice_list_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/bridge.yaml')
        ..writeAsStringSync('- just\n- a\n- list\n');

      expect(BridgeChoiceStore(file).load(), isNull);
    });

    test('falls back to the defaults for mis-typed host and port', () {
      final dir = Directory.systemTemp.createTempSync('bridge_choice_type_');
      addTearDown(() => dir.deleteSync(recursive: true));

      // Valid YAML, wrong types — a quoted port is the classic hand-edit slip.
      // `fromMap` already defaults an *absent* key, so a value it cannot read
      // is treated the same way rather than escaping as a `TypeError`.
      final file = File('${dir.path}/bridge.yaml')
        ..writeAsStringSync(
          'version: 1\nbridge:\n  host: 42\n'
          '  port: "not-a-number"\n',
        );

      final loaded = BridgeChoiceStore(file).load();
      expect(loaded, isNotNull);
      expect(loaded!.host, '127.0.0.1');
      expect(loaded.port, 19900);
    });

    test('returns null for an unreadable file', () {
      final dir = Directory.systemTemp.createTempSync('bridge_choice_perm_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/bridge.yaml')
        ..writeAsStringSync(
          'version: 1\nbridge:\n  host: 127.0.0.1\n'
          '  port: 19900\n',
        );

      // Permissions are the only portable way to make an *existing* file
      // unreadable, and they do not bite on Windows or for root. Rather than
      // assert vacuously, confirm the read really fails before claiming the
      // store survives it.
      Process.runSync('chmod', ['000', file.path]);
      addTearDown(() => Process.runSync('chmod', ['600', file.path]));

      var readThrew = false;
      try {
        file.readAsStringSync();
      } on FileSystemException {
        readThrew = true;
      }
      if (!readThrew) {
        markTestSkipped('the platform let the process read a 000 file');
        return;
      }

      expect(BridgeChoiceStore(file).load(), isNull);
    });
  });
}

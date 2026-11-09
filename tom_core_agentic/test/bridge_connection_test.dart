import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_file_system/io.dart';

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
      expect(bound.matches(serverOn('192.0.2.9')), isFalse);
      expect(bound.matches(serverOn('build-box')), isFalse);
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
    late TomMemoryFileSystem fs;
    setUp(() => fs = TomMemoryFileSystem());

    /// A store over [content] written to its default location.
    Future<BridgeChoiceStore> storeWith(String content) async {
      final store = BridgeChoiceStore.resolveDefault(fs);
      await fs.writeTextMakingFolder(store.uri, content);
      return store;
    }

    test('round-trips the bound choice through YAML', () async {
      final store = BridgeChoiceStore.resolveDefault(fs);
      expect(store.uri, fs.uriOf('.tom/bridge_connection.yaml'));

      expect(await store.load(), isNull);

      await store.save(const BridgeChoice(host: '127.0.0.1', port: 19900));
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.host, '127.0.0.1');
      expect(loaded.port, 19900);

      await store.clear();
      expect(await fs.exists(store.uri), isFalse);
      expect(await store.load(), isNull);
    });

    test('TOM_SPECS_BRIDGE_FILE moves the sidecar', () {
      final store = BridgeChoiceStore.resolveDefault(
        fs,
        environment: const {'TOM_SPECS_BRIDGE_FILE': 'config/bridge.yaml'},
      );
      expect(store.uri, fs.uriOf('config/bridge.yaml'));
    });

    // The sidecar is the one a user is most likely to edit by hand — it is the
    // file you open to check which port the editor bound to. `load()` degrades
    // like the other stores: missing, empty, unreadable and malformed all
    // yield `null`, and nothing propagates to the caller.

    test('returns null for a syntactically damaged file', () async {
      final store = await storeWith(
        'version: 1\nbridge: {port: 19900\n  broken: [\n',
      );

      // `loadYaml` throws a `YamlException` here. It is a `FormatException`,
      // which is why catching that one type covers YAML damage as well.
      expect(await store.load(), isNull);
    });

    test('returns null for a file whose root is not a mapping', () async {
      final store = await storeWith('- just\n- a\n- list\n');

      expect(await store.load(), isNull);
    });

    test('falls back to the defaults for mis-typed host and port', () async {
      // Valid YAML, wrong types — a quoted port is the classic hand-edit slip.
      // `fromMap` already defaults an *absent* key, so a value it cannot read
      // is treated the same way rather than escaping as a `TypeError`.
      final store = await storeWith(
        'version: 1\nbridge:\n  host: 42\n'
        '  port: "not-a-number"\n',
      );

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.host, '127.0.0.1');
      expect(loaded.port, 19900);
    });

    // An unreadable file needs a real disk: the local file system.
    test('returns null for an unreadable file', () async {
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

      expect(
        await BridgeChoiceStore(
          fileSystem: TomLocalFileSystem(dir.path),
          uri: file.uri,
        ).load(),
        isNull,
      );
    });
  });
}

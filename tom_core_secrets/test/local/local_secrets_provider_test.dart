/// TomLocalSecretsProvider against a scripted stand-in for the Tom Secrets
/// Manager's secrets service: a Unix socket (Linux, macOS) or a localhost
/// port with client.port and client.token (Windows) in a runtime directory
/// named by TSM_RUNTIME_DIR. Demo data only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_secrets/local.dart';
import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_client/tom_secrets_client.dart'
    show
        TomSecretsFrameReader,
        tomSecretsDecodePayload,
        tomSecretsJsonFrame,
        tomSecretsMaxRequestPayload;

Matcher _refused(String key) =>
    throwsA(isA<TomSecretsException>().having((e) => e.key, 'key', key));

/// The service: answers `hello` and every `get` from [answer].
final class _Service {
  _Service._(this.dir, this._server);

  final Directory dir;
  final ServerSocket _server;

  /// Every message received.
  final List<Map<String, Object?>> received = [];

  /// The answer to a `get` (its id is filled in).
  Map<String, Object?> Function(Map<String, Object?> request) answer = (r) =>
      _value('demo-password');

  static Future<_Service> start() async {
    // The system's temporary directory: a Unix socket path is limited to
    // about 100 bytes.
    final dir = Directory.systemTemp.createTempSync('tcs');
    final ServerSocket server;
    if (Platform.isWindows) {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      File('${dir.path}\\client.port').writeAsStringSync('${server.port}\n');
      File('${dir.path}\\client.token').writeAsStringSync('demo-token\n');
    } else {
      server = await ServerSocket.bind(
        InternetAddress(
          '${dir.path}/client.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
    }
    final service = _Service._(dir, server);
    server.listen(service._serve);
    return service;
  }

  Map<String, String> get environment => {'TSM_RUNTIME_DIR': dir.path};

  void _serve(Socket socket) {
    final reader = TomSecretsFrameReader(
      maxPayload: tomSecretsMaxRequestPayload,
    );
    socket.listen(
      (bytes) {
        for (final frame in reader.add(bytes)) {
          final m = tomSecretsDecodePayload(frame.payload);
          received.add(m);
          if (m['op'] == 'hello') {
            socket.add(
              tomSecretsJsonFrame({
                'op': 'welcome',
                'protocol': 1,
                'service': {'version': '0.1.0'},
                'features': <String>[],
                'host': 'demo-host',
                'platform': 'linux',
              }),
            );
          } else {
            socket.add(tomSecretsJsonFrame({...answer(m), 'id': m['id']}));
          }
        }
      },
      // The client hung up: close this side too, so nothing keeps the
      // process alive.
      onDone: socket.destroy,
      onError: (Object _) => socket.destroy(),
    );
  }

  Future<void> stop() async {
    await _server.close();
    dir.deleteSync(recursive: true);
  }
}

Map<String, Object?> _value(
  String value, {
  String encoding = 'utf8',
  String modified = '2026-11-01T12:00:00Z',
  String revision = 'r1',
}) => {
  'op': 'value',
  'value': encoding == 'base64' ? base64.encode(utf8.encode(value)) : value,
  'encoding': encoding,
  'entry': {
    'store': 'demo',
    'uuid': '0f3c2a1b4d5e6f708192a3b4c5d6e7f8',
    'source': 'file',
    'fetchedAt': '2026-11-14T08:00:00Z',
  },
  'bound': <String, String>{},
  'version': {'modified': modified, 'revision': revision},
};

Map<String, Object?> _error(String kind, [String? reason]) => {
  'op': 'error',
  'kind': kind,
  'message': 'demo',
  if (reason != null) 'details': {'reason': reason},
};

void main() {
  late _Service service;

  setUp(() async => service = await _Service.start());
  tearDown(() async {
    await TomSecrets.reset();
    await service.stop();
  });

  TomLocalSecretsProvider provider({
    Map<String, String> dimensions = const {},
    bool wait = true,
    Duration? timeout,
  }) => TomLocalSecretsProvider(
    clientName: 'demo-server',
    dimensions: dimensions,
    wait: wait,
    timeout: timeout,
    environment: service.environment,
  );

  test('a reference becomes the tsm reference with its field; the value is '
      'that field, with the entry version', () async {
    final local = provider(
      dimensions: {'env': 'prod'},
      wait: false,
      timeout: const Duration(seconds: 7),
    );
    service.answer = (r) => _value(
      r['field'] == 'UserName' ? 'demo-user' : 'demo-password',
      revision: 'b1946ac9',
    );
    final payload = await local.fetch(
      TomSecretReference.parse('secret:local:[env:prod]db.main#UserName'),
    );
    expect(payload.isField, isTrue);
    expect(
      payload.data,
      'demo-password',
      reason: 'the field travels in the reference, not as field',
    );
    expect(payload.version, '2026-11-01T12:00:00.000Z b1946ac9');
    final get = service.received.last;
    expect(get['ref'], '[env:prod]db.main#UserName');
    expect(get.containsKey('field'), isFalse);
    expect(get['dimensions'], {'env': 'prod'});
    expect(get['wait'], isFalse);
    expect(get['timeoutMs'], 7000);
    final hello = service.received.first;
    expect((hello['client']! as Map)['name'], 'demo-server');
    await local.close();
  });

  test('registered as local, it resolves configuration and refreshes a '
      'rotated secret', () async {
    var password = 'demo-pw-1';
    var modified = '2026-11-01T12:00:00Z';
    service.answer = (r) => (r['ref'] as String).endsWith('#UserName')
        ? _value('demo-user')
        : _value(password, modified: modified);
    TomSecrets.register(provider());
    await TomSecrets.load({
      'db': {
        'password': 'secret:local:fleet/Db/Main',
        'user': 'secret:local:fleet/Db/Main#UserName',
      },
    });
    expect(TomSecrets.current('secret:local:fleet/Db/Main'), 'demo-pw-1');
    expect(
      TomSecrets.current('secret:local:fleet/Db/Main#UserName'),
      'demo-user',
    );
    expect(
      service.received.where((m) => m['op'] == 'get').map((m) => m['ref']),
      ['fleet/Db/Main', 'fleet/Db/Main#UserName'],
    );
    password = 'demo-pw-2';
    modified = '2026-11-14T09:00:00Z';
    final seen = <String>[];
    TomSecrets.watch('secret:local:fleet/Db/Main', seen.add);
    final outcome = await TomSecrets.refresh();
    expect(outcome.changed, ['secret:local:fleet/Db/Main']);
    expect(seen, ['demo-pw-2']);
    expect(
      TomSecrets.versionOf('secret:local:fleet/Db/Main'),
      '2026-11-14T09:00:00.000Z r1',
    );
  });

  test(
    'errors map onto the secrets keys, the kind named, never the value',
    () async {
      final local = provider();
      service.answer = (_) => _error('not_found');
      await expectLater(
        local.fetch(const TomSecretReference('local', 'demo.missing')),
        _refused('secrets.fetch.not_found'),
      );
      service.answer = (_) => _error('denied', 'no_approver');
      await expectLater(
        local.fetch(const TomSecretReference('local', 'demo.key')),
        throwsA(
          isA<TomSecretsException>()
              .having((e) => e.key, 'key', 'secrets.fetch.failed')
              .having((e) => e.parameters, 'parameters', {
                'provider': 'local',
                'reference': 'demo.key',
                'kind': 'denied',
                'reason': 'no_approver',
              }),
        ),
      );
      service.answer = (_) => _value('demo-bytes', encoding: 'base64');
      await expectLater(
        local.fetch(const TomSecretReference('local', 'demo.bin')),
        _refused('secrets.local.binary_not_text'),
      );
      await expectLater(
        local.fetch(const TomSecretReference('local', 'a//b')),
        throwsA(
          isA<TomSecretsException>().having(
            (e) => e.parameters?['kind'],
            'kind',
            'malformed',
          ),
        ),
      );
      await local.close();
    },
  );

  test('no service: secrets.fetch.failed, kind not_running', () async {
    final local = TomLocalSecretsProvider(
      environment: {'TSM_RUNTIME_DIR': '${service.dir.path}/nowhere'},
    );
    await expectLater(
      local.fetch(const TomSecretReference('local', 'demo.key')),
      throwsA(
        isA<TomSecretsException>().having(
          (e) => e.parameters?['kind'],
          'kind',
          'not_running',
        ),
      ),
    );
  });

  group('fromConfiguration', () {
    TomServerConfigResourceProvider config(Map<String, Object?> local) =>
        TomServerConfigResourceProvider.from({
          'secrets': {'local': local},
        });

    test('reads the settings; every one is optional', () async {
      final local = TomLocalSecretsProvider.fromConfiguration(
        config: config({
          'clientName': 'billing-server',
          'dimensions': {'env': 'prod'},
          'timeoutSeconds': 30,
          'waitForUnlock': false,
        }),
        environment: service.environment,
      );
      expect(local.name, 'local');
      expect(local.dimensions, {'env': 'prod'});
      expect(local.timeout, const Duration(seconds: 30));
      expect(local.wait, isFalse);
      await local.fetch(const TomSecretReference('local', 'demo.key'));
      expect(
        (service.received.first['client']! as Map)['name'],
        'billing-server',
      );
      await local.close();
      final plain = TomLocalSecretsProvider.fromConfiguration(
        config: TomServerConfigResourceProvider.from({}),
        environment: service.environment,
      );
      expect(plain.dimensions, isEmpty);
      expect(plain.wait, isTrue);
      expect(plain.timeout, isNull);
    });

    test('a malformed setting is refused by name', () {
      for (final bad in <Map<String, Object?>>[
        {'clientName': 3},
        {'dimensions': 'env=prod'},
        {
          'dimensions': {'env': 1},
        },
        {'timeoutSeconds': 0},
        {'waitForUnlock': 'yes'},
      ]) {
        expect(
          () => TomLocalSecretsProvider.fromConfiguration(config: config(bad)),
          _refused('secrets.local.config.malformed'),
          reason: '$bad',
        );
      }
    });
  });
}

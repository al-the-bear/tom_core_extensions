/// Wiring the Tom Secrets Manager into a Tom server's configuration.
///
/// A real server registers [TomLocalSecretsProvider.fromConfiguration], which
/// reads `secrets.local` and finds the secrets service of the machine's user
/// (or the runtime directory `TSM_RUNTIME_DIR` names). So that this example
/// runs anywhere, a stand-in answers the service's client protocol in-process
/// in a temporary runtime directory; against the real service drop the
/// `environment` argument.
///
/// Run with `dart run example/local_secrets_example.dart`.
library;

import 'dart:io';

import 'package:tom_core_secrets/local.dart';
import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_client/tom_secrets_client.dart'
    show
        TomSecretsFrameReader,
        tomSecretsDecodePayload,
        tomSecretsJsonFrame,
        tomSecretsMaxRequestPayload;

void _check(bool ok, String expectation) {
  if (!ok) throw StateError('example check failed: $expectation');
}

Future<void> main() async {
  // The stand-in service: one entry whose password rotates.
  final values = {
    '[env:prod]db.main': 'pw-1',
    '[env:prod]db.main#UserName': 'billing',
  };
  var modified = '2026-11-01T12:00:00Z';
  final runtime = Directory.systemTemp.createTempSync('tsm_example');
  final server = await _standIn(runtime, (request) {
    final value = values[request['ref']];
    if (value == null) {
      return {'op': 'error', 'kind': 'not_found', 'message': 'no such entry'};
    }
    return {
      'op': 'value',
      'value': value,
      'encoding': 'utf8',
      'entry': {
        'store': 'fleet',
        'uuid': '0f3c2a1b4d5e6f708192a3b4c5d6e7f8',
        'source': 'github',
        'fetchedAt': modified,
      },
      'bound': {'env': 'prod'},
      'version': {'modified': modified, 'revision': 'b1946ac9'},
    };
  });

  try {
    // 1. Register the provider; it answers every `secret:local:` reference.
    final provider = TomLocalSecretsProvider.fromConfiguration(
      config: TomServerConfigResourceProvider.from({
        'secrets': {
          'local': {'clientName': 'billing-server', 'timeoutSeconds': 30},
        },
      }),
      environment: {'TSM_RUNTIME_DIR': runtime.path},
    );
    TomSecrets.register(provider);

    // 2. A configuration names the password and the user name of one entry;
    //    the qualifier picks the prod overlay, the field after the last #.
    await TomSecrets.load({
      'database': {
        'password': 'secret:local:[env:prod]db.main',
        'user': 'secret:local:[env:prod]db.main#UserName',
      },
    });
    final password = TomSecrets.current('secret:local:[env:prod]db.main');
    _check(password == 'pw-1', 'the password resolved');
    _check(
      TomSecrets.current('secret:local:[env:prod]db.main#UserName') ==
          'billing',
      'the user name resolved',
    );
    print(
      '1. resolved user ${TomSecrets.current('secret:local:[env:prod]db.main#UserName')}',
    );

    // 3. The password rotates in the vault; a refresh finds it, the watcher
    //    hears it, and the version moves with it.
    final seen = <String>[];
    TomSecrets.watch('secret:local:[env:prod]db.main', seen.add);
    values['[env:prod]db.main'] = 'pw-2';
    modified = '2026-11-14T09:00:00Z';
    final outcome = await TomSecrets.refresh();
    _check(outcome.changed.length == 1, 'one reference changed');
    _check(seen.single == 'pw-2', 'the watcher heard the new password');
    print('2. rotated password arrived: ${seen.single}');
    print(
      '3. its version: '
      '${TomSecrets.versionOf('secret:local:[env:prod]db.main')}',
    );
  } finally {
    await TomSecrets.reset();
    await server.close();
    runtime.deleteSync(recursive: true);
  }
}

/// A stand-in for the secrets service's client endpoint in [runtime]: a Unix
/// socket, or on Windows a localhost port with client.port and client.token.
Future<ServerSocket> _standIn(
  Directory runtime,
  Map<String, Object?> Function(Map<String, Object?> request) answer,
) async {
  final ServerSocket server;
  if (Platform.isWindows) {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    File('${runtime.path}\\client.port').writeAsStringSync('${server.port}\n');
    File('${runtime.path}\\client.token').writeAsStringSync('example-token\n');
  } else {
    server = await ServerSocket.bind(
      InternetAddress(
        '${runtime.path}/client.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
  }
  server.listen((socket) {
    final reader = TomSecretsFrameReader(
      maxPayload: tomSecretsMaxRequestPayload,
    );
    socket.listen(
      (bytes) {
        for (final frame in reader.add(bytes)) {
          final request = tomSecretsDecodePayload(frame.payload);
          socket.add(
            tomSecretsJsonFrame(
              request['op'] == 'hello'
                  ? {
                      'op': 'welcome',
                      'protocol': 1,
                      'service': {'version': '0.1.0'},
                      'features': <String>[],
                      'host': 'example-host',
                      'platform': 'linux',
                    }
                  : {...answer(request), 'id': request['id']},
            ),
          );
        }
      },
      // The client hung up: close this side too, so nothing keeps the
      // process alive.
      onDone: socket.destroy,
      onError: (Object _) => socket.destroy(),
    );
  });
  return server;
}

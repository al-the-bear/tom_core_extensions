/// The server's message-bus invalidation channel between two nodes over NATS:
/// a grant revoked on one node is refused on the other within the channel's
/// bound. A node is a process with caches of its own; a spawned isolate is
/// one in every respect that matters here, and the only thing the two share
/// is the NATS server.
///
/// `@Tags(['nats'])`, self-skipping unless `tool/run_nats_tests.sh` started a
/// server and named it in `TOM_NATS_TEST_URL`.
@Tags(['nats'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_core_message_bus_nats/tom_core_message_bus_nats.dart';
import 'package:tom_core_server/tom_core_server.dart';

final String? _url = Platform.environment['TOM_NATS_TEST_URL'];

TomClientJwtToken _token(String username, DateTime issuedAt) {
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final payload = {
    'username': username,
    'iat': issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    'exp':
        issuedAt.toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000,
  };
  return TomClientJwtToken(
    '${segment({'alg': 'HS256', 'typ': 'JWT'})}.${segment(payload)}.sig',
    decrypt: false,
  );
}

/// Node B: joins through NATS, caches alice's principal, reports ready, then
/// reports how long after node A's signal it began refusing alice's token
/// (or `-1` if it never did within ten seconds).
Future<void> _nodeB(List<Object> args) async {
  final url = args[0] as String;
  final topic = args[1] as String;
  final ready = args[2] as SendPort;
  final result = args[3] as SendPort;
  final go = ReceivePort();

  final bus = await TomNatsMessageBus.connect(Uri.parse(url));
  await TomCacheInvalidator.install(
    TomBusInvalidationChannel(
      bus: bus,
      log: TomMemoryInvalidationLog(),
      topic: topic,
    ),
  );
  final token = _token(
    'alice',
    DateTime.now().subtract(const Duration(minutes: 5)),
  );
  await TomAuthorizationCache.storePrincipal(
    token,
    TomPrincipal(user: TomUser(username: 'alice'), authenticated: true),
  );
  final before = await TomAuthorizationCache.getPrincipal(token);
  ready.send([go.sendPort, before?.username ?? 'miss']);

  await go.first;
  final clock = Stopwatch()..start();
  var refusedAfter = -1;
  while (clock.elapsed < const Duration(seconds: 10)) {
    try {
      await TomAuthorizationCache.getPrincipal(token);
    } on TomAuthorizationCacheException catch (e) {
      if (e.key == 'authorization.cache.revoked_principal') {
        refusedAfter = clock.elapsedMilliseconds;
        break;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await TomCacheInvalidator.reset();
  await bus.close();
  result.send(refusedAfter);
}

void main() {
  test(
    'NB-V1: a grant revoked on one node is refused on the other within the '
    'channel\'s bound',
    () async {
      final topic =
          'invalidation-${Random().nextInt(1 << 32).toRadixString(16)}';
      final readyPort = ReceivePort();
      final resultPort = ReceivePort();
      await Isolate.spawn(_nodeB, <Object>[
        _url!,
        topic,
        readyPort.sendPort,
        resultPort.sendPort,
      ]);
      final ready = await readyPort.first as List;
      expect(ready[1], 'alice', reason: 'node B served alice before');

      // Node A: this isolate.
      final bus = await TomNatsMessageBus.connect(Uri.parse(_url!));
      addTearDown(bus.close);
      final channel = TomBusInvalidationChannel(
        bus: bus,
        log: TomMemoryInvalidationLog(),
        topic: topic,
      );
      await TomCacheInvalidator.install(channel);
      addTearDown(TomCacheInvalidator.reset);
      (ready[0] as SendPort).send(true);
      await TomCacheInvalidator.revokePrincipal('alice');

      final refusedAfterMs =
          await resultPort.first.timeout(const Duration(seconds: 20)) as int;
      expect(refusedAfterMs, isNot(-1), reason: 'node B never refused');
      expect(
        refusedAfterMs,
        lessThan(channel.stalenessBound.inMilliseconds),
        reason: 'refused within the stated bound',
      );
    },
    skip: _url == null
        ? 'TOM_NATS_TEST_URL is not set — run tool/run_nats_tests.sh'
        : null,
  );
}

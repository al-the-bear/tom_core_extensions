import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('AsyncShutdownCoordinator', () {
    test('runs the teardown to completion then terminates cleanly', () async {
      final signals = StreamController<String>();
      final order = <String>[];
      final exitCodes = <int>[];

      final coordinator = AsyncShutdownCoordinator.install<String>(
        label: 'test.shutdown',
        signals: [signals.stream],
        onShutdown: () async {
          order.add('teardown-start');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          order.add('teardown-end');
        },
        terminate: exitCodes.add,
      );

      signals.add('SIGTERM');
      final code = await coordinator.completed;

      expect(code, shutdownExitOk);
      expect(order, ['teardown-start', 'teardown-end']);
      expect(exitCodes, [shutdownExitOk]);
      expect(coordinator.isTriggered, isTrue);
      await signals.close();
    });

    test('a second signal during teardown is ignored', () async {
      final signals = StreamController<String>();
      var teardownCount = 0;
      final gate = Completer<void>();

      final coordinator = AsyncShutdownCoordinator.install<String>(
        label: 'test.shutdown',
        signals: [signals.stream],
        onShutdown: () async {
          teardownCount++;
          await gate.future;
        },
        terminate: (_) {},
      );

      signals.add('SIGINT');
      await Future<void>.delayed(const Duration(milliseconds: 1));
      signals.add('SIGINT'); // arrives mid-teardown
      await Future<void>.delayed(const Duration(milliseconds: 1));
      gate.complete();
      await coordinator.completed;

      expect(teardownCount, 1);
      await signals.close();
    });

    test('a throwing teardown still terminates with the error code', () async {
      final signals = StreamController<String>();
      final exitCodes = <int>[];

      final coordinator = AsyncShutdownCoordinator.install<String>(
        label: 'test.shutdown',
        signals: [signals.stream],
        onShutdown: () async => throw StateError('drain failed'),
        terminate: exitCodes.add,
      );

      signals.add('SIGTERM');
      final code = await coordinator.completed;

      expect(code, shutdownExitError);
      expect(exitCodes, [shutdownExitError]);
      await signals.close();
    });

    test('dispose stops listening without triggering shutdown', () async {
      final signals = StreamController<String>();
      var teardownCount = 0;

      final coordinator = AsyncShutdownCoordinator.install<String>(
        label: 'test.shutdown',
        signals: [signals.stream],
        onShutdown: () async => teardownCount++,
        terminate: (_) {},
      );

      await coordinator.dispose();
      signals.add('SIGTERM');
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(teardownCount, 0);
      expect(coordinator.isTriggered, isFalse);
      await signals.close();
    });
  });
}

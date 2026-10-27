// Unit tests for IsolateExceptionRegistry — the host-side map that
// rebuilds a typed exception from its flat wire form. These exercise the
// generic contract with throwaway local exception types; the concrete
// memory taxonomy is round-tripped in tom_brain_memory's own suite.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateExceptionRegistry;
import 'package:test/test.dart';

// ─── Local fake taxonomy (stands in for a real adapter's closed set) ──

final class _FakeNotFound implements Exception {
  final String key;
  final String message;
  _FakeNotFound({required this.key, required this.message});
}

final class _FakeRejected implements Exception {
  final int code;
  final List<String> reasons;
  final String message;
  _FakeRejected({
    required this.code,
    required this.reasons,
    required this.message,
  });
}

void main() {
  group('IsolateExceptionRegistry', () {
    test('reconstruct rebuilds the registered type from message + details', () {
      final registry = IsolateExceptionRegistry()
        ..register(
          '_FakeNotFound',
          (message, details) =>
              _FakeNotFound(key: details['key']! as String, message: message),
        );

      final rebuilt = registry.reconstruct(
        '_FakeNotFound',
        'no such key',
        <String, Object?>{'key': 'alpha'},
      );

      expect(rebuilt, isA<_FakeNotFound>());
      final typed = rebuilt! as _FakeNotFound;
      expect(typed.key, equals('alpha'));
      expect(typed.message, equals('no such key'));
    });

    test('reconstruct preserves structured fields including lists/ints', () {
      final registry = IsolateExceptionRegistry()
        ..register(
          '_FakeRejected',
          (message, details) => _FakeRejected(
            code: details['code']! as int,
            reasons: (details['reasons']! as List).cast<String>(),
            message: message,
          ),
        );

      final rebuilt =
          registry.reconstruct('_FakeRejected', 'denied', <String, Object?>{
                'code': 7,
                'reasons': <String>['a', 'b'],
              })
              as _FakeRejected;

      expect(rebuilt.code, equals(7));
      expect(rebuilt.reasons, equals(<String>['a', 'b']));
      expect(rebuilt.message, equals('denied'));
    });

    test('reconstruct returns null for an unregistered type (fallback)', () {
      final registry = IsolateExceptionRegistry();
      expect(registry.reconstruct('StateError', 'boom'), isNull);
    });

    test('details defaults to empty when omitted', () {
      final registry = IsolateExceptionRegistry()
        ..register('NoFields', (message, details) {
          expect(details, isEmpty);
          return _FakeNotFound(key: 'x', message: message);
        });
      expect(registry.reconstruct('NoFields', 'm'), isA<_FakeNotFound>());
    });

    test('isRegistered / registeredTypes reflect the registered set', () {
      final registry = IsolateExceptionRegistry()
        ..register(
          '_FakeNotFound',
          (m, d) => _FakeNotFound(key: '', message: m),
        )
        ..register(
          '_FakeRejected',
          (m, d) => _FakeRejected(code: 0, reasons: const [], message: m),
        );

      expect(registry.isRegistered('_FakeNotFound'), isTrue);
      expect(registry.isRegistered('_FakeRejected'), isTrue);
      expect(registry.isRegistered('Unknown'), isFalse);
      expect(
        registry.registeredTypes,
        unorderedEquals(<String>['_FakeNotFound', '_FakeRejected']),
      );
    });

    test('register overwrites a prior factory for the same tag', () {
      final registry = IsolateExceptionRegistry()
        ..register(
          '_FakeNotFound',
          (m, d) => _FakeNotFound(key: 'first', message: m),
        )
        ..register(
          '_FakeNotFound',
          (m, d) => _FakeNotFound(key: 'second', message: m),
        );

      final rebuilt =
          registry.reconstruct('_FakeNotFound', 'm') as _FakeNotFound;
      expect(rebuilt.key, equals('second'));
    });
  });
}

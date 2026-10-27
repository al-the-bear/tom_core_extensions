import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

class _Resource with CloseGuard {
  int released = 0;

  void use() {
    ensureOpen('_Resource.use');
  }

  void close() {
    if (!markClosed()) return;
    released++;
  }
}

void main() {
  group('CloseGuard', () {
    test('starts open', () {
      expect(_Resource().isClosed, isFalse);
    });

    test('ensureOpen is a no-op while open', () {
      final r = _Resource();
      expect(r.use, returnsNormally);
    });

    test('ensureOpen throws after close with the operation in the message', () {
      final r = _Resource()..close();
      expect(
        r.use,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            '_Resource.use called after close()',
          ),
        ),
      );
    });

    test(
      'markClosed transitions once and reports it; close() stays idempotent',
      () {
        final r = _Resource();
        expect(r.isClosed, isFalse);
        r.close();
        expect(r.isClosed, isTrue);
        expect(r.released, 1);
        r.close(); // second call short-circuits
        expect(r.released, 1);
      },
    );
  });
}

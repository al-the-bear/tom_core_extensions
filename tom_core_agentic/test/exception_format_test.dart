import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

/// A concrete exception used to verify `runtimeType` resolves to the
/// most-derived class when `this` is passed from a base method.
final class _SampleException implements Exception {
  final String message;
  final String? context;

  _SampleException(this.message, {this.context});

  @override
  String toString() => formatException(this, message, context: context);
}

void main() {
  group('formatException', () {
    test('bare form omits the parenthesised context', () {
      expect(formatException(_Marker(), 'boom'), equals('_Marker: boom'));
    });

    test('context form wraps the fragment in parentheses', () {
      expect(
        formatException(_Marker(), 'boom', context: 'Event'),
        equals('_Marker(Event): boom'),
      );
    });

    test('empty context renders as ()', () {
      expect(
        formatException(_Marker(), 'boom', context: ''),
        equals('_Marker(): boom'),
      );
    });

    test('resolves the most-derived runtimeType via this', () {
      expect(
        _SampleException('boom', context: 'X').toString(),
        equals('_SampleException(X): boom'),
      );
      expect(
        _SampleException('boom').toString(),
        equals('_SampleException: boom'),
      );
    });
  });
}

final class _Marker {}

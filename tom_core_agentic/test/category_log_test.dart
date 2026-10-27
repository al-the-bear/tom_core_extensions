import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

enum _Cat {
  host('demo.host'),
  store('demo.store');

  const _Cat(this.name);
  final String name;
}

final class _DemoLog extends CategoryLog {
  const _DemoLog._(this.category);
  final _Cat category;

  @override
  String get categoryName => category.name;

  static const _DemoLog host = _DemoLog._(_Cat.host);
  static const _DemoLog store = _DemoLog._(_Cat.store);
}

void main() {
  group('CategoryLog.tagMessage', () {
    test('tags an eager (non-function) message', () {
      expect(CategoryLog.tagMessage('demo.host', 'hello'), '[demo.host] hello');
    });

    test('tags a lazy () => Object message only when evaluated', () {
      var evaluated = 0;
      final tagged = CategoryLog.tagMessage('demo.host', () {
        evaluated++;
        return 'expensive';
      });
      // Not evaluated yet — the wrapper must defer the inner call.
      expect(evaluated, 0);
      expect(tagged, isA<Object Function()>());
      final rendered = (tagged as Object Function())();
      expect(rendered, '[demo.host] expensive');
      expect(evaluated, 1);
    });

    test('tags a lazy () => String message', () {
      final tagged = CategoryLog.tagMessage('demo.store', () => 'lazy');
      expect((tagged as Object Function())(), '[demo.store] lazy');
    });
  });

  group('CategoryLog subclass', () {
    test('exposes the category name and supports const instances', () {
      expect(_DemoLog.host.categoryName, 'demo.host');
      expect(_DemoLog.store.categoryName, 'demo.store');
      expect(identical(_DemoLog.host, _DemoLog.host), isTrue);
    });
  });
}

// The base of the agent sidecar stores: its writes run in the order they were
// asked for, a failed write does not stop the next, and a store made in one
// zone writes when it is used from another (a widget test makes its stores in
// a fake-async zone and sends in the real one).

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_file_system/tom_file_system.dart';

/// An in-memory workspace whose writes can be made to fail.
class _FlakyWorkspace extends TomMemoryFileSystem {
  int failNext = 0;

  @override
  Future<TomFileRevision> write(
    Uri uri,
    Uint8List bytes, {
    TomFileRevision? expected,
  }) async {
    if (failNext > 0) {
      failNext--;
      throw StateError('disk full');
    }
    return super.write(uri, bytes, expected: expected);
  }
}

void main() {
  test('AS-1: writes land in the order they were asked for; settled '
      'completes when they have', () async {
    final fs = TomMemoryFileSystem();
    final store = ChatVariableStore.resolveDefault(fs);
    for (var i = 0; i < 5; i++) {
      unawaited(store.save([ChatVariable(name: 'v', value: '$i')]));
    }
    await store.settled;
    expect((await store.load()).single.value, '4');
    expect(store.uri, fs.uriOf('.tom/chat_variables.yaml'));
  });

  test('AS-2: a failed write fails its caller\'s future and the next write '
      'still runs', () async {
    final fs = _FlakyWorkspace()..failNext = 1;
    final store = ChatVariableStore.resolveDefault(fs);
    final failed = store.save(const [ChatVariable(name: 'a', value: '1')]);
    final next = store.save(const [ChatVariable(name: 'a', value: '2')]);
    await expectLater(failed, throwsStateError);
    await next;
    expect((await store.load()).single.value, '2');
  });

  test('AS-3: a store made in a zone that never runs its microtasks writes '
      'when used from another zone', () async {
    final held = <void Function()>[];
    late ChatVariableStore store;
    // A zone whose microtasks are held, never run — what a widget test's
    // fake-async zone is between pumps.
    runZoned(
      () => store = ChatVariableStore.resolveDefault(TomMemoryFileSystem()),
      zoneSpecification: ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, task) => held.add(task),
      ),
    );
    await store
        .save(const [ChatVariable(name: 'x', value: 'y')])
        .timeout(const Duration(seconds: 5));
    await store.settled.timeout(const Duration(seconds: 5));
    expect((await store.load()).single.value, 'y');
  });

  test('AS-4: TOM_SPECS_*_FILE in the environment places the sidecar, '
      'relative to the workspace or absolute; an empty one is ignored', () {
    final fs = TomMemoryFileSystem();
    Uri at(Map<String, String> environment) =>
        ChatVariableStore.resolveDefault(fs, environment: environment).uri;
    expect(
      at(const {'TOM_SPECS_CHATVARS_FILE': 'cfg/vars.yaml'}),
      fs.uriOf('cfg/vars.yaml'),
    );
    expect(
      at(const {'TOM_SPECS_CHATVARS_FILE': '/elsewhere/vars.yaml'}).path,
      '/elsewhere/vars.yaml',
    );
    expect(
      at(const {'TOM_SPECS_CHATVARS_FILE': ''}),
      fs.uriOf('.tom/chat_variables.yaml'),
    );
  });
}

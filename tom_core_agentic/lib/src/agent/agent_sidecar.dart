// Shared read + decode for the editor's YAML sidecar stores.
//
// The eleven sidecars — queue, profiles, chat variables, prompt, queue and
// reminder templates, timed requests, trail, agent settings, bridge choice,
// session id — all make one promise: a damaged file costs the user a reset,
// never a crash. They share one base, [AgentSidecarStore], which reads and
// writes through the workspace's file system and keeps that promise, so "all
// eleven degrade the same way" is a property of one class rather than a claim
// about eleven separate bodies.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tom_file_system/tom_file_system.dart';

import 'agent_yaml.dart';

/// A store keeping its state in one YAML sidecar file of a workspace, read
/// and written through the workspace's [TomFileSystem] — on the local disk,
/// in memory in a test, on the web.
///
/// The writes of one store run one after the other, in the order they were
/// asked for, so the file always ends at the latest state; [settled]
/// completes when every write asked for so far has landed. A write that fails
/// fails the future its caller got, and the next write still runs.
abstract base class AgentSidecarStore {
  AgentSidecarStore({required this.fileSystem, required this.uri});

  /// The file system the sidecar is read and written through.
  final TomFileSystem fileSystem;

  /// The sidecar file.
  final Uri uri;

  /// The writes asked for and not yet run, in order.
  final List<Future<void> Function()> _pending = [];

  /// Whether [_drain] is running the writes.
  bool _draining = false;

  /// Callers of [settled] waiting for the writes to run out.
  final List<Completer<void>> _settleWaiters = [];

  /// Completes when every write asked for so far has landed or failed.
  Future<void> get settled {
    if (!_draining) return Future.value();
    final waiter = Completer<void>();
    _settleWaiters.add(waiter);
    return waiter.future;
  }

  /// Where a store's sidecar lives in [fileSystem]: the path the
  /// [environment] variable [variable] names when it is set (relative to the
  /// workspace, or absolute), else [defaultPath].
  static Uri locate(
    TomFileSystem fileSystem, {
    required Map<String, String> environment,
    required String variable,
    required String defaultPath,
  }) {
    final override = environment[variable];
    return fileSystem.uriOf(
      override != null && override.isNotEmpty ? override : defaultPath,
    );
  }

  /// The sidecar parsed, or `null` when it is missing, empty, unreadable or
  /// malformed.
  ///
  /// The four cases collapse into one result on purpose: to a caller about to
  /// fall back on its defaults, a file it cannot use and a file that is not
  /// there are the same file.
  @protected
  Future<Map<String, dynamic>?> readRoot() async {
    final String? content;
    try {
      content = await fileSystem.readTextIfExists(uri);
    } on Exception {
      // Unreadable (permissions, not UTF-8): the defaults, as for a missing
      // file.
      return null;
    }
    if (content == null || content.trim().isEmpty) return null;
    try {
      return decodeAgentYaml(content);
    } on FormatException {
      // Covers YAML syntax damage as well: a `YamlException` is a
      // `FormatException`.
      return null;
    }
  }

  /// Writes [text] to the sidecar, making its folder when it is missing,
  /// after the writes asked for before.
  @protected
  Future<void> writeText(String text) =>
      _enqueue(() => fileSystem.writeTextMakingFolder(uri, text));

  /// Removes the sidecar when it exists, after the writes asked for before.
  @protected
  Future<void> deleteFile() => _enqueue(() async {
    if (await fileSystem.exists(uri)) await fileSystem.delete(uri);
  });

  // Why: no future outlives one write. Each caller gets a future made in its
  // own zone, and the queue is a list rather than a chain of futures, so a
  // store used from two zones (a widget test's fake-async zone and the real
  // one) never waits on a future whose zone does not run.
  Future<void> _enqueue(Future<void> Function() write) {
    final done = Completer<void>();
    _pending.add(() async {
      try {
        await write();
        done.complete();
      } on Object catch (error, stack) {
        // The failure goes to the caller; the next write still runs.
        done.completeError(error, stack);
      }
    });
    if (!_draining) unawaited(_drain());
    return done.future;
  }

  Future<void> _drain() async {
    _draining = true;
    while (_pending.isNotEmpty) {
      await _pending.removeAt(0)();
    }
    _draining = false;
    for (final waiter in _settleWaiters) {
      waiter.complete();
    }
    _settleWaiters.clear();
  }
}

/// Builds the models in the list under [key] of [root], skipping the entries
/// the file cannot supply.
///
/// An entry is skipped when it is not a mapping, when its [identity] field is
/// not a non-empty string, or when [fromYaml] cannot read it.
///
/// **Skipping rather than defaulting** the identity is deliberate: an entry
/// with no id cannot afterwards be selected, edited or deleted, so
/// materialising one under a synthetic id would turn a recoverable data error
/// into a permanent orphan.
///
/// **Skipping per entry rather than failing the load** is the other half, and
/// the more valuable one. The stores used to discard the whole file the
/// moment anything in it was unreadable, so one bad row cost the user every
/// good row beside it.
///
/// The [identity] requirement is what separates a store's top-level list from
/// the nested lists inside an entry, which [decodeAgentYamlEntries] handles
/// without one.
List<T> decodeAgentYamlList<T>(
  Map<String, dynamic>? root, {
  required String key,
  required String identity,
  required T Function(Map<String, dynamic>) fromYaml,
}) => decodeAgentYamlEntries(root?[key], fromYaml, identity: identity) ?? <T>[];

/// Builds the single model under [key] of [root], or [orElse] when the file
/// cannot supply it. The singleton counterpart of [decodeAgentYamlList] —
/// with nothing to skip *to*, an unusable value falls back rather than
/// dropping out.
T decodeAgentYamlValue<T>(
  Map<String, dynamic>? root, {
  required String key,
  required T Function(Map<String, dynamic>) fromYaml,
  required T orElse,
}) {
  final value = root?[key];
  if (value is! Map) return orElse;
  try {
    return fromYaml(value.cast<String, dynamic>());
  } on TypeError {
    return orElse;
  }
}

/// A small record kind, a storage double and a sync unit over them — enough to
/// drive the merge, the engine and the scheduler without any application.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:tom_core_storage/tom_core_storage.dart';
import 'package:tom_core_sync/tom_core_sync.dart';

/// One note: an id, a text, and when it was last changed.
class Note {
  final String id;
  final String text;
  final DateTime? modified;

  const Note(this.id, this.text, [this.modified]);

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    if (modified != null) 'modified': modified!.toUtc().toIso8601String(),
  };

  static Note fromJson(Map<String, Object?> json) => Note(
    json['id']! as String,
    json['text']! as String,
    json['modified'] == null
        ? null
        : DateTime.parse(json['modified']! as String),
  );

  @override
  String toString() => 'Note($id: $text)';
}

/// How the merge reads a [Note].
class NoteCodec implements TomRecordCodec<Note> {
  const NoteCodec();

  @override
  String idOf(Note record) => record.id;

  @override
  DateTime? modifiedOf(Note record) => record.modified;

  @override
  Uint8List canonicalBytes(Note record) =>
      utf8.encode(jsonEncode(record.toJson()));
}

DateTime at(int minute) => DateTime.utc(2026, 1, 1, 12, minute);

Map<String, Note> notes(Iterable<Note> list) => {for (final n in list) n.id: n};

Uint8List encodeNotes(Map<String, Note> notes) => utf8.encode(
  jsonEncode([
    for (final key in notes.keys.toList()..sort()) notes[key]!.toJson(),
  ]),
);

Map<String, Note> decodeNotes(Uint8List bytes) => notes([
  for (final raw in jsonDecode(utf8.decode(bytes)) as List)
    Note.fromJson((raw as Map).cast<String, Object?>()),
]);

/// A single-file storage double with compare-and-swap, opaque heads, and
/// switches for the failures the loop must handle.
class FakeStorage extends TomStorage {
  final String prefix;
  final Map<String, Uint8List> files = {};
  final Map<String, String> heads = {};

  /// Heads are minted from this list in turn, so a test can choose heads
  /// whose lexical order runs backwards.
  final List<String> headNames;
  int _minted = 0;

  int headsOfCalls = 0;
  int commits = 0;
  Object? failReads;
  Object? failCommits;
  TomBackoffPolicy? adopted;

  FakeStorage({this.prefix = 'mem:', List<String>? headNames})
    : headNames = headNames ?? const [];

  String _mint() =>
      _minted < headNames.length ? headNames[_minted++] : 'h${_minted++}';

  /// Puts [bytes] at [locator] as another writer would.
  void seed(String locator, Uint8List bytes) {
    files[locator] = bytes;
    heads[locator] = _mint();
  }

  @override
  void adoptBackoff(TomBackoffPolicy policy) => adopted = policy;

  @override
  bool handles(String locator) => locator.startsWith(prefix);

  @override
  Future<List<TomStorageEntry>> list(String locator) async => const [];

  @override
  Future<Uint8List> readBytes(String locator) async {
    if (failReads != null) throw failReads!;
    final bytes = files[locator];
    if (bytes == null) throw TomContainerNotFoundException(locator);
    return bytes;
  }

  @override
  Future<TomBundleMedium> readBundle(String locator) async =>
      throw TomContainerNotFoundException(locator);

  @override
  Future<String> commit(
    String locator,
    TomChangeset changeset, {
    String? expectedHead,
    String? message,
    TomCommitProgressSink? onProgress,
  }) async {
    if (failCommits != null) throw failCommits!;
    if (heads[locator] != expectedHead) {
      throw TomCasConflictException(
        locator,
        expectedHead: expectedHead,
        actualHead: heads[locator],
      );
    }
    commits++;
    files[locator] = changeset.containerBytes;
    return heads[locator] = _mint();
  }

  @override
  Future<void> delete(String locator) async {
    files.remove(locator);
    heads.remove(locator);
  }

  @override
  Future<String?> headOf(String locator) async {
    if (failReads != null) throw failReads!;
    return heads[locator];
  }

  @override
  Future<Map<String, String?>> headsOf(Iterable<String> locators) async {
    headsOfCalls++;
    if (failReads != null) throw failReads!;
    return {for (final l in locators) l: heads[l]};
  }
}

/// A sync unit holding notes: merged per id by [tomMergeKeyed], committed as
/// one JSON file.
class NotesUnit implements TomSyncUnit {
  @override
  final String locator;

  @override
  final FakeStorage storage;

  @override
  String? head;

  Map<String, Note> working = {};
  Map<String, Note> base = {};
  bool _dirty = false;
  bool disposed = false;
  Object? keyRequired;

  final StreamController<void> _edits = StreamController<void>.broadcast(
    sync: true,
  );

  NotesUnit(this.locator, this.storage);

  /// A local edit, announced on [edits].
  void put(Note note) {
    working[note.id] = note;
    _dirty = true;
    _edits.add(null);
  }

  @override
  Stream<void> get edits => _edits.stream;

  @override
  bool get hasLocalChanges => _dirty || head == null;

  @override
  Future<List<TomSyncConflict>> pull(String remoteHead) async {
    if (keyRequired != null) throw keyRequired!;
    final theirs = decodeNotes(await storage.readBytes(locator));
    final result = tomMergeKeyed(
      base: base,
      ours: working,
      theirs: theirs,
      codec: const NoteCodec(),
    );
    working = result.merged;
    base = theirs;
    head = remoteHead;
    return result.conflicts;
  }

  @override
  Future<List<TomSyncConflict>> push() async {
    _dirty = false;
    final bytes = encodeNotes(working);
    try {
      head = await storage.commit(
        locator,
        TomChangeset.singleFile(bytes),
        expectedHead: head,
      );
      base = Map.of(working);
      return const [];
    } on TomCasConflictException {
      _dirty = true;
      throw TomCasExhaustedException(locator, conflicts: const [], attempts: 1);
    } catch (cause) {
      _dirty = true;
      throw TomCommitFailedException(
        locator,
        changeset: TomChangeset.singleFile(bytes),
        baseHead: head,
        version: 0,
        commitMessage: 'notes',
        cause: cause,
      );
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _edits.close();
  }
}

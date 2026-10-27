import 'package:test/test.dart';
import 'package:tom_core_sync/tom_core_sync.dart';

import 'support/notes.dart';

TomKeyedMergeResult<Note> merge(
  List<Note> base,
  List<Note> ours,
  List<Note> theirs, {
  TomMergeTie tie = TomMergeTie.ours,
  TomDeleteEditPolicy deleteEdit = TomDeleteEditPolicy.keepEditSilently,
}) => tomMergeKeyed(
  base: notes(base),
  ours: notes(ours),
  theirs: notes(theirs),
  codec: const NoteCodec(),
  tie: tie,
  deleteEdit: deleteEdit,
);

void main() {
  const a = Note('a', 'one');

  group('MERGE: the keyed three-way merge', () {
    test('MERGE-1: a key only one side changed takes that side, with no '
        'conflict — a deletion included', () {
      final edited = Note('a', 'edited', at(5));
      final r = merge(
        [a, const Note('b', 'x')],
        [edited, const Note('b', 'x')],
        [a],
      );
      expect(r.merged.keys, ['a']);
      expect(r.merged['a'], same(edited));
      expect(r.conflicts, isEmpty);
    });

    test('MERGE-2: the same edit on both sides, or a deletion on both, is no '
        'conflict', () {
      final r = merge([a, const Note('b', 'x')], [const Note('a', 'two')], [
        const Note('a', 'two'),
      ]);
      expect(r.merged.values.single.text, 'two');
      expect(r.conflicts, isEmpty);
    });

    test('MERGE-3: an edit against a deletion keeps the edit, silently by '
        'default and reported when asked', () {
      final edited = Note('a', 'edited', at(9));
      final silent = merge([a], [edited], []);
      expect(silent.merged['a'], same(edited));
      expect(silent.conflicts, isEmpty);

      final reported = merge(
        [a],
        [],
        [edited],
        deleteEdit: TomDeleteEditPolicy.keepEditAndReport,
      );
      expect(reported.merged['a'], same(edited));
      final c = reported.conflicts.single;
      expect(c.chosen, same(edited));
      expect(c.ours, isNull);
      expect(c.loser, isNull, reason: 'a deletion has nothing to retain');
      expect(reported.losers, isEmpty);
    });

    test('MERGE-4: two different edits go to the newer stamp, and the loser '
        'is retained', () {
      final ours = Note('a', 'mine', at(1));
      final theirs = Note('a', 'yours', at(2));
      final r = merge([a], [ours], [theirs]);
      final c = r.conflicts.single;
      expect(c.anchor, 'a');
      expect(c.base, same(a));
      expect(c.chosen, same(theirs));
      expect(c.oursChosen, isFalse);
      expect(c.loser, same(ours));
      expect(r.losers, {'a': ours});
    });

    test('MERGE-5: a tie goes to ours, or to the later canonical bytes', () {
      final ours = Note('a', 'b-text', at(3));
      final theirs = Note('a', 'z-text', at(3));
      expect(merge([a], [ours], [theirs]).merged['a'], same(ours));
      expect(
        merge([a], [ours], [
          theirs,
        ], tie: TomMergeTie.canonicalOrder).merged['a'],
        same(theirs),
      );
      expect(
        merge([a], [theirs], [
          ours,
        ], tie: TomMergeTie.canonicalOrder).merged['a'],
        same(theirs),
        reason: 'the canonical order does not depend on which side is ours',
      );
    });

    test('MERGE-6: both sides adding a key independently has no ancestor', () {
      final r = merge([], [const Note('n', 'x')], [const Note('n', 'y')]);
      expect(r.conflicts.single.base, isNull);
    });

    test('MERGE-7: copies in different major formats are refused before '
        'anything is compared', () {
      expect(
        () => tomMergeKeyed(
          base: const <String, Note>{},
          ours: notes([a]),
          theirs: notes([a]),
          codec: const NoteCodec(),
          formatVersions: (ours: '1.4', theirs: '2.0'),
          location: 'mem:/doc',
        ),
        throwsA(
          isA<TomMergeRefusedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('mem:/doc'), contains('1.4'), contains('2.0')),
          ),
        ),
      );
    });

    test('MERGE-7b: different minors of one major merge', () {
      final r = tomMergeKeyed(
        base: const <String, Note>{},
        ours: notes([a]),
        theirs: notes([a]),
        codec: const NoteCodec(),
        formatVersions: (ours: '1.0', theirs: '1.9'),
      );
      expect(r.merged['a'], same(a));
    });

    test('MERGE-8: merged keys keep first-seen order: ancestor, ours, '
        'theirs', () {
      final r = merge(
        [const Note('b', 'b')],
        [const Note('b', 'b'), const Note('c', 'c')],
        [const Note('b', 'b'), const Note('a', 'a')],
      );
      expect(r.merged.keys, ['b', 'c', 'a']);
    });

    test('MERGE-9: a conflict over a triple a caller holds picks the version '
        'the merge would pick, and refuses two deletions', () {
      final ours = Note('a', 'mine', at(4));
      final theirs = Note('a', 'yours', at(2));
      final c = tomMergeConflictOf(
        key: 'a',
        base: a,
        ours: ours,
        theirs: theirs,
        codec: const NoteCodec(),
      );
      expect(c.chosen, same(ours));
      expect(
        tomMergeConflictOf<Note>(
          key: 'a',
          ours: null,
          theirs: theirs,
          codec: const NoteCodec(),
        ).chosen,
        same(theirs),
      );
      expect(
        () => tomMergeConflictOf<Note>(
          key: 'a',
          ours: null,
          theirs: null,
          codec: const NoteCodec(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('CONFLICT: conflict records', () {
    test('CONFLICT-1: a record anchors on its key and copies its retained '
        'version with the copier it is given', () {
      final record = TomConflictRecord<Note>(
        key: 'a',
        loser: '.history/a/1.yaml',
        retained: const Note('a', 'lost'),
      );
      expect(record.anchor, 'a');
      final copy = record.copyWith((n) => Note(n.id, '${n.text}!'));
      expect(copy.loser, record.loser);
      expect(copy.retained!.text, 'lost!');
      expect(
        TomConflictRecord<Note>(key: 'a').copyWith((n) => n).retained,
        isNull,
      );
    });
  });
}

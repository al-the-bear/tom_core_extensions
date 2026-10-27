import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('classifyDeliberationCue', () {
    test('a plain prompt with no cue is normal', () {
      expect(
        classifyDeliberationCue('how do I configure the bomber?'),
        DeliberationVerdict.normal,
      );
      expect(
        classifyDeliberationCue('what time is the meeting'),
        DeliberationVerdict.normal,
      );
    });

    test('a "think about" prompt is thinking', () {
      expect(
        classifyDeliberationCue('think about whether we should migrate'),
        DeliberationVerdict.thinking,
      );
    });

    test('every canonical cue triggers the thinking branch', () {
      for (final cue in deliberationCues) {
        expect(
          classifyDeliberationCue('please $cue this for me'),
          DeliberationVerdict.thinking,
          reason: 'cue "$cue" must route to thinking',
        );
      }
    });

    test('matching is case-insensitive', () {
      expect(
        classifyDeliberationCue('PONDER the tradeoffs'),
        DeliberationVerdict.thinking,
      );
      expect(
        classifyDeliberationCue('Research the current API'),
        DeliberationVerdict.thinking,
      );
    });

    test('matching is word-boundary aware — no substring false positives', () {
      // "research" inside "researcher" must NOT trigger; the user is naming a
      // role, not asking us to research.
      expect(
        classifyDeliberationCue('who is the lead researcher here?'),
        DeliberationVerdict.normal,
      );
      // "ponder" inside a longer word likewise does not trigger.
      expect(
        classifyDeliberationCue('the responder sent a 200'),
        DeliberationVerdict.normal,
      );
    });

    test(
      'empty and whitespace-only text are normal (total + deterministic)',
      () {
        expect(classifyDeliberationCue(''), DeliberationVerdict.normal);
        expect(classifyDeliberationCue('   \n\t'), DeliberationVerdict.normal);
      },
    );

    test('the same input always yields the same verdict', () {
      const prompt = 'reason about the failure modes';
      final first = classifyDeliberationCue(prompt);
      final second = classifyDeliberationCue(prompt);
      expect(first, second);
      expect(first, DeliberationVerdict.thinking);
    });

    test('a multi-word cue matches across its internal space', () {
      expect(
        classifyDeliberationCue('work through the proof step by step'),
        DeliberationVerdict.thinking,
      );
      // but the words apart, not as the phrase, do not match
      expect(
        classifyDeliberationCue('the work is done, walk me through the door'),
        DeliberationVerdict.normal,
      );
    });
  });
}

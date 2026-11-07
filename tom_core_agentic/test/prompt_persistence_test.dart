// Round-trip tests for the prompt-queue and prompt-trail YAML stores. Each
// store writes to a file of an in-memory workspace and reloads to an equal model list, and degrades to an empty list on a missing/malformed file.

import 'package:test/test.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_file_system/tom_file_system.dart';

void main() {
  group('PromptQueueStore', () {
    late TomMemoryFileSystem fs;

    setUp(() => fs = TomMemoryFileSystem());

    PromptQueueStore store() => PromptQueueStore.resolveDefault(fs);

    QueuedPrompt prompt(
      String id,
      String text, {
      QueuedPromptStatus status = QueuedPromptStatus.pending,
    }) => QueuedPrompt(
      id: id,
      originalText: text,
      expandedText: text,
      createdAt: '2026-06-17T10:00:00Z',
      status: status,
    );

    test(
      'round-trips a queue through YAML preserving order and status',
      () async {
        final s = store();
        await s.save([
          prompt('a', 'first'),
          prompt('b', 'second', status: QueuedPromptStatus.error),
        ]);

        final loaded = (await s.load());
        expect(loaded.map((p) => p.id), ['a', 'b']);
        expect(loaded[0].originalText, 'first');
        expect(loaded[1].status, QueuedPromptStatus.error);
      },
    );

    test('returns an empty list for a missing file', () async {
      expect(await store().load(), isEmpty);
    });

    test('returns an empty list for a malformed file', () async {
      final s = store();
      await fs.writeTextMakingFolder(s.uri, ': not a mapping :');
      expect(await (await s.load()), isEmpty);
    });
  });

  group('PromptTrailStore', () {
    late TomMemoryFileSystem fs;

    setUp(() => fs = TomMemoryFileSystem());

    PromptTrailStore store() => PromptTrailStore.resolveDefault(fs);

    TrailPair pair(String id, String request, String? answer) => TrailPair(
      id: id,
      createdAt: '2026-06-17T10:00:00Z',
      request: ChatMessage(
        id: '$id-q',
        role: ChatRole.user,
        text: request,
        createdAt: '2026-06-17T10:00:00Z',
      ),
      answer: answer == null
          ? null
          : ChatMessage(
              id: '$id-a',
              role: ChatRole.assistant,
              text: answer,
              createdAt: '2026-06-17T10:00:01Z',
            ),
    );

    test(
      'round-trips request/answer pairs, including a pending answer',
      () async {
        final s = store();
        await s.save([
          pair('p1', 'ask one', 'answer one'),
          pair('p2', 'ask two', null),
        ]);

        final loaded = (await s.load());
        expect(loaded.map((p) => p.id), ['p1', 'p2']);
        expect(loaded[0].request.text, 'ask one');
        expect(loaded[0].answer?.text, 'answer one');
        expect(loaded[1].answer, isNull);
      },
    );

    test('returns an empty list for a missing file', () async {
      expect(await store().load(), isEmpty);
    });
  });
}

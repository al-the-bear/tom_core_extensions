// Round-trip tests for the prompt-queue and prompt-trail YAML stores. Each
// store writes to a temp file and reloads to an equal model list, and degrades to an empty list on a missing/malformed file.

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('PromptQueueStore', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('tom_specs_queue'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    PromptQueueStore store() =>
        PromptQueueStore(File('${dir.path}/prompt_queue.yaml'));

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

    test('round-trips a queue through YAML preserving order and status', () {
      final s = store();
      s.save([
        prompt('a', 'first'),
        prompt('b', 'second', status: QueuedPromptStatus.error),
      ]);

      final loaded = s.load();
      expect(loaded.map((p) => p.id), ['a', 'b']);
      expect(loaded[0].originalText, 'first');
      expect(loaded[1].status, QueuedPromptStatus.error);
    });

    test('returns an empty list for a missing file', () {
      expect(store().load(), isEmpty);
    });

    test('returns an empty list for a malformed file', () {
      final file = File('${dir.path}/prompt_queue.yaml')
        ..writeAsStringSync(': not a mapping :');
      expect(PromptQueueStore(file).load(), isEmpty);
    });
  });

  group('PromptTrailStore', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('tom_specs_trail'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    PromptTrailStore store() =>
        PromptTrailStore(File('${dir.path}/prompt_trail.yaml'));

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

    test('round-trips request/answer pairs, including a pending answer', () {
      final s = store();
      s.save([
        pair('p1', 'ask one', 'answer one'),
        pair('p2', 'ask two', null),
      ]);

      final loaded = s.load();
      expect(loaded.map((p) => p.id), ['p1', 'p2']);
      expect(loaded[0].request.text, 'ask one');
      expect(loaded[0].answer?.text, 'answer one');
      expect(loaded[1].answer, isNull);
    });

    test('returns an empty list for a missing file', () {
      expect(store().load(), isEmpty);
    });
  });
}

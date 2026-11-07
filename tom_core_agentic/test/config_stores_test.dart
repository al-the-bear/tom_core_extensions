// Round-trip tests for the config-editor YAML stores: agent profiles, prompt templates, queue templates, timed requests, and the
// singleton agent settings. Each store writes to a file of an in-memory workspace and reloads to an
// equal model, and degrades to the empty/default value on a missing/malformed
// file — mirroring the existing PromptQueueStore/ChatVariableStore behaviour.

import 'package:test/test.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_file_system/tom_file_system.dart';

void main() {
  late TomMemoryFileSystem _fs;
  setUp(() => _fs = TomMemoryFileSystem());

  Uri f(String name) => _fs.uriOf(name);

  group('AgentProfileStore', () {
    test('round-trips profiles preserving order and key fields', () async {
      final store = AgentProfileStore(fileSystem: _fs, uri: f('profiles.yaml'));
      await store.save([
        const AgentProfile(
          id: 'p1',
          name: 'Builder',
          systemPrompt: 'You build.',
          maxTokens: 4096,
          interruptRetryPrefix: 'Resuming after an interruption.',
        ),
        const AgentProfile(id: 'p2', name: 'Reviewer', isDefault: true),
      ]);

      final loaded = (await store.load());
      expect(loaded.map((p) => p.id), ['p1', 'p2']);
      expect(loaded[0].maxTokens, 4096);
      expect(loaded[0].interruptRetryPrefix, 'Resuming after an interruption.');
      expect(loaded[1].isDefault, isTrue);
    });

    test('returns an empty list for a missing file', () async {
      expect(
        (await AgentProfileStore(
          fileSystem: _fs,
          uri: f('missing.yaml'),
        ).load()),
        isEmpty,
      );
    });

    test('returns an empty list for a malformed file', () async {
      final file = f('bad.yaml');
      await _fs.writeText(file, ': not a mapping :');
      expect(
        (await AgentProfileStore(fileSystem: _fs, uri: file).load()),
        isEmpty,
      );
    });
  });

  group('PromptTemplateStore', () {
    test(
      'round-trips prompt templates including the user-message flag',
      () async {
        final store = PromptTemplateStore(
          fileSystem: _fs,
          uri: f('prompts.yaml'),
        );
        await store.save([
          const PromptTemplate(
            id: 't1',
            name: 'Greeting',
            body: 'Hello \${name}',
            isUserMessage: true,
          ),
          const PromptTemplate(id: 't2', name: 'Empty'),
        ]);

        final loaded = (await store.load());
        expect(loaded.map((t) => t.id), ['t1', 't2']);
        expect(loaded[0].body, 'Hello \${name}');
        expect(loaded[0].isUserMessage, isTrue);
        expect(loaded[1].isUserMessage, isFalse);
      },
    );

    test('returns an empty list for a missing file', () async {
      expect(
        (await PromptTemplateStore(
          fileSystem: _fs,
          uri: f('missing.yaml'),
        ).load()),
        isEmpty,
      );
    });
  });

  group('QueueTemplateStore', () {
    test('round-trips queue templates preserving prompt order', () async {
      final store = QueueTemplateStore(
        fileSystem: _fs,
        uri: f('queue_templates.yaml'),
      );
      await store.save([
        const QueueTemplate(
          id: 'q1',
          name: 'Daily',
          prompts: ['first', 'second', 'third'],
        ),
      ]);

      final loaded = (await store.load());
      expect(loaded.single.name, 'Daily');
      expect(loaded.single.prompts, ['first', 'second', 'third']);
    });

    test('returns an empty list for a missing file', () async {
      expect(
        (await QueueTemplateStore(
          fileSystem: _fs,
          uri: f('missing.yaml'),
        ).load()),
        isEmpty,
      );
    });
  });

  group('ReminderTemplateStore', () {
    test(
      'round-trips reminder templates preserving the default flag',
      () async {
        final store = ReminderTemplateStore(
          fileSystem: _fs,
          uri: f('reminder_templates.yaml'),
        );
        await store.save([
          const ReminderTemplate(
            id: 'r1',
            name: 'Gentle',
            prompt: 'Still there? {{waitingMinutes}} minutes so far.',
          ),
          const ReminderTemplate(
            id: 'r2',
            name: 'Fallback',
            prompt: 'Any update?',
            isDefault: true,
          ),
        ]);

        final loaded = (await store.load());
        expect(loaded.map((r) => r.id), ['r1', 'r2']);
        expect(loaded.first.prompt, contains('{{waitingMinutes}}'));
        expect(loaded.first.isDefault, isFalse);
        expect(loaded.last.isDefault, isTrue);
      },
    );

    test('returns an empty list for a missing file', () async {
      expect(
        (await ReminderTemplateStore(
          fileSystem: _fs,
          uri: f('missing.yaml'),
        ).load()),
        isEmpty,
      );
    });

    test(
      'resolves an id a persisted queue item or timed request names',
      () async {
        // The reason this store exists. Both models hold a
        // `reminderTemplateId`, and both are themselves persisted, so a queue
        // restored on the next launch has to be able to find the body it names.
        // Without a store the id resolved to nothing and the reference was one
        // in name only.
        final store = ReminderTemplateStore(
          fileSystem: _fs,
          uri: f('reminder_templates.yaml'),
        );
        await store.save([
          const ReminderTemplate(
            id: 'r1',
            name: 'Gentle',
            prompt: 'Still there?',
          ),
        ]);

        const queued = QueuedPrompt(
          id: 'p1',
          originalText: 'go',
          expandedText: 'go',
          createdAt: '2026-01-02T03:04:05.000Z',
          reminderTemplateId: 'r1',
        );
        const timed = TimedRequest(
          id: 't1',
          originalText: 'nudge',
          scheduleMode: ScheduleMode.interval,
          reminderTemplateId: 'r1',
        );

        final byId = {for (final r in (await store.load())) r.id: r};
        expect(byId[queued.reminderTemplateId]?.name, 'Gentle');
        expect(byId[timed.reminderTemplateId]?.name, 'Gentle');
      },
    );
  });

  group('TimedRequestStore', () {
    test('round-trips timed requests preserving schedule fields', () async {
      final store = TimedRequestStore(fileSystem: _fs, uri: f('timed.yaml'));
      await store.save([
        const TimedRequest(
          id: 'r1',
          originalText: 'check builds',
          scheduleMode: ScheduleMode.interval,
          intervalMinutes: 30,
        ),
        const TimedRequest(
          id: 'r2',
          originalText: 'morning report',
          scheduleMode: ScheduleMode.scheduled,
          scheduledTimes: [ScheduledTime(time: '09:00')],
          enabled: false,
        ),
      ]);

      final loaded = (await store.load());
      expect(loaded.map((r) => r.id), ['r1', 'r2']);
      expect(loaded[0].intervalMinutes, 30);
      expect(loaded[1].scheduleMode, ScheduleMode.scheduled);
      expect(loaded[1].scheduledTimes?.single.time, '09:00');
      expect(loaded[1].enabled, isFalse);
    });

    test('returns an empty list for a missing file', () async {
      expect(
        (await TimedRequestStore(
          fileSystem: _fs,
          uri: f('missing.yaml'),
        ).load()),
        isEmpty,
      );
    });
  });

  group('AgentSettingsStore', () {
    test('round-trips the singleton settings', () async {
      final store = AgentSettingsStore(
        fileSystem: _fs,
        uri: f('agent_settings.yaml'),
      );
      await store.save(
        const AgentSettings(
          bridgeHost: '127.0.0.1',
          portScanStart: 19900,
          portScanEnd: 19905,
          defaultProfileId: 'p1',
          maxTokens: 8192,
          thinkingEnabled: true,
          toolApprovalMode: ToolApprovalMode.never,
        ),
      );

      final loaded = (await store.load());
      expect(loaded.bridgeHost, '127.0.0.1');
      expect(loaded.portScanEnd, 19905);
      expect(loaded.defaultProfileId, 'p1');
      expect(loaded.maxTokens, 8192);
      expect(loaded.thinkingEnabled, isTrue);
      expect(loaded.toolApprovalMode, ToolApprovalMode.never);
    });

    test('returns the defaults for a missing file', () async {
      // The host default is the shared `defaultBridgeHost`, not a second
      // spelling of it: this settings object is scanned against a binding
      // that defaults from the same constant, and the two used to disagree.
      final loaded = (await AgentSettingsStore(
        fileSystem: _fs,
        uri: f('missing.yaml'),
      ).load());
      expect(loaded.bridgeHost, defaultBridgeHost);
      expect(loaded.bridgeHost, '127.0.0.1');
      expect(loaded.portScanStart, 19900);
      expect(loaded.portScanEnd, 19909);
      expect(loaded.hasValidPortRange, isTrue);
    });

    test('hasValidPortRange rejects an inverted range', () async {
      const settings = AgentSettings(portScanStart: 19909, portScanEnd: 19900);
      expect(settings.hasValidPortRange, isFalse);
    });
  });
}

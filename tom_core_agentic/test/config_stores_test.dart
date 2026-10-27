// Round-trip tests for the config-editor YAML stores: agent profiles, prompt templates, queue templates, timed requests, and the
// singleton agent settings. Each store writes to a temp file and reloads to an
// equal model, and degrades to the empty/default value on a missing/malformed
// file — mirroring the existing PromptQueueStore/ChatVariableStore behaviour.

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tom_specs_config'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File f(String name) => File('${dir.path}/$name');

  group('AgentProfileStore', () {
    test('round-trips profiles preserving order and key fields', () {
      final store = AgentProfileStore(f('profiles.yaml'));
      store.save([
        const AgentProfile(
          id: 'p1',
          name: 'Builder',
          systemPrompt: 'You build.',
          maxTokens: 4096,
          interruptRetryPrefix: 'Resuming after an interruption.',
        ),
        const AgentProfile(id: 'p2', name: 'Reviewer', isDefault: true),
      ]);

      final loaded = store.load();
      expect(loaded.map((p) => p.id), ['p1', 'p2']);
      expect(loaded[0].maxTokens, 4096);
      expect(loaded[0].interruptRetryPrefix, 'Resuming after an interruption.');
      expect(loaded[1].isDefault, isTrue);
    });

    test('returns an empty list for a missing file', () {
      expect(AgentProfileStore(f('missing.yaml')).load(), isEmpty);
    });

    test('returns an empty list for a malformed file', () {
      final file = f('bad.yaml')..writeAsStringSync(': not a mapping :');
      expect(AgentProfileStore(file).load(), isEmpty);
    });
  });

  group('PromptTemplateStore', () {
    test('round-trips prompt templates including the user-message flag', () {
      final store = PromptTemplateStore(f('prompts.yaml'));
      store.save([
        const PromptTemplate(
          id: 't1',
          name: 'Greeting',
          body: 'Hello \${name}',
          isUserMessage: true,
        ),
        const PromptTemplate(id: 't2', name: 'Empty'),
      ]);

      final loaded = store.load();
      expect(loaded.map((t) => t.id), ['t1', 't2']);
      expect(loaded[0].body, 'Hello \${name}');
      expect(loaded[0].isUserMessage, isTrue);
      expect(loaded[1].isUserMessage, isFalse);
    });

    test('returns an empty list for a missing file', () {
      expect(PromptTemplateStore(f('missing.yaml')).load(), isEmpty);
    });
  });

  group('QueueTemplateStore', () {
    test('round-trips queue templates preserving prompt order', () {
      final store = QueueTemplateStore(f('queue_templates.yaml'));
      store.save([
        const QueueTemplate(
          id: 'q1',
          name: 'Daily',
          prompts: ['first', 'second', 'third'],
        ),
      ]);

      final loaded = store.load();
      expect(loaded.single.name, 'Daily');
      expect(loaded.single.prompts, ['first', 'second', 'third']);
    });

    test('returns an empty list for a missing file', () {
      expect(QueueTemplateStore(f('missing.yaml')).load(), isEmpty);
    });
  });

  group('ReminderTemplateStore', () {
    test('round-trips reminder templates preserving the default flag', () {
      final store = ReminderTemplateStore(f('reminder_templates.yaml'));
      store.save([
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

      final loaded = store.load();
      expect(loaded.map((r) => r.id), ['r1', 'r2']);
      expect(loaded.first.prompt, contains('{{waitingMinutes}}'));
      expect(loaded.first.isDefault, isFalse);
      expect(loaded.last.isDefault, isTrue);
    });

    test('returns an empty list for a missing file', () {
      expect(ReminderTemplateStore(f('missing.yaml')).load(), isEmpty);
    });

    test('resolves an id a persisted queue item or timed request names', () {
      // The reason this store exists. Both models hold a
      // `reminderTemplateId`, and both are themselves persisted, so a queue
      // restored on the next launch has to be able to find the body it names.
      // Without a store the id resolved to nothing and the reference was one
      // in name only.
      final store = ReminderTemplateStore(f('reminder_templates.yaml'))
        ..save([
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

      final byId = {for (final r in store.load()) r.id: r};
      expect(byId[queued.reminderTemplateId]?.name, 'Gentle');
      expect(byId[timed.reminderTemplateId]?.name, 'Gentle');
    });
  });

  group('TimedRequestStore', () {
    test('round-trips timed requests preserving schedule fields', () {
      final store = TimedRequestStore(f('timed.yaml'));
      store.save([
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

      final loaded = store.load();
      expect(loaded.map((r) => r.id), ['r1', 'r2']);
      expect(loaded[0].intervalMinutes, 30);
      expect(loaded[1].scheduleMode, ScheduleMode.scheduled);
      expect(loaded[1].scheduledTimes?.single.time, '09:00');
      expect(loaded[1].enabled, isFalse);
    });

    test('returns an empty list for a missing file', () {
      expect(TimedRequestStore(f('missing.yaml')).load(), isEmpty);
    });
  });

  group('AgentSettingsStore', () {
    test('round-trips the singleton settings', () {
      final store = AgentSettingsStore(f('agent_settings.yaml'));
      store.save(
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

      final loaded = store.load();
      expect(loaded.bridgeHost, '127.0.0.1');
      expect(loaded.portScanEnd, 19905);
      expect(loaded.defaultProfileId, 'p1');
      expect(loaded.maxTokens, 8192);
      expect(loaded.thinkingEnabled, isTrue);
      expect(loaded.toolApprovalMode, ToolApprovalMode.never);
    });

    test('returns the defaults for a missing file', () {
      // The host default is the shared `defaultBridgeHost`, not a second
      // spelling of it: this settings object is scanned against a binding
      // that defaults from the same constant, and the two used to disagree.
      final loaded = AgentSettingsStore(f('missing.yaml')).load();
      expect(loaded.bridgeHost, defaultBridgeHost);
      expect(loaded.bridgeHost, '127.0.0.1');
      expect(loaded.portScanStart, 19900);
      expect(loaded.portScanEnd, 19909);
      expect(loaded.hasValidPortRange, isTrue);
    });

    test('hasValidPortRange rejects an inverted range', () {
      const settings = AgentSettings(portScanStart: 19909, portScanEnd: 19900);
      expect(settings.hasValidPortRange, isFalse);
    });
  });
}

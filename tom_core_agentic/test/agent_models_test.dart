// Round-trip coverage for the editor-facing agent data models and the editor
// placeholder binder. Each model is serialised to a
// real YAML document via `encodeAgentYaml`, parsed back via
// `decodeAgentYaml`, and reconstructed through its `fromYaml` factory — so
// the assertions prove the full Map → YAML-text → Map → object path, not
// just a Map identity.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

/// Encodes [model] to YAML text and reads it straight back into a plain map,
/// proving the value survives the YAML boundary.
Map<String, dynamic> roundTrip(Map<String, dynamic> model) =>
    decodeAgentYaml(encodeAgentYaml(model));

void main() {
  group('agent YAML codec', () {
    test('encode → decode preserves nested maps, lists and scalars', () {
      final data = <String, dynamic>{
        'id': 'x',
        'count': 3,
        'flag': true,
        'cost': 0.25,
        'nested': <String, dynamic>{'a': 1},
        'items': <dynamic>[
          <String, dynamic>{'k': 'v'},
          'plain',
        ],
      };
      expect(roundTrip(data), data);
    });

    test('decode rejects a non-mapping root', () {
      expect(
        () => decodeAgentYaml('- just\n- a\n- list'),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode coerces a multi-line block scalar back verbatim', () {
      const model = <String, dynamic>{'body': 'line one\nline two\n'};
      expect(roundTrip(model), model);
    });
  });

  group('ReminderTemplate', () {
    test('round-trips through YAML', () {
      const template = ReminderTemplate(
        id: 'default',
        name: 'Default nudge',
        prompt: 'Still there after {{timeoutMinutes}} minutes?',
        isDefault: true,
      );
      final restored = ReminderTemplate.fromYaml(roundTrip(template.toYaml()));
      expect(restored.toYaml(), template.toYaml());
      expect(restored.id, 'default');
      expect(restored.isDefault, isTrue);
    });
  });

  group('TimedRequest', () {
    test('interval mode round-trips', () {
      const request = TimedRequest(
        id: 't1',
        originalText: 'Run the nightly summary',
        scheduleMode: ScheduleMode.interval,
        intervalMinutes: 60,
        reminderEnabled: true,
        reminderTimeoutMinutes: 5,
        status: TimedRequestStatus.active,
      );
      final restored = TimedRequest.fromYaml(roundTrip(request.toYaml()));
      expect(restored.toYaml(), request.toYaml());
      expect(restored.scheduleMode, ScheduleMode.interval);
      expect(restored.intervalMinutes, 60);
    });

    test('scheduled mode with one-shot times round-trips', () {
      const request = TimedRequest(
        id: 't2',
        originalText: 'Daily and one-shot',
        scheduleMode: ScheduleMode.scheduled,
        scheduledTimes: <ScheduledTime>[
          ScheduledTime(time: '09:00'),
          ScheduledTime(time: '17:30', date: '2026-06-20'),
        ],
        status: TimedRequestStatus.paused,
      );
      final restored = TimedRequest.fromYaml(roundTrip(request.toYaml()));
      expect(restored.toYaml(), request.toYaml());
      expect(restored.scheduledTimes, hasLength(2));
      expect(restored.scheduledTimes![1].date, '2026-06-20');
      expect(restored.status, TimedRequestStatus.paused);
    });

    test('a file with no scheduleMode key still reads as interval', () {
      // The constructor parameter is required, the persisted key is not.
      // A hand-edit that drops the line should cost a re-pick of the mode,
      // not the entry — so this asymmetry is the point, not an oversight.
      final restored = TimedRequest.fromYaml(<String, dynamic>{
        'id': 't3',
        'originalText': 'no mode on disk',
      });
      expect(restored.scheduleMode, ScheduleMode.interval);
      expect(restored.intervalMinutes, isNull);
    });

    test('an unknown scheduleMode token reads as interval', () {
      final restored = TimedRequest.fromYaml(<String, dynamic>{
        'id': 't4',
        'originalText': 'mode this build does not know',
        'scheduleMode': 'lunar',
      });
      expect(restored.scheduleMode, ScheduleMode.interval);
    });

    test('toYaml always writes scheduleMode, so a mode is never implied', () {
      const request = TimedRequest(
        id: 't5',
        originalText: 'explicit on disk',
        scheduleMode: ScheduleMode.scheduled,
      );
      expect(request.toYaml()['scheduleMode'], 'scheduled');
    });
  });

  group('prompt queue', () {
    test('a full QueuedPrompt with pre-prompts and follow-ups round-trips', () {
      const prompt = QueuedPrompt(
        id: 'q1',
        originalText: 'Do the thing',
        expandedText: 'Do the thing (expanded)',
        createdAt: '2026-06-16T10:00:00Z',
        template: 'work',
        status: QueuedPromptStatus.pending,
        type: QueuedPromptType.normal,
        reminderEnabled: true,
        reminderTimeoutMinutes: 5,
        repeatCount: 3,
        transport: QueuedTransport.anthropic,
        anthropicProfileId: 'p1',
        prePrompts: <QueuedPrePrompt>[
          QueuedPrePrompt(
            text: 'context first',
            repeatCount: 'myVar',
            transport: QueuedTransport.anthropic,
          ),
        ],
        followUps: <QueuedFollowUpPrompt>[
          QueuedFollowUpPrompt(
            id: 'f1',
            originalText: 'and then this',
            createdAt: '2026-06-16T10:01:00Z',
            answerWaitMinutes: 2,
          ),
        ],
      );
      final restored = QueuedPrompt.fromYaml(roundTrip(prompt.toYaml()));
      expect(restored.toYaml(), prompt.toYaml());
      expect(restored.status, QueuedPromptStatus.pending);
      expect(restored.type, QueuedPromptType.normal);
      expect(restored.transport, QueuedTransport.anthropic);
      // `repeatCount` mirrors the `number | string` union: int here…
      expect(restored.repeatCount, 3);
      // …and a chat-variable name on the pre-prompt.
      expect(restored.prePrompts!.single.repeatCount, 'myVar');
      expect(restored.followUps!.single.answerWaitMinutes, 2);
    });

    test('a minimal QueuedPrompt omits absent optionals from the YAML', () {
      const prompt = QueuedPrompt(
        id: 'q2',
        originalText: 'minimal',
        expandedText: 'minimal',
        createdAt: '2026-06-16T11:00:00Z',
      );
      final yaml = prompt.toYaml();
      expect(yaml.containsKey('followUps'), isFalse);
      expect(yaml.containsKey('transport'), isFalse);
      final restored = QueuedPrompt.fromYaml(roundTrip(yaml));
      expect(restored.toYaml(), yaml);
      // No transport stored → resolves to null (copilot at dispatch).
      expect(restored.transport, isNull);
    });

    test('unknown status / type values fall back to defaults', () {
      final restored = QueuedPrompt.fromYaml(<String, dynamic>{
        'id': 'q3',
        'originalText': 'x',
        'expandedText': 'x',
        'createdAt': 't',
        'status': 'bogus',
        'type': 'bogus',
      });
      expect(restored.status, QueuedPromptStatus.pending);
      expect(restored.type, QueuedPromptType.normal);
    });
  });

  group('AgentProfile', () {
    test('round-trips and always carries interruptRetryPrefix (N10)', () {
      const profile = AgentProfile(
        id: 'p1',
        name: 'Engineer',
        description: 'Senior dev persona',
        systemPrompt: 'You are an engineer.',
        enabledTools: <String>['read', 'edit'],
        thinkingEnabled: true,
        thinkingBudgetTokens: 8192,
        toolApprovalMode: ToolApprovalMode.never,
        interruptRetryPrefix: 'Resuming after a hiccup.',
      );
      final restored = AgentProfile.fromYaml(roundTrip(profile.toYaml()));
      expect(restored.toYaml(), profile.toYaml());
      expect(restored.toolApprovalMode, ToolApprovalMode.never);
      expect(restored.enabledTools, <String>['read', 'edit']);
      expect(restored.interruptRetryPrefix, 'Resuming after a hiccup.');
    });

    test('interruptRetryPrefix defaults when absent from the YAML', () {
      final restored = AgentProfile.fromYaml(<String, dynamic>{
        'id': 'p2',
        'name': 'Bare',
      });
      expect(
        restored.interruptRetryPrefix,
        AgentProfile.defaultInterruptRetryPrefix,
      );
      // The default is re-emitted, so a re-encode is stable.
      expect(
        roundTrip(restored.toYaml())['interruptRetryPrefix'],
        AgentProfile.defaultInterruptRetryPrefix,
      );
    });
  });

  group('ChatVariable', () {
    test('round-trips through YAML', () {
      const variable = ChatVariable(
        name: 'project',
        value: 'TomSpecs',
        description: 'the active spec project',
      );
      final restored = ChatVariable.fromYaml(roundTrip(variable.toYaml()));
      expect(restored.toYaml(), variable.toYaml());
      expect(restored.name, 'project');
      expect(restored.builtIn, isFalse);
    });

    test('bindingsOf folds variables into a name → value map (last wins)', () {
      final bindings = ChatVariable.bindingsOf(const <ChatVariable>[
        ChatVariable(name: 'a', value: '1'),
        ChatVariable(name: 'b', value: '2'),
        ChatVariable(name: 'a', value: '3'),
      ]);
      expect(bindings, <String, String>{'a': '3', 'b': '2'});
    });
  });

  group('PromptTemplate', () {
    test('round-trips through YAML', () {
      const template = PromptTemplate(
        id: 'pt1',
        name: 'Bug report',
        body: r'Investigate ${file-bug.md} for project ${project}.',
        isUserMessage: true,
      );
      final restored = PromptTemplate.fromYaml(roundTrip(template.toYaml()));
      expect(restored.toYaml(), template.toYaml());
      expect(restored.isUserMessage, isTrue);
    });
  });

  group('QueueTemplate', () {
    test('round-trips an ordered prompt set through YAML', () {
      const template = QueueTemplate(
        id: 'qt1',
        name: 'Nightly',
        prompts: <String>['summarise the day', 'plan tomorrow'],
      );
      final restored = QueueTemplate.fromYaml(roundTrip(template.toYaml()));
      expect(restored.toYaml(), template.toYaml());
      expect(restored.prompts, <String>['summarise the day', 'plan tomorrow']);
    });

    test('a missing prompts key decodes to an empty list', () {
      final restored = QueueTemplate.fromYaml(<String, dynamic>{
        'id': 'qt2',
        'name': 'Empty',
      });
      expect(restored.prompts, isEmpty);
    });
  });

  group('chat / trail', () {
    test('a ChatMessage round-trips', () {
      const message = ChatMessage(
        id: 'm1',
        role: ChatRole.assistant,
        text: 'Hello.',
        createdAt: '2026-06-16T12:00:00Z',
      );
      final restored = ChatMessage.fromYaml(roundTrip(message.toYaml()));
      expect(restored.toYaml(), message.toYaml());
      expect(restored.role, ChatRole.assistant);
    });

    test('a TrailPair with provenance round-trips', () {
      const pair = TrailPair(
        id: 'r1',
        createdAt: '2026-06-16T12:00:00Z',
        request: ChatMessage(
          id: 'm-req',
          role: ChatRole.user,
          text: 'What is the capital of France?',
          createdAt: '2026-06-16T12:00:00Z',
        ),
        answer: ChatMessage(
          id: 'm-ans',
          role: ChatRole.assistant,
          text: 'Paris.',
          createdAt: '2026-06-16T12:00:02Z',
        ),
        summaryMarkdown: '**Q:** capital of France → **A:** Paris',
        providerId: 'claude:sonnet:none',
        modelId: 'claude-sonnet-4-6',
        tokensIn: 88,
        tokensOut: 40,
        costUsd: 0.0021,
      );
      final restored = TrailPair.fromYaml(roundTrip(pair.toYaml()));
      expect(restored.toYaml(), pair.toYaml());
      expect(restored.answer!.text, 'Paris.');
      expect(restored.tokensOut, 40);
      expect(restored.costUsd, 0.0021);
    });

    test('a still-streaming TrailPair omits the answer', () {
      const pair = TrailPair(
        id: 'r2',
        createdAt: '2026-06-16T12:00:00Z',
        request: ChatMessage(
          id: 'm-req',
          role: ChatRole.user,
          text: 'pending…',
          createdAt: '2026-06-16T12:00:00Z',
        ),
      );
      final yaml = pair.toYaml();
      expect(yaml.containsKey('answer'), isFalse);
      final restored = TrailPair.fromYaml(roundTrip(yaml));
      expect(restored.answer, isNull);
    });
  });

  group('EditorPlaceholderBindings', () {
    test('resolves \${name} and the {{name}} alias from bindings', () {
      final binder = EditorPlaceholderBindings(
        bindings: <String, String>{'project': 'TomSpecs', 'who': 'Alex'},
      );
      expect(binder.resolve(r'${project} by {{who}}'), 'TomSpecs by Alex');
    });

    test('an unbound \${name?} optional vanishes; \${name} renders empty '
        'in lenient mode', () {
      final binder = EditorPlaceholderBindings();
      expect(binder.resolve(r'a${missing?}b'), 'ab');
      expect(binder.resolve(r'a${missing}b'), 'ab');
    });

    test('strict mode throws on an unbound name', () {
      final binder = EditorPlaceholderBindings(strict: true);
      expect(() => binder.resolve(r'${missing}'), throwsA(isA<Object>()));
    });

    test('resolves \${env:NAME} from an injected environment', () {
      final binder = EditorPlaceholderBindings(
        environment: <String, String>{'WORKSPACE': 'al_the_bear'},
      );
      expect(binder.resolve(r'${env:WORKSPACE}'), 'al_the_bear');
    });

    test('the \${{ … }} expression form is rejected, not executed', () {
      final binder = EditorPlaceholderBindings();
      expect(
        () => binder.resolve(r'${{ 1 + 1 }}'),
        throwsA(isA<PlaceholderExpressionsUnsupportedError>()),
      );
    });

    test('rejection happens before the alias pass, so a real {{name}} after '
        'an expression is never reached', () {
      final binder = EditorPlaceholderBindings(
        bindings: <String, String>{'x': 'y'},
      );
      expect(
        () => binder.resolve(r'${{ foo }} and {{x}}'),
        throwsA(isA<PlaceholderExpressionsUnsupportedError>()),
      );
    });

    test('reserved file and state forms pass through verbatim: the binder '
        'does no I/O', () {
      final binder = EditorPlaceholderBindings(
        bindings: <String, String>{'file:a.md': 'bound', 'x': 'y'},
        strict: true,
      );
      expect(
        binder.resolve(r'${file:a.md} ${state:k} {{x}}'),
        r'${file:a.md} ${state:k} y',
      );
    });
  });
}

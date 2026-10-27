// Prompt-queue models — `QueuedPrompt`, `QueuedPrePrompt`,
// `QueuedFollowUpPrompt`.
//
// Ported from the VS Code extension's prompt-queue manager
// (`tom_vscode_extension/src/managers/promptQueueManager.ts`) for the
// TomSpecs editor's queue and its Prompt Queue editor. Persisted
// as YAML in the spec workspace (`*.entry.queue.yaml`).
//
// `repeatCount` mirrors the extension's `number | string` union (a literal
// count or a chat-variable name resolved at dispatch time); it is kept as
// an `Object?` here and round-trips as a YAML scalar.
library;

import 'agent_yaml.dart';

/// Lifecycle of a queued prompt.
enum QueuedPromptStatus {
  staged('staged'),
  pending('pending'),
  sending('sending'),
  sent('sent'),
  error('error');

  const QueuedPromptStatus(this.value);

  final String value;

  static QueuedPromptStatus fromValue(String? value) =>
      QueuedPromptStatus.values.firstWhere(
        (s) => s.value == value,
        orElse: () => QueuedPromptStatus.pending,
      );
}

/// What kind of queued prompt this is.
enum QueuedPromptType {
  normal('normal'),
  timed('timed'),
  reminder('reminder');

  const QueuedPromptType(this.value);

  final String value;

  static QueuedPromptType fromValue(String? value) =>
      QueuedPromptType.values.firstWhere(
        (t) => t.value == value,
        orElse: () => QueuedPromptType.normal,
      );
}

/// Which backend a queued prompt dispatches through. Items without an
/// explicit transport resolve to [QueuedTransport.copilot] at dispatch.
enum QueuedTransport {
  copilot('copilot'),
  anthropic('anthropic');

  const QueuedTransport(this.value);

  final String value;

  static QueuedTransport? fromValue(String? value) {
    if (value == null) return null;
    for (final t in QueuedTransport.values) {
      if (t.value == value) return t;
    }
    return null;
  }
}

/// A follow-up prompt sent after a queue item's main prompt is answered.
final class QueuedFollowUpPrompt {
  const QueuedFollowUpPrompt({
    required this.id,
    required this.originalText,
    required this.createdAt,
    this.template,
    this.reminderTemplateId,
    this.reminderTimeoutMinutes,
    this.reminderRepeat,
    this.reminderEnabled,
    this.repeatCount,
    this.resolvedRepeatCount,
    this.repeatIndex,
    this.answerWaitMinutes,
    this.transport,
    this.anthropicProfileId,
    this.anthropicConfigId,
    this.answerText,
  });

  final String id;
  final String originalText;
  final String createdAt;
  final String? template;
  final String? reminderTemplateId;
  final int? reminderTimeoutMinutes;
  final bool? reminderRepeat;
  final bool? reminderEnabled;

  /// Literal count or chat-variable name (`number | string` in the source).
  final Object? repeatCount;
  final int? resolvedRepeatCount;
  final int? repeatIndex;
  final int? answerWaitMinutes;
  final QueuedTransport? transport;
  final String? anthropicProfileId;
  final String? anthropicConfigId;
  final String? answerText;

  factory QueuedFollowUpPrompt.fromYaml(Map<String, dynamic> yaml) =>
      QueuedFollowUpPrompt(
        id: yaml['id'] as String,
        originalText: yamlValue<String>(yaml, 'originalText') ?? '',
        createdAt: yamlValue<String>(yaml, 'createdAt') ?? '',
        template: yamlValue<String>(yaml, 'template'),
        reminderTemplateId: yamlValue<String>(yaml, 'reminderTemplateId'),
        reminderTimeoutMinutes: yamlValue<int>(yaml, 'reminderTimeoutMinutes'),
        reminderRepeat: yamlValue<bool>(yaml, 'reminderRepeat'),
        reminderEnabled: yamlValue<bool>(yaml, 'reminderEnabled'),
        repeatCount: yaml['repeatCount'],
        resolvedRepeatCount: yamlValue<int>(yaml, 'resolvedRepeatCount'),
        repeatIndex: yamlValue<int>(yaml, 'repeatIndex'),
        answerWaitMinutes: yamlValue<int>(yaml, 'answerWaitMinutes'),
        transport: QueuedTransport.fromValue(
          yamlValue<String>(yaml, 'transport'),
        ),
        anthropicProfileId: yamlValue<String>(yaml, 'anthropicProfileId'),
        anthropicConfigId: yamlValue<String>(yaml, 'anthropicConfigId'),
        answerText: yamlValue<String>(yaml, 'answerText'),
      );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'originalText': originalText,
    'createdAt': createdAt,
    if (template != null) 'template': template,
    if (reminderTemplateId != null) 'reminderTemplateId': reminderTemplateId,
    if (reminderTimeoutMinutes != null)
      'reminderTimeoutMinutes': reminderTimeoutMinutes,
    if (reminderRepeat != null) 'reminderRepeat': reminderRepeat,
    if (reminderEnabled != null) 'reminderEnabled': reminderEnabled,
    if (repeatCount != null) 'repeatCount': repeatCount,
    if (resolvedRepeatCount != null) 'resolvedRepeatCount': resolvedRepeatCount,
    if (repeatIndex != null) 'repeatIndex': repeatIndex,
    if (answerWaitMinutes != null) 'answerWaitMinutes': answerWaitMinutes,
    if (transport != null) 'transport': transport!.value,
    if (anthropicProfileId != null) 'anthropicProfileId': anthropicProfileId,
    if (anthropicConfigId != null) 'anthropicConfigId': anthropicConfigId,
    if (answerText != null) 'answerText': answerText,
  };
}

/// A pre-prompt sent ahead of a queue item's main prompt.
final class QueuedPrePrompt {
  const QueuedPrePrompt({
    required this.text,
    this.status = QueuedPrePromptStatus.pending,
    this.template,
    this.repeatCount,
    this.resolvedRepeatCount,
    this.repeatIndex,
    this.answerWaitMinutes,
    this.reminderTemplateId,
    this.reminderTimeoutMinutes,
    this.reminderRepeat,
    this.reminderEnabled,
    this.transport,
    this.anthropicProfileId,
    this.anthropicConfigId,
    this.answerText,
  });

  final String text;
  final QueuedPrePromptStatus status;
  final String? template;
  final Object? repeatCount;
  final int? resolvedRepeatCount;
  final int? repeatIndex;
  final int? answerWaitMinutes;
  final String? reminderTemplateId;
  final int? reminderTimeoutMinutes;
  final bool? reminderRepeat;
  final bool? reminderEnabled;
  final QueuedTransport? transport;
  final String? anthropicProfileId;
  final String? anthropicConfigId;
  final String? answerText;

  factory QueuedPrePrompt.fromYaml(
    Map<String, dynamic> yaml,
  ) => QueuedPrePrompt(
    text: yamlValue<String>(yaml, 'text') ?? '',
    status: QueuedPrePromptStatus.fromValue(yamlValue<String>(yaml, 'status')),
    template: yamlValue<String>(yaml, 'template'),
    repeatCount: yaml['repeatCount'],
    resolvedRepeatCount: yamlValue<int>(yaml, 'resolvedRepeatCount'),
    repeatIndex: yamlValue<int>(yaml, 'repeatIndex'),
    answerWaitMinutes: yamlValue<int>(yaml, 'answerWaitMinutes'),
    reminderTemplateId: yamlValue<String>(yaml, 'reminderTemplateId'),
    reminderTimeoutMinutes: yamlValue<int>(yaml, 'reminderTimeoutMinutes'),
    reminderRepeat: yamlValue<bool>(yaml, 'reminderRepeat'),
    reminderEnabled: yamlValue<bool>(yaml, 'reminderEnabled'),
    transport: QueuedTransport.fromValue(yamlValue<String>(yaml, 'transport')),
    anthropicProfileId: yamlValue<String>(yaml, 'anthropicProfileId'),
    anthropicConfigId: yamlValue<String>(yaml, 'anthropicConfigId'),
    answerText: yamlValue<String>(yaml, 'answerText'),
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'text': text,
    'status': status.value,
    if (template != null) 'template': template,
    if (repeatCount != null) 'repeatCount': repeatCount,
    if (resolvedRepeatCount != null) 'resolvedRepeatCount': resolvedRepeatCount,
    if (repeatIndex != null) 'repeatIndex': repeatIndex,
    if (answerWaitMinutes != null) 'answerWaitMinutes': answerWaitMinutes,
    if (reminderTemplateId != null) 'reminderTemplateId': reminderTemplateId,
    if (reminderTimeoutMinutes != null)
      'reminderTimeoutMinutes': reminderTimeoutMinutes,
    if (reminderRepeat != null) 'reminderRepeat': reminderRepeat,
    if (reminderEnabled != null) 'reminderEnabled': reminderEnabled,
    if (transport != null) 'transport': transport!.value,
    if (anthropicProfileId != null) 'anthropicProfileId': anthropicProfileId,
    if (anthropicConfigId != null) 'anthropicConfigId': anthropicConfigId,
    if (answerText != null) 'answerText': answerText,
  };
}

/// Status of a pre-prompt — the source uses a narrower set than the main
/// queue item.
enum QueuedPrePromptStatus {
  pending('pending'),
  sent('sent'),
  error('error');

  const QueuedPrePromptStatus(this.value);

  final String value;

  static QueuedPrePromptStatus fromValue(String? value) =>
      QueuedPrePromptStatus.values.firstWhere(
        (s) => s.value == value,
        orElse: () => QueuedPrePromptStatus.pending,
      );
}

/// A prompt queued for dispatch, with optional pre-prompts, follow-ups,
/// reminders, repeats and multi-transport routing.
final class QueuedPrompt {
  const QueuedPrompt({
    required this.id,
    required this.originalText,
    required this.expandedText,
    required this.createdAt,
    this.template = '(None)',
    this.answerWrapper,
    this.status = QueuedPromptStatus.pending,
    this.type = QueuedPromptType.normal,
    this.sentAt,
    this.error,
    this.reminderTemplateId,
    this.reminderTimeoutMinutes,
    this.reminderRepeat,
    this.reminderEnabled,
    this.reminderQueued,
    this.reminderSentCount,
    this.lastReminderAt,
    this.requestId,
    this.expectedRequestId,
    this.prePrompts,
    this.followUps,
    this.followUpIndex,
    this.repeatCount,
    this.resolvedRepeatCount,
    this.repeatIndex,
    this.repeatPrefix,
    this.repeatSuffix,
    this.templateRepeatCount,
    this.templateRepeatIndex,
    this.answerWaitMinutes,
    this.transport,
    this.anthropicProfileId,
    this.anthropicConfigId,
    this.answerText,
  });

  final String id;
  final String template;
  final bool? answerWrapper;
  final String originalText;
  final String expandedText;
  final QueuedPromptStatus status;
  final QueuedPromptType type;
  final String createdAt;
  final String? sentAt;
  final String? error;
  final String? reminderTemplateId;
  final int? reminderTimeoutMinutes;
  final bool? reminderRepeat;
  final bool? reminderEnabled;
  final bool? reminderQueued;
  final int? reminderSentCount;
  final String? lastReminderAt;
  final String? requestId;
  final String? expectedRequestId;
  final List<QueuedPrePrompt>? prePrompts;
  final List<QueuedFollowUpPrompt>? followUps;
  final int? followUpIndex;
  final Object? repeatCount;
  final int? resolvedRepeatCount;
  final int? repeatIndex;
  final String? repeatPrefix;
  final String? repeatSuffix;
  final Object? templateRepeatCount;
  final int? templateRepeatIndex;
  final int? answerWaitMinutes;
  final QueuedTransport? transport;
  final String? anthropicProfileId;
  final String? anthropicConfigId;
  final String? answerText;

  factory QueuedPrompt.fromYaml(Map<String, dynamic> yaml) => QueuedPrompt(
    id: yaml['id'] as String,
    template: yamlValue<String>(yaml, 'template') ?? '(None)',
    answerWrapper: yamlValue<bool>(yaml, 'answerWrapper'),
    originalText: yamlValue<String>(yaml, 'originalText') ?? '',
    expandedText: yamlValue<String>(yaml, 'expandedText') ?? '',
    status: QueuedPromptStatus.fromValue(yamlValue<String>(yaml, 'status')),
    type: QueuedPromptType.fromValue(yamlValue<String>(yaml, 'type')),
    createdAt: yamlValue<String>(yaml, 'createdAt') ?? '',
    sentAt: yamlValue<String>(yaml, 'sentAt'),
    error: yamlValue<String>(yaml, 'error'),
    reminderTemplateId: yamlValue<String>(yaml, 'reminderTemplateId'),
    reminderTimeoutMinutes: yamlValue<int>(yaml, 'reminderTimeoutMinutes'),
    reminderRepeat: yamlValue<bool>(yaml, 'reminderRepeat'),
    reminderEnabled: yamlValue<bool>(yaml, 'reminderEnabled'),
    reminderQueued: yamlValue<bool>(yaml, 'reminderQueued'),
    reminderSentCount: yamlValue<int>(yaml, 'reminderSentCount'),
    lastReminderAt: yamlValue<String>(yaml, 'lastReminderAt'),
    requestId: yamlValue<String>(yaml, 'requestId'),
    expectedRequestId: yamlValue<String>(yaml, 'expectedRequestId'),
    prePrompts: decodeAgentYamlEntries(
      yaml['prePrompts'],
      QueuedPrePrompt.fromYaml,
    ),
    followUps: decodeAgentYamlEntries(
      yaml['followUps'],
      QueuedFollowUpPrompt.fromYaml,
      identity: 'id',
    ),
    followUpIndex: yamlValue<int>(yaml, 'followUpIndex'),
    repeatCount: yaml['repeatCount'],
    resolvedRepeatCount: yamlValue<int>(yaml, 'resolvedRepeatCount'),
    repeatIndex: yamlValue<int>(yaml, 'repeatIndex'),
    repeatPrefix: yamlValue<String>(yaml, 'repeatPrefix'),
    repeatSuffix: yamlValue<String>(yaml, 'repeatSuffix'),
    templateRepeatCount: yaml['templateRepeatCount'],
    templateRepeatIndex: yamlValue<int>(yaml, 'templateRepeatIndex'),
    answerWaitMinutes: yamlValue<int>(yaml, 'answerWaitMinutes'),
    transport: QueuedTransport.fromValue(yamlValue<String>(yaml, 'transport')),
    anthropicProfileId: yamlValue<String>(yaml, 'anthropicProfileId'),
    anthropicConfigId: yamlValue<String>(yaml, 'anthropicConfigId'),
    answerText: yamlValue<String>(yaml, 'answerText'),
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'template': template,
    if (answerWrapper != null) 'answerWrapper': answerWrapper,
    'originalText': originalText,
    'expandedText': expandedText,
    'status': status.value,
    'type': type.value,
    'createdAt': createdAt,
    if (sentAt != null) 'sentAt': sentAt,
    if (error != null) 'error': error,
    if (reminderTemplateId != null) 'reminderTemplateId': reminderTemplateId,
    if (reminderTimeoutMinutes != null)
      'reminderTimeoutMinutes': reminderTimeoutMinutes,
    if (reminderRepeat != null) 'reminderRepeat': reminderRepeat,
    if (reminderEnabled != null) 'reminderEnabled': reminderEnabled,
    if (reminderQueued != null) 'reminderQueued': reminderQueued,
    if (reminderSentCount != null) 'reminderSentCount': reminderSentCount,
    if (lastReminderAt != null) 'lastReminderAt': lastReminderAt,
    if (requestId != null) 'requestId': requestId,
    if (expectedRequestId != null) 'expectedRequestId': expectedRequestId,
    if (prePrompts != null)
      'prePrompts': prePrompts!.map((p) => p.toYaml()).toList(),
    if (followUps != null)
      'followUps': followUps!.map((f) => f.toYaml()).toList(),
    if (followUpIndex != null) 'followUpIndex': followUpIndex,
    if (repeatCount != null) 'repeatCount': repeatCount,
    if (resolvedRepeatCount != null) 'resolvedRepeatCount': resolvedRepeatCount,
    if (repeatIndex != null) 'repeatIndex': repeatIndex,
    if (repeatPrefix != null) 'repeatPrefix': repeatPrefix,
    if (repeatSuffix != null) 'repeatSuffix': repeatSuffix,
    if (templateRepeatCount != null) 'templateRepeatCount': templateRepeatCount,
    if (templateRepeatIndex != null) 'templateRepeatIndex': templateRepeatIndex,
    if (answerWaitMinutes != null) 'answerWaitMinutes': answerWaitMinutes,
    if (transport != null) 'transport': transport!.value,
    if (anthropicProfileId != null) 'anthropicProfileId': anthropicProfileId,
    if (anthropicConfigId != null) 'anthropicConfigId': anthropicConfigId,
    if (answerText != null) 'answerText': answerText,
  };
}

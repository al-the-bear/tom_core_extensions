// TimedRequest — a scheduled or repeating prompt.
//
// Ported from `tom_vscode_scripting_api`'s `TimedRequest` /
// `tom_vscode_extension` for the TomSpecs editor's Timed Requests editor.
// Persisted as YAML in the spec workspace (`*.timed.yaml`).
library;

import 'agent_yaml.dart';

/// Lifecycle of a timed request entry.
enum TimedRequestStatus {
  active('active'),
  paused('paused'),
  completed('completed');

  const TimedRequestStatus(this.value);

  final String value;

  static TimedRequestStatus fromValue(String? value) =>
      TimedRequestStatus.values.firstWhere(
        (s) => s.value == value,
        orElse: () => TimedRequestStatus.active,
      );
}

/// How a timed request fires: on a fixed interval or at scheduled times.
enum ScheduleMode {
  interval('interval'),
  scheduled('scheduled');

  const ScheduleMode(this.value);

  final String value;

  static ScheduleMode fromValue(String? value) => ScheduleMode.values
      .firstWhere((m) => m.value == value, orElse: () => ScheduleMode.interval);
}

/// A single scheduled slot. A bare [time] repeats daily; adding a [date]
/// makes it a one-shot.
final class ScheduledTime {
  const ScheduledTime({required this.time, this.date});

  /// Time of day in `HH:MM`.
  final String time;

  /// Optional `YYYY-MM-DD` date — one-shot when present.
  final String? date;

  factory ScheduledTime.fromYaml(Map<String, dynamic> yaml) => ScheduledTime(
    time: yamlValue<String>(yaml, 'time') ?? '00:00',
    date: yamlValue<String>(yaml, 'date'),
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'time': time,
    if (date != null) 'date': date,
  };
}

/// A timed / repeating prompt entry.
///
/// [scheduleMode] is required while the payload it selects
/// ([intervalMinutes] / [scheduledTimes]) is not, which is deliberate rather
/// than an oversight. The mode is a decision — defaulting it would hand every
/// caller that forgot it an interval request nobody chose — whereas the
/// payload is something the user fills in afterwards. This is an editor
/// working state, so "scheduled, but no times entered yet" is exactly what a
/// request looks like between picking the mode and typing the first time, and
/// the model has to be able to hold it.
final class TimedRequest {
  const TimedRequest({
    required this.id,
    required this.originalText,
    required this.scheduleMode,
    this.enabled = true,
    this.template = '(None)',
    this.answerWrapper,
    this.intervalMinutes,
    this.scheduledTimes,
    this.reminderEnabled,
    this.reminderTemplateId,
    this.reminderTimeoutMinutes,
    this.reminderRepeat,
    this.lastSentAt,
    this.status = TimedRequestStatus.active,
  });

  final String id;
  final bool enabled;
  final String template;
  final bool? answerWrapper;
  final String originalText;
  final ScheduleMode scheduleMode;
  final int? intervalMinutes;
  final List<ScheduledTime>? scheduledTimes;
  final bool? reminderEnabled;
  final String? reminderTemplateId;
  final int? reminderTimeoutMinutes;
  final bool? reminderRepeat;
  final String? lastSentAt;
  final TimedRequestStatus status;

  /// Reads a request from a persisted mapping.
  ///
  /// The `scheduleMode` *key* stays optional even though the constructor
  /// parameter is required: a file is untrusted input, and a hand-edit that
  /// drops the line should cost the user a re-pick of the mode, not the whole
  /// entry. Requiring the parameter is about the callers this package can see
  /// at compile time; coercing the key is about the ones it cannot.
  factory TimedRequest.fromYaml(Map<String, dynamic> yaml) => TimedRequest(
    id: yaml['id'] as String,
    enabled: yamlValue<bool>(yaml, 'enabled') ?? true,
    template: yamlValue<String>(yaml, 'template') ?? '(None)',
    answerWrapper: yamlValue<bool>(yaml, 'answerWrapper'),
    originalText: yamlValue<String>(yaml, 'originalText') ?? '',
    scheduleMode: ScheduleMode.fromValue(
      yamlValue<String>(yaml, 'scheduleMode'),
    ),
    intervalMinutes: yamlValue<int>(yaml, 'intervalMinutes'),
    scheduledTimes: decodeAgentYamlEntries(
      yaml['scheduledTimes'],
      ScheduledTime.fromYaml,
    ),
    reminderEnabled: yamlValue<bool>(yaml, 'reminderEnabled'),
    reminderTemplateId: yamlValue<String>(yaml, 'reminderTemplateId'),
    reminderTimeoutMinutes: yamlValue<int>(yaml, 'reminderTimeoutMinutes'),
    reminderRepeat: yamlValue<bool>(yaml, 'reminderRepeat'),
    lastSentAt: yamlValue<String>(yaml, 'lastSentAt'),
    status: TimedRequestStatus.fromValue(yamlValue<String>(yaml, 'status')),
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'enabled': enabled,
    'template': template,
    if (answerWrapper != null) 'answerWrapper': answerWrapper,
    'originalText': originalText,
    'scheduleMode': scheduleMode.value,
    if (intervalMinutes != null) 'intervalMinutes': intervalMinutes,
    if (scheduledTimes != null)
      'scheduledTimes': scheduledTimes!.map((t) => t.toYaml()).toList(),
    if (reminderEnabled != null) 'reminderEnabled': reminderEnabled,
    if (reminderTemplateId != null) 'reminderTemplateId': reminderTemplateId,
    if (reminderTimeoutMinutes != null)
      'reminderTimeoutMinutes': reminderTimeoutMinutes,
    if (reminderRepeat != null) 'reminderRepeat': reminderRepeat,
    if (lastSentAt != null) 'lastSentAt': lastSentAt,
    'status': status.value,
  };
}

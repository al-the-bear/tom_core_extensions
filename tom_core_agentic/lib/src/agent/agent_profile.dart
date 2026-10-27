// AgentProfile — the editor's persona / behaviour model.
//
// Ported from the VS Code extension's `AnthropicProfile`
// (`tom_vscode_extension/src/handlers/anthropic-handler.ts`) for the TomSpecs
// editor's Profiles editor. Persisted as YAML in the spec workspace.
//
// Beyond the VS Code field set this gains one editor-specific field:
// [interruptRetryPrefix] — the prefix prepended to an
// auto-resent interrupted prompt during the reconnect protocol.
library;

import 'agent_yaml.dart';

/// Approval gate for write tool calls.
///
/// Sent to the Agent SDK as a permission mode; see
/// `permissionModeForApproval`.
enum ToolApprovalMode {
  always('always'),
  never('never');

  const ToolApprovalMode(this.value);

  final String value;

  static ToolApprovalMode fromValue(String? value) =>
      ToolApprovalMode.values.firstWhere(
        (m) => m.value == value,
        orElse: () => ToolApprovalMode.always,
      );
}

/// A named persona that supplies the system prompt and per-send behaviour.
///
/// An Agent SDK send (`AgentSendConfig.fromProfile`) reads [systemPrompt],
/// [maxRounds] (the turn cap), [toolApprovalMode] (the permission mode) and
/// [thinkingEnabled] with [thinkingBudgetTokens] (the thinking
/// configuration), each overlaid on `AgentSettings`. The ported fields the
/// SDK's `Options` has no destination for — [maxTokens] and
/// [promptCachingEnabled] among them — are persisted and edited, and kept for
/// the providers that will take them.
final class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.name,
    this.description = '',
    this.systemPrompt = '',
    this.configurationId,
    this.toolsEnabled,
    this.enabledTools,
    this.maxRounds,
    this.historyMode,
    this.maxTokens,
    this.retryMaxTotalWaitMinutes,
    this.isDefault,
    this.thinkingEnabled,
    this.thinkingBudgetTokens,
    this.promptCachingEnabled,
    this.toolApprovalMode,
    this.useBuiltInTools,
    this.allowInteractiveQuestions,
    this.interactiveQuestionsTemplateId,
    this.autoInjectMemory,
    this.userPromptWrapper,
    this.interruptRetryPrefix = defaultInterruptRetryPrefix,
  });

  /// Default [interruptRetryPrefix] seeded when a VS Code profile is copied
  /// into the editor (N10).
  static const String defaultInterruptRetryPrefix =
      'This was interrupted due to a technical error.';

  final String id;
  final String name;
  final String description;
  final String systemPrompt;
  final String? configurationId;
  final bool? toolsEnabled;
  final List<String>? enabledTools;
  final int? maxRounds;
  final String? historyMode;
  final int? maxTokens;
  final int? retryMaxTotalWaitMinutes;
  final bool? isDefault;
  final bool? thinkingEnabled;
  final int? thinkingBudgetTokens;
  final bool? promptCachingEnabled;
  final ToolApprovalMode? toolApprovalMode;
  final bool? useBuiltInTools;
  final bool? allowInteractiveQuestions;
  final String? interactiveQuestionsTemplateId;
  final bool? autoInjectMemory;
  final String? userPromptWrapper;

  /// Editor-specific: prefix for an auto-resent interrupted prompt.
  final String interruptRetryPrefix;

  factory AgentProfile.fromYaml(Map<String, dynamic> yaml) => AgentProfile(
    id: yaml['id'] as String,
    name: yamlValue<String>(yaml, 'name') ?? '',
    description: yamlValue<String>(yaml, 'description') ?? '',
    systemPrompt: yamlValue<String>(yaml, 'systemPrompt') ?? '',
    configurationId: yamlValue<String>(yaml, 'configurationId'),
    toolsEnabled: yamlValue<bool>(yaml, 'toolsEnabled'),
    enabledTools: yamlStringList(yaml, 'enabledTools'),
    maxRounds: yamlValue<int>(yaml, 'maxRounds'),
    historyMode: yamlValue<String>(yaml, 'historyMode'),
    maxTokens: yamlValue<int>(yaml, 'maxTokens'),
    retryMaxTotalWaitMinutes: yamlValue<int>(yaml, 'retryMaxTotalWaitMinutes'),
    isDefault: yamlValue<bool>(yaml, 'isDefault'),
    thinkingEnabled: yamlValue<bool>(yaml, 'thinkingEnabled'),
    thinkingBudgetTokens: yamlValue<int>(yaml, 'thinkingBudgetTokens'),
    promptCachingEnabled: yamlValue<bool>(yaml, 'promptCachingEnabled'),
    toolApprovalMode: yamlEnum(
      yaml,
      'toolApprovalMode',
      ToolApprovalMode.fromValue,
    ),
    useBuiltInTools: yamlValue<bool>(yaml, 'useBuiltInTools'),
    allowInteractiveQuestions: yamlValue<bool>(
      yaml,
      'allowInteractiveQuestions',
    ),
    interactiveQuestionsTemplateId: yamlValue<String>(
      yaml,
      'interactiveQuestionsTemplateId',
    ),
    autoInjectMemory: yamlValue<bool>(yaml, 'autoInjectMemory'),
    userPromptWrapper: yamlValue<String>(yaml, 'userPromptWrapper'),
    interruptRetryPrefix:
        yamlValue<String>(yaml, 'interruptRetryPrefix') ??
        defaultInterruptRetryPrefix,
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'systemPrompt': systemPrompt,
    if (configurationId != null) 'configurationId': configurationId,
    if (toolsEnabled != null) 'toolsEnabled': toolsEnabled,
    if (enabledTools != null) 'enabledTools': enabledTools,
    if (maxRounds != null) 'maxRounds': maxRounds,
    if (historyMode != null) 'historyMode': historyMode,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (retryMaxTotalWaitMinutes != null)
      'retryMaxTotalWaitMinutes': retryMaxTotalWaitMinutes,
    if (isDefault != null) 'isDefault': isDefault,
    if (thinkingEnabled != null) 'thinkingEnabled': thinkingEnabled,
    if (thinkingBudgetTokens != null)
      'thinkingBudgetTokens': thinkingBudgetTokens,
    if (promptCachingEnabled != null)
      'promptCachingEnabled': promptCachingEnabled,
    if (toolApprovalMode != null) 'toolApprovalMode': toolApprovalMode!.value,
    if (useBuiltInTools != null) 'useBuiltInTools': useBuiltInTools,
    if (allowInteractiveQuestions != null)
      'allowInteractiveQuestions': allowInteractiveQuestions,
    if (interactiveQuestionsTemplateId != null)
      'interactiveQuestionsTemplateId': interactiveQuestionsTemplateId,
    if (autoInjectMemory != null) 'autoInjectMemory': autoInjectMemory,
    if (userPromptWrapper != null) 'userPromptWrapper': userPromptWrapper,
    'interruptRetryPrefix': interruptRetryPrefix,
  };
}

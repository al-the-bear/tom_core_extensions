// Chat-message & trail models.
//
// The TomSpecs editor's chat composer message stream and its prompt trail's
// request/answer pairs. The trail
// mirrors `_ai/trail/anthropic/{quest}/`: each [TrailPair] carries the
// request, the answer, a summary-markdown blob and the provenance read off
// the SDK result. Persisted as YAML in the spec workspace.
library;

import 'agent_yaml.dart';

/// Who authored a chat message.
enum ChatRole {
  user('user'),
  assistant('assistant'),
  system('system'),
  tool('tool');

  const ChatRole(this.value);

  final String value;

  static ChatRole fromValue(String? value) => ChatRole.values.firstWhere(
    (r) => r.value == value,
    orElse: () => ChatRole.user,
  );
}

/// A single message in a chat exchange.
final class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.toolName,
    this.toolCallId,
  });

  final String id;
  final ChatRole role;
  final String text;
  final String createdAt;

  /// Tool name when [role] is [ChatRole.tool].
  final String? toolName;

  /// Tool-call correlation id when [role] is [ChatRole.tool].
  final String? toolCallId;

  factory ChatMessage.fromYaml(Map<String, dynamic> yaml) => ChatMessage(
    id: yaml['id'] as String,
    role: ChatRole.fromValue(yamlValue<String>(yaml, 'role')),
    text: yamlValue<String>(yaml, 'text') ?? '',
    createdAt: yamlValue<String>(yaml, 'createdAt') ?? '',
    toolName: yamlValue<String>(yaml, 'toolName'),
    toolCallId: yamlValue<String>(yaml, 'toolCallId'),
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'role': role.value,
    'text': text,
    'createdAt': createdAt,
    if (toolName != null) 'toolName': toolName,
    if (toolCallId != null) 'toolCallId': toolCallId,
  };
}

/// One request/answer pair from an SDK exchange, as shown in the trail.
final class TrailPair {
  const TrailPair({
    required this.id,
    required this.request,
    required this.createdAt,
    this.answer,
    this.summaryMarkdown,
    this.providerId,
    this.modelId,
    this.tokensIn,
    this.tokensOut,
    this.costUsd,
  });

  final String id;
  final ChatMessage request;

  /// The answer; `null` while the exchange is still streaming.
  final ChatMessage? answer;
  final String createdAt;
  final String? summaryMarkdown;
  final String? providerId;
  final String? modelId;
  final int? tokensIn;
  final int? tokensOut;
  final double? costUsd;

  factory TrailPair.fromYaml(Map<String, dynamic> yaml) => TrailPair(
    id: yaml['id'] as String,
    request: ChatMessage.fromYaml(
      (yaml['request'] as Map).cast<String, dynamic>(),
    ),
    answer: yaml['answer'] is Map
        ? ChatMessage.fromYaml((yaml['answer'] as Map).cast<String, dynamic>())
        : null,
    createdAt: yamlValue<String>(yaml, 'createdAt') ?? '',
    summaryMarkdown: yamlValue<String>(yaml, 'summaryMarkdown'),
    providerId: yamlValue<String>(yaml, 'providerId'),
    modelId: yamlValue<String>(yaml, 'modelId'),
    tokensIn: yamlValue<int>(yaml, 'tokensIn'),
    tokensOut: yamlValue<int>(yaml, 'tokensOut'),
    costUsd: yamlValue<num>(yaml, 'costUsd')?.toDouble(),
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'id': id,
    'request': request.toYaml(),
    if (answer != null) 'answer': answer!.toYaml(),
    'createdAt': createdAt,
    if (summaryMarkdown != null) 'summaryMarkdown': summaryMarkdown,
    if (providerId != null) 'providerId': providerId,
    if (modelId != null) 'modelId': modelId,
    if (tokensIn != null) 'tokensIn': tokensIn,
    if (tokensOut != null) 'tokensOut': tokensOut,
    if (costUsd != null) 'costUsd': costUsd,
  };
}

/// Every Agent SDK message a run receives, as trail events.
///
/// Pure and stateful per run: the channel feeds it each `SDKMessage` in order
/// and forwards what it returns. A separate class rather than a body inside
/// the channel's listener, so a recorded message sequence can be replayed
/// through exactly the code a live run uses, with no socket.
///
/// **Text and thinking arrive twice, and are emitted once.** The query asks
/// for partial messages (`includePartialMessages`), so a turn's text and
/// thinking stream as `stream_event` deltas and then arrive again, assembled,
/// in the turn's `assistant` message. The deltas are what make the trail live,
/// so they are emitted; the assembled message's text and thinking are emitted
/// only for a turn whose deltas never came. Tool calls are taken from the
/// assembled message, where their input is complete JSON rather than
/// fragments.
library;

import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_llm/tom_llm.dart';

import 'transport.dart';

/// One run's translation from Agent SDK messages to events.
final class SdkTrailTranslator {
  /// The ids of the assistant messages whose text or thinking streamed as
  /// deltas — their assembled copies add no text.
  final Set<String> _streamed = {};

  /// The assistant message the current `stream_event`s belong to.
  String? _current;

  /// Whether any text has been emitted, and whether a tool call happened
  /// since — together they decide whether the next turn's text starts a new
  /// paragraph, so the turns of a run do not run together in the answer.
  bool _emittedText = false;
  bool _toolCallSinceText = false;

  /// Whether the current message has emitted text yet.
  bool _textInCurrent = false;

  int _toolCalls = 0;

  /// The run's account, so the completed run it ends carries its report.
  final LlmRunAccount _account;

  /// The prefix the SDK gives a tool declared on the run's in-process MCP
  /// server (`mcp__<server>__<tool>`); the trail names the tool without it.
  final String? _toolPrefix;

  /// A translator for one run of the transport [providerId], whose tools, if
  /// any, are declared on the in-process MCP server [toolServerName].
  SdkTrailTranslator({String providerId = '', String? toolServerName})
    : _account = LlmRunAccount(providerId: providerId),
      _toolPrefix = toolServerName == null ? null : 'mcp__${toolServerName}__';

  /// The tool calls the model has made in this run so far.
  int get toolCalls => _toolCalls;

  /// The events [message] means, in order.
  List<AgentSdkCompletionEvent> translate(SdkMessage message) {
    final events = _translate(message);
    for (final event in events) {
      if (event is AgentSdkTrailed) _account.observe(event.event);
    }
    return events;
  }

  List<AgentSdkCompletionEvent> _translate(SdkMessage message) =>
      switch (message) {
        SdkSystemMessage() when (message.subtype ?? 'init') == 'init' => [
          AgentSdkTrailed(
            LlmSystemInit(
              model: message.model,
              tools: [for (final t in message.tools) _toolName(t)],
            ),
          ),
        ],
        SdkSystemMessage() => [
          AgentSdkLiveness(
            'system/${message.subtype}',
            unmappedType: 'system/${message.subtype}',
          ),
        ],
        SdkSystemEvent(subtype: 'api_retry') => [
          AgentSdkTrailed(_retry(message.raw)),
        ],
        SdkSystemEvent() => [
          AgentSdkLiveness(
            'system/${message.subtype ?? 'event'}',
            unmappedType: 'system/${message.subtype ?? 'event'}',
          ),
        ],
        SdkPartialAssistantMessage() => _partial(message.event ?? const {}),
        SdkAssistantMessage() => _assistant(message),
        SdkUserMessage() => _user(message),
        SdkResultMessage(isError: false) => _completed(message),
        // A failed result's accounting is still the run's; the failure
        // itself is the channel's to raise, as the transport's one error type.
        SdkResultMessage() => [AgentSdkTrailed(_usage(message))],
        SdkUnknownMessage() => [
          AgentSdkLiveness(message.type, unmappedType: message.type),
        ],
      };

  List<AgentSdkCompletionEvent> _partial(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'message_start':
        final id = (event['message'] as Map?)?['id'] as String?;
        _current = id;
        _textInCurrent = false;
        return const [AgentSdkLiveness('stream_event')];
      case 'content_block_delta':
        final delta = (event['delta'] as Map?)?.cast<String, dynamic>() ?? {};
        switch (delta['type']) {
          case 'thinking_delta':
            final text = delta['thinking'] as String? ?? '';
            if (text.isEmpty) break;
            _markStreamed();
            return [AgentSdkTrailed(LlmThinkingDelta(text))];
          case 'text_delta':
            final text = delta['text'] as String? ?? '';
            if (text.isEmpty) break;
            _markStreamed();
            return [AgentSdkTrailed(LlmTextDelta(_textPiece(text)))];
        }
        return const [AgentSdkLiveness('stream_event')];
      default:
        return const [AgentSdkLiveness('stream_event')];
    }
  }

  void _markStreamed() {
    final id = _current;
    if (id != null) _streamed.add(id);
  }

  /// [text], led by a blank line when it is the first text of a turn that
  /// follows a tool call.
  String _textPiece(String text) {
    final separate = !_textInCurrent && _emittedText && _toolCallSinceText;
    _emittedText = true;
    _textInCurrent = true;
    _toolCallSinceText = false;
    return separate ? '\n\n$text' : text;
  }

  List<AgentSdkCompletionEvent> _assistant(SdkAssistantMessage message) {
    // A message the SDK writes to report a failure (`error` set — an
    // invalid key reads "Invalid API key · …") is not the model speaking:
    // its text is no part of the answer. The failure arrives as the run's
    // error result, which the channel raises.
    if (message.error != null) {
      return [AgentSdkLiveness('assistant/${message.error}')];
    }
    final id = message.message?['id'] as String?;
    final streamed = id != null && _streamed.contains(id);
    if (!streamed) _textInCurrent = false;
    final events = <AgentSdkCompletionEvent>[];
    for (final block in message.content) {
      switch (block) {
        case ThinkingBlock(:final thinking)
            when !streamed && thinking.isNotEmpty:
          events.add(AgentSdkTrailed(LlmThinkingDelta(thinking)));
        case TextBlock(:final text) when !streamed && text.isNotEmpty:
          events.add(AgentSdkTrailed(LlmTextDelta(_textPiece(text))));
        case ToolUseBlock():
          _toolCalls++;
          _toolCallSinceText = true;
          events.add(
            AgentSdkTrailed(
              LlmToolCall(
                callId: block.id,
                name: _toolName(block.name),
                arguments: block.input.cast<String, Object?>(),
              ),
            ),
          );
        case ThinkingBlock() ||
            TextBlock() ||
            ToolResultBlock() ||
            UnknownBlock():
          break;
      }
    }
    // A turn whose content was all streamed, or held nothing the trail
    // records, is still life.
    return events.isEmpty ? const [AgentSdkLiveness('assistant')] : events;
  }

  List<AgentSdkCompletionEvent> _user(SdkUserMessage message) {
    if (message.isReplay) return const [AgentSdkLiveness('user')];
    final events = <AgentSdkCompletionEvent>[
      for (final block in message.content)
        if (block is ToolResultBlock) AgentSdkTrailed(_toolResult(block)),
    ];
    return events.isEmpty ? const [AgentSdkLiveness('user')] : events;
  }

  static LlmToolResult _toolResult(ToolResultBlock block) {
    final text = switch (block.content) {
      final String text => text,
      final List<Object?> parts => [
        for (final part in parts)
          if (part is Map && part['type'] == 'text')
            part['text'] as String? ?? ''
          else if (part is Map)
            '[${part['type']}]',
      ].join('\n'),
      _ => '',
    };
    return LlmToolResult(
      callId: block.toolUseId,
      isError: block.isError,
      text: text,
      fullLength: text.length,
    );
  }

  static LlmRetry _retry(Map<String, dynamic> raw) {
    final status = raw['error_status'];
    final error = raw['error'];
    final cause = [
      if (status != null) 'HTTP $status',
      if (error != null) '$error',
    ].join(': ');
    final delay = (raw['retry_delay_ms'] as num?)?.toInt();
    return LlmRetry(
      attempt: (raw['attempt'] as num?)?.toInt(),
      delay: delay == null ? null : Duration(milliseconds: delay),
      cause: cause.isEmpty ? null : cause,
    );
  }

  /// The successful result: its usage, then the run's end, accounted.
  List<AgentSdkCompletionEvent> _completed(SdkResultMessage message) {
    final usage = _usage(message);
    _account.observe(usage);
    return [
      AgentSdkTrailed(usage),
      AgentSdkTrailed(
        _account.end(
          LlmRunOutcome.completed,
          rounds: message.numTurns,
          duration: Duration(milliseconds: message.durationMs ?? 0),
        ),
      ),
    ];
  }

  static LlmUsage _usage(SdkResultMessage message) {
    final usage = message.usage ?? const {};
    int? count(Map<String, dynamic> map, String key) =>
        (map[key] as num?)?.toInt();
    final models = (message.raw['modelUsage'] as Map?)?.cast<String, dynamic>();
    final apiMs = message.durationApiMs;
    return LlmUsage(
      inputTokens: count(usage, 'input_tokens'),
      outputTokens: count(usage, 'output_tokens'),
      cacheReadTokens: count(usage, 'cache_read_input_tokens'),
      cacheWriteTokens: count(usage, 'cache_creation_input_tokens'),
      costUsd: message.totalCostUsd,
      apiDuration: apiMs == null ? null : Duration(milliseconds: apiMs),
      models: [
        if (models != null)
          for (final entry in models.entries)
            if (entry.value is Map)
              LlmModelUsage(
                model: entry.key,
                inputTokens: count(
                  entry.value as Map<String, dynamic>,
                  'inputTokens',
                ),
                outputTokens: count(
                  entry.value as Map<String, dynamic>,
                  'outputTokens',
                ),
                cacheReadTokens: count(
                  entry.value as Map<String, dynamic>,
                  'cacheReadInputTokens',
                ),
                cacheWriteTokens: count(
                  entry.value as Map<String, dynamic>,
                  'cacheCreationInputTokens',
                ),
                costUsd: ((entry.value as Map)['costUSD'] as num?)?.toDouble(),
              ),
      ],
    );
  }

  String _toolName(String name) {
    final prefix = _toolPrefix;
    return prefix != null && name.startsWith(prefix)
        ? name.substring(prefix.length)
        : name;
  }
}

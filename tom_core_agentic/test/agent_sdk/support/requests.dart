/// Requests as an application builds them, for the transport suites.
library;

import 'package:tom_llm/tom_llm.dart';

/// A request for [purpose] with [instruction] as the user channel and
/// [context] as the system channel — the shape the transports put on the wire
/// as the instruction followed by the context.
LlmRequest testRequest({
  String purpose = 'generate',
  String instruction = '',
  String context = '',
  String? model,
  String? sessionId,
  LlmToolBinding? toolBinding,
  bool keepTrailInMemory = false,
}) => LlmRequest(
  prompt: WirePrompt(
    system: context,
    user: instruction,
    anchorHash: '',
    roleId: purpose,
  ),
  options: LlmOptions(model: model, sessionId: sessionId),
  toolBinding: toolBinding,
  keepTrailInMemory: keepTrailInMemory,
);

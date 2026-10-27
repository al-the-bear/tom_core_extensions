/// The text a transport's event stream carries, in order, with the liveness
/// events dropped — what a suite asserts on when it drives a transport
/// directly rather than through the provider (which does this itself, under
/// its stall bound).
library;

import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

Stream<String> textOf(Stream<AgentSdkCompletionEvent> events) => events
    .map(
      (event) => switch (event) {
        AgentSdkTrailed(event: LlmTextDelta(:final text)) => text,
        _ => '',
      },
    )
    .where((text) => text.isNotEmpty);

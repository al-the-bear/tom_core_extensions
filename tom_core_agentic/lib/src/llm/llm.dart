// The Anthropic Agent SDK provider and its session strategies.
//
// The provider contract it implements — `LlmProvider`, `LlmRequest`, the
// `LlmEvent` union and the call report — is `tom_llm`'s, which this
// package re-exports so a caller of the Agent SDK provider names one import.
//
// **One provider ships here, and that is deliberate.** The brain's other three
// — an Ollama HTTP provider, an OpenAI passthrough, and a deterministic stub —
// stay with the brain, because each depends on brain-domain packages that sit
// *above* this layer. `example/llm/llm_example.dart` implements a second
// provider in fifty lines to show the contract is complete without them.
library;

export 'package:tom_llm/tom_llm.dart';

export 'agent_sdk_llm_provider.dart';
export 'agent_sdk_session.dart';

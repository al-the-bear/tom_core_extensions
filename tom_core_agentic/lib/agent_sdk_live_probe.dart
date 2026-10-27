/// Whether a **model** answers behind an AI transport — the probe every live
/// AI suite runs before it spends minutes on a real completion.
///
/// A separate entry point rather than part of the product barrel: it exists
/// for live suites — this package's and its consumers' — and a
/// product build has no reason to link it.
library;

export 'src/agent_sdk/live_model_probe.dart';

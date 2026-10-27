import 'package:tom_basics/utilities.dart';

/// Hashes [body] and returns it in the `sha256:<lowercase-hex>`
/// convention used as a content fingerprint across agentic trails.
///
/// This is the consolidation of the `_hashPrompt` helper that several
/// substrate LLM providers (`OllamaLlmProvider`, `OpenAiPassthroughProvider`,
/// `StubLlmProvider`) and the anchor registry grew independently. They
/// were behaviourally identical apart from a cosmetic split between
/// `'sha256:$digest'` and `'sha256:${digest.toString()}'` — both produce
/// the same string, but the divergent expression is exactly the drift a
/// single helper removes.
///
/// The digest is `tom_basics`' `tomSha256OfText` (UTF-8 bytes, lowercase
/// hex), the same hash every Tom package uses to name content. The prefix
/// lets a trail reader tell the hash algorithm from the digest without an
/// out-of-band agreement.
String promptSha256(String body) => 'sha256:${tomSha256OfText(body)}';

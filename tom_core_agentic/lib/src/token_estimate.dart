// Rough token-count estimation.
//
// The char/4 heuristic ("a token is roughly four characters of English
// text") is the standard cheap estimate used wherever a real tokenizer
// is unavailable or too expensive — usage accounting, budget pre-checks,
// log previews. It appears verbatim across substrate-shaped code; this is
// the single definition with its divisor named.

/// Approximate number of characters per token for the [estimateTokens]
/// heuristic. The familiar "~4 characters per token" rule of thumb for
/// English text; not exact and not a substitute for a real tokenizer.
const int approxCharsPerToken = 4;

/// A rough token-count estimate for [text]: `ceil(length /
/// approxCharsPerToken)`.
///
/// Cheap and tokenizer-free — suitable for budget pre-checks and usage
/// reporting where an exact count is unnecessary. An empty string
/// estimates to zero tokens.
int estimateTokens(String text) => (text.length / approxCharsPerToken).ceil();

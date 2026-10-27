// Deterministic, domain-free detection of "deliberation cues" in a prompt.
//
// An agent that routes a prompt between a fast answer path and a slower
// think-it-through path needs a *deterministic* tie-breaker: given the
// same text it must always pick the same branch, even when a model-based
// classifier is unavailable or returns something unreadable. This is that
// tie-breaker, with exactly one definition — a pure text scan for the
// canonical cue phrases ("think about", "ponder", "research", …) that
// signal the user is asking for deliberation rather than a quick reply.
//
// It is intentionally domain-free: it knows nothing about Tom Brain,
// procedures, or roles. It is a string operation over a fixed cue list,
// safe to reuse from any agent runtime. The richer judgement — does the
// prompt *really* want deliberation, beyond a passing mention of a cue
// word — belongs to the model-based classifier that calls this only as a
// fallback.

/// Which execution branch a prompt's surface text points to.
enum DeliberationVerdict {
  /// No deliberation cue present — the ordinary, fast answer path.
  normal,

  /// A deliberation cue is present — the slower think-it-through path.
  thinking,
}

/// The canonical deliberation cues, lower-case, in declaration order.
///
/// These are the phrases [classifyDeliberationCue] treats as a request to
/// deliberate. The list is deliberately tight — the model-based classifier
/// is the primary judge of intent; this fallback errs toward the fast
/// `normal` path rather than over-triggering `thinking` on a loose match.
/// A cue may be a single word (`ponder`) or a phrase (`think about`); both
/// are matched on word boundaries, so `research` matches "please research X"
/// but not "researcher".
const List<String> deliberationCues = <String>[
  'think about',
  'think through',
  'reason about',
  'work through',
  'reflect on',
  'mull over',
  'ponder',
  'research',
  'deliberate',
  'contemplate',
];

/// Classifies [text] as [DeliberationVerdict.thinking] when it contains any
/// of the [deliberationCues] (matched case-insensitively, on word
/// boundaries), otherwise [DeliberationVerdict.normal].
///
/// Pure and total: empty or whitespace-only text is [DeliberationVerdict.normal],
/// and the same input always yields the same verdict. Word-boundary matching
/// keeps the match honest — `research` matches "can you research the API" but
/// not the substring inside "researcher" or "rare searches".
DeliberationVerdict classifyDeliberationCue(String text) {
  for (final cue in deliberationCues) {
    if (_containsCue(text, cue)) return DeliberationVerdict.thinking;
  }
  return DeliberationVerdict.normal;
}

/// Whether [text] contains [cue] as a word-boundary-delimited match,
/// case-insensitively. [cue] is treated as a literal (regex metacharacters
/// are escaped), so a multi-word phrase matches across its internal spaces.
bool _containsCue(String text, String cue) {
  final pattern = RegExp('\\b${RegExp.escape(cue)}\\b', caseSensitive: false);
  return pattern.hasMatch(text);
}

// Length-bounded text preview for log lines, exception messages, and
// trail entries.
//
// Many subsystems need the same operation: "keep at most N characters
// of this string so a multi-megabyte error body does not bloat a log
// line, and mark that it was clipped". This is that operation, with
// exactly one definition.

/// Returns [text] unchanged when it is at most [limit] characters,
/// otherwise the first [limit] characters followed by [ellipsis].
///
/// The result keeps up to `limit` characters of the original; the
/// [ellipsis] is appended beyond that, so a clipped result has length
/// `limit + ellipsis.length`. The default ellipsis is the single-glyph
/// `…`; callers that must stay ASCII (e.g. some terminal logs) pass
/// `ellipsis: '...'`.
///
/// [limit] must be non-negative.
String textPreview(String text, {int limit = 512, String ellipsis = '…'}) {
  if (limit < 0) {
    throw ArgumentError.value(limit, 'limit', 'limit must be >= 0');
  }
  if (text.length <= limit) return text;
  return '${text.substring(0, limit)}$ellipsis';
}

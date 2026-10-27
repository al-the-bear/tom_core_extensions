// RFC 7231 HTTP-date parsing — without `dart:io`.
//
// `dart:io` ships an `HttpDate.parse`, but pulling in `dart:io` makes
// the consuming library VM-only. This re-implementation uses only core
// Dart so web tools that must compile under Flutter web can still parse
// a `Retry-After` / `Date` header.

/// Parser for the three date formats RFC 7231 § 7.1.1.1 permits in an
/// HTTP-date header.
///
/// Accepts:
///   - RFC 1123: `Wed, 21 Oct 2026 07:28:00 GMT`
///   - RFC 850:  `Wednesday, 21-Oct-26 07:28:00 GMT`
///   - asctime:  `Wed Oct 21 07:28:00 2026`
///
/// Always returns a UTC [DateTime]. Throws [FormatException] on any
/// unparseable input.
final class HttpDate {
  static const _months = <String, int>{
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static DateTime parse(String input) {
    final trimmed = input.trim();
    // RFC 1123 + RFC 850 share the comma; asctime does not.
    if (trimmed.contains(',')) {
      return _parseRfc1123OrRfc850(trimmed);
    }
    return _parseAsctime(trimmed);
  }

  static DateTime _parseRfc1123OrRfc850(String input) {
    // After the comma: `21 Oct 2026 07:28:00 GMT` or
    // `21-Oct-26 07:28:00 GMT`.
    final afterComma = input.split(',').last.trim();
    final tokens = afterComma.split(RegExp(r'[\s-]+'));
    if (tokens.length < 5) {
      throw FormatException('Invalid HTTP-date: $input');
    }
    final day = int.parse(tokens[0]);
    final month = _monthOrThrow(tokens[1]);
    final yearToken = tokens[2];
    final year = yearToken.length == 2
        ? 2000 + int.parse(yearToken)
        : int.parse(yearToken);
    final timeParts = tokens[3].split(':');
    if (timeParts.length != 3) {
      throw FormatException('Invalid HTTP-date time: $input');
    }
    return _buildUtc(input, year, month, day, timeParts);
  }

  static DateTime _parseAsctime(String input) {
    final tokens = input.split(RegExp(r'\s+'));
    if (tokens.length < 5) {
      throw FormatException('Invalid HTTP-date (asctime): $input');
    }
    final month = _monthOrThrow(tokens[1]);
    final day = int.parse(tokens[2]);
    final timeParts = tokens[3].split(':');
    if (timeParts.length != 3) {
      throw FormatException('Invalid HTTP-date asctime time: $input');
    }
    final year = int.parse(tokens[4]);
    return _buildUtc(input, year, month, day, timeParts);
  }

  /// Range-validates the calendar/clock fields and assembles a UTC [DateTime].
  ///
  /// `DateTime.utc` *silently normalises* out-of-range components (e.g. day 32
  /// rolls into the next month, hour 25 into the next day), so a malformed
  /// header would otherwise parse to a plausible-but-wrong instant instead of
  /// being rejected. Each field is bounded here so an invalid header
  /// throws [FormatException] rather than yielding a misleading date.
  static DateTime _buildUtc(
    String input,
    int year,
    int month,
    int day,
    List<String> timeParts,
  ) {
    final hour = int.parse(timeParts[0]);
    final minute = int.parse(timeParts[1]);
    final second = int.parse(timeParts[2]);
    _checkRange(input, 'day', day, 1, 31);
    _checkRange(input, 'hour', hour, 0, 23);
    _checkRange(input, 'minute', minute, 0, 59);
    // 60 admits a leap second, which RFC 7231 § 7.1.1.1 permits.
    _checkRange(input, 'second', second, 0, 60);
    return DateTime.utc(year, month, day, hour, minute, second);
  }

  static void _checkRange(
    String input,
    String field,
    int value,
    int lo,
    int hi,
  ) {
    if (value < lo || value > hi) {
      throw FormatException('Invalid HTTP-date $field ($value): $input');
    }
  }

  static int _monthOrThrow(String token) {
    // A short month token (e.g. truncated `Oc`) must be a FormatException, not
    // a RangeError from `substring(0, 3)` on a <3-char string.
    if (token.length < 3) {
      throw FormatException('Unknown HTTP-date month: $token');
    }
    final m = _months[token.toLowerCase().substring(0, 3)];
    if (m == null) {
      throw FormatException('Unknown HTTP-date month: $token');
    }
    return m;
  }
}

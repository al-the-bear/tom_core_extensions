// A multi-format parser for tool calls a model emitted as plain text.
//
// Many LLMs cannot (or will not) use a provider's native structured
// tool-call channel and instead write the tool call into the completion
// text in their own chat-template dialect. The dialects in the wild fall
// into two families:
//
//   * the *functional* family — `call:NAME{ARGS}`, optionally wrapped in
//     sentinels (`<|tool_call>call:web.search{query: "x"}<tool_call|>`),
//     whose `ARGS` is a JS-object literal with *unquoted* keys, single or
//     double quotes, bare numbers/booleans/null, and nested values; and
//   * the *JSON* family — a JSON object or array carrying a tool name and
//     an argument map, optionally inside `<tool_call>…</tool_call>`
//     (Hermes/Qwen), behind a `[TOOL_CALLS]` marker (Mistral), inside a
//     ```json fence, or as the OpenAI `{"function": {"name", "arguments":
//     "<json-string>"}}` shape where the arguments are a doubly-encoded
//     JSON string.
//
// [parseToolCallsFromText] recognises every one of those and lowers them
// to a single uniform [ParsedToolCall] shape, so a caller can recover a
// tool call regardless of which family the model belongs to. It is
// deliberately total: malformed input never throws — it yields an empty
// list. [looksLikeToolCallAttempt] is the cheap predicate a caller uses to
// decide whether a non-empty parse result was *expected* (and its absence
// therefore worth noting) without committing to a full parse.

import 'dart:convert';

/// One tool call recovered from model text, normalised across dialects.
///
/// [name] is the tool identifier exactly as the model wrote it (e.g.
/// `web.search`); [arguments] is the decoded argument object with `String`
/// keys, empty when the call carried no arguments.
final class ParsedToolCall {
  const ParsedToolCall(this.name, this.arguments);

  /// The tool identifier as written by the model.
  final String name;

  /// The decoded argument object; empty when the call had no arguments.
  final Map<String, Object?> arguments;

  @override
  String toString() => 'ParsedToolCall($name, $arguments)';
}

/// Parses every tool call [text] contains, across all known dialects.
///
/// The functional family (`call:NAME{…}`) is tried first; only when it
/// finds nothing does the JSON family run, so an input never double-counts
/// across families. When [knownToolNames] is supplied, calls to any other
/// name are dropped — the lever a caller uses to ignore a model's
/// hallucinated tool. Returns an empty list for prose, for JSON data that
/// is not a tool call, and for malformed input; it never throws.
List<ParsedToolCall> parseToolCallsFromText(
  String text, {
  Set<String>? knownToolNames,
}) {
  var calls = const <ParsedToolCall>[];
  try {
    calls = _functionalCalls(text);
    if (calls.isEmpty) {
      calls = _jsonCalls(text);
    }
  } catch (_) {
    return const <ParsedToolCall>[];
  }
  if (knownToolNames != null) {
    calls = calls
        .where((c) => knownToolNames.contains(c.name))
        .toList(growable: false);
  }
  return calls;
}

/// Whether [text] *looks like* an attempt at a tool call.
///
/// True when the text leads with a JSON object/array, carries a known
/// tool-call marker (`<tool_call>`, `<|tool_call>`, `[TOOL_CALLS]`), opens
/// a `call:NAME{` functional call, or starts a ``` fence. A caller uses it
/// to distinguish "the model tried to call a tool and we failed to parse
/// it" (worth noting) from "the model answered in prose" (expected).
bool looksLikeToolCallAttempt(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('{') || t.startsWith('[')) return true;
  if (t.startsWith('```')) return true;
  if (t.contains('<tool_call>') || t.contains('<|tool_call>')) return true;
  if (t.contains('[TOOL_CALLS]')) return true;
  return _functionalCallPattern.hasMatch(t);
}

// --- functional family: call:NAME{ARGS} -----------------------------------

final RegExp _functionalCallPattern = RegExp(r'call:([A-Za-z_][\w.]*)\s*\{');

List<ParsedToolCall> _functionalCalls(String text) {
  final out = <ParsedToolCall>[];
  for (final m in _functionalCallPattern.allMatches(text)) {
    final name = m.group(1)!;
    final braceStart = m.end - 1; // index of the opening '{'
    final braceEnd = _matchBrace(text, braceStart);
    if (braceEnd == null) continue;
    final body = text.substring(braceStart, braceEnd + 1);
    try {
      final value = _LenientParser(body).parseValue();
      if (value is Map) {
        out.add(ParsedToolCall(name, _asStringKeyMap(value)));
      }
    } catch (_) {
      // Malformed argument body — skip this call, keep the others.
    }
  }
  return out;
}

/// Returns the index of the `}` that closes the `{` at [start], or null
/// when the braces are unbalanced. String contents (single or double
/// quoted, with backslash escapes) are skipped so braces inside a value do
/// not affect the depth count.
int? _matchBrace(String s, int start) {
  var depth = 0;
  String? quote;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == r'\') {
        i++; // skip the escaped char
        continue;
      }
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

// --- JSON family ----------------------------------------------------------

final RegExp _toolCallTagPattern = RegExp(
  r'<tool_call>(.*?)</tool_call>',
  dotAll: true,
);
final RegExp _mistralMarkerPattern = RegExp(r'\[TOOL_CALLS\]');

List<ParsedToolCall> _jsonCalls(String text) {
  // Hermes/Qwen: one or more <tool_call>…</tool_call> blocks.
  final tagged = _toolCallTagPattern.allMatches(text).toList(growable: false);
  if (tagged.isNotEmpty) {
    final out = <ParsedToolCall>[];
    for (final m in tagged) {
      out.addAll(_interpretJsonPayload(m.group(1)!));
    }
    return out;
  }
  // Mistral: everything after the [TOOL_CALLS] marker.
  final mistral = _mistralMarkerPattern.firstMatch(text);
  if (mistral != null) {
    return _interpretJsonPayload(text.substring(mistral.end));
  }
  // Bare or fenced JSON object/array, possibly embedded in prose or
  // concatenated with siblings.
  return _scanBareJsonCalls(text);
}

/// Recovers every JSON tool call carried by [text] when it is neither tagged
/// nor marker-delimited.
///
/// Beyond the whole-text decode (the common case where the completion *is* a
/// single JSON value), this scans for each balanced `{…}` / `[…]` span — so a
/// JSON call buried in surrounding prose, or several concatenated bare objects
/// that are not wrapped in an array, are all recovered. Each span is
/// interpreted independently; spans that do not lower to a tool call are
/// dropped, so ordinary data-bearing prose never becomes a call.
List<ParsedToolCall> _scanBareJsonCalls(String text) {
  final cleaned = _stripFence(text);
  final out = <ParsedToolCall>[];
  // Bound the total scan work to keep this linear in the input length.
  // A balanced span the loop matches is jumped past, so a
  // well-formed input is scanned ~once and stays far under budget. The
  // pathological case is a long run of *unbalanced* openers: each one makes
  // `_matchBalanced` sweep to the end of the string and the outer loop then
  // advances a single character and re-sweeps — Θ(n²), enough to peg the
  // isolate on a few hundred KB of `{`. The budget caps that redundant work;
  // once spent the scan bails with whatever it has found.
  var budget = cleaned.length * 4 + 64;
  var i = 0;
  while (i < cleaned.length && budget > 0) {
    final c = cleaned[i];
    if (c == '{' || c == '[') {
      final span = _matchBalanced(cleaned, i, budget);
      budget -= span.scanned;
      if (span.end != null) {
        out.addAll(_interpretJsonPayload(cleaned.substring(i, span.end! + 1)));
        i = span.end! + 1;
        continue;
      }
    }
    i++;
  }
  return out;
}

/// Scans the `{`/`[` span opening at [start] for its matching close.
///
/// Returns `(end: i, scanned: n)` when the delimiter at index `i` balances the
/// span, or `(end: null, scanned: n)` when the span is unbalanced, its brackets
/// mismatch, or the [maxScan] character budget is exhausted before it balances.
/// `scanned` is always how many characters were examined, so the caller can
/// debit a shared work budget and keep the overall scan linear.
/// String contents (single or double quoted, with backslash escapes) are
/// skipped so a `{`, `}`, `[` or `]` inside a value does not affect the depth.
({int? end, int scanned}) _matchBalanced(String s, int start, int maxScan) {
  final closers = <String>[];
  String? quote;
  var i = start;
  for (; i < s.length && (i - start) < maxScan; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == r'\') {
        i++; // skip the escaped char
        continue;
      }
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '{') {
      closers.add('}');
    } else if (c == '[') {
      closers.add(']');
    } else if (c == '}' || c == ']') {
      if (closers.isEmpty || closers.removeLast() != c) {
        return (end: null, scanned: i - start + 1);
      }
      if (closers.isEmpty) return (end: i, scanned: i - start + 1);
    }
  }
  return (end: null, scanned: i - start);
}

List<ParsedToolCall> _interpretJsonPayload(String raw) {
  final cleaned = _stripFence(raw).trim();
  if (cleaned.isEmpty) return const <ParsedToolCall>[];
  Object? decoded;
  try {
    decoded = jsonDecode(cleaned);
  } catch (_) {
    try {
      decoded = _LenientParser(cleaned).parseValue();
    } catch (_) {
      return const <ParsedToolCall>[];
    }
  }
  return _callsFromDecoded(decoded);
}

List<ParsedToolCall> _callsFromDecoded(Object? decoded) {
  if (decoded is List) {
    final out = <ParsedToolCall>[];
    for (final element in decoded) {
      final call = _callFromObject(element);
      if (call != null) out.add(call);
    }
    return out;
  }
  final call = _callFromObject(decoded);
  return call == null ? const <ParsedToolCall>[] : <ParsedToolCall>[call];
}

/// Lowers one decoded JSON object to a [ParsedToolCall], or null when it is
/// not a tool call (e.g. plain data with no tool/name/function key).
ParsedToolCall? _callFromObject(Object? object) {
  if (object is! Map) return null;
  final map = _asStringKeyMap(object);
  // OpenAI nesting: {"function": {"name", "arguments"}}.
  if (map['function'] is Map) {
    return _callFromObject(map['function']);
  }
  final name = map['tool'] ?? map['name'];
  if (name is! String || name.isEmpty) return null;
  final argsRaw = map.containsKey('arguments')
      ? map['arguments']
      : map['parameters'];
  return ParsedToolCall(name, _decodeArguments(argsRaw));
}

/// Decodes an argument payload that may be a map, a (possibly doubly
/// encoded) JSON string, or absent.
Map<String, Object?> _decodeArguments(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is Map) return _asStringKeyMap(raw);
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return _asStringKeyMap(decoded);
    } catch (_) {
      try {
        final decoded = _LenientParser(trimmed).parseValue();
        if (decoded is Map) return _asStringKeyMap(decoded);
      } catch (_) {
        // fall through to the empty map
      }
    }
  }
  return const <String, Object?>{};
}

// --- shared helpers -------------------------------------------------------

String _stripFence(String text) {
  var t = text.trim();
  if (t.startsWith('```')) {
    final firstNewline = t.indexOf('\n');
    if (firstNewline != -1) t = t.substring(firstNewline + 1);
    if (t.endsWith('```')) t = t.substring(0, t.length - 3);
  }
  return t.trim();
}

Map<String, Object?> _asStringKeyMap(Map<Object?, Object?> map) =>
    <String, Object?>{
      for (final entry in map.entries) entry.key.toString(): entry.value,
    };

/// A tolerant recursive-descent parser for the JS-object-literal dialect
/// the functional family uses: unquoted keys, single or double quotes,
/// bare numbers/booleans/null, and nested objects and arrays. It also
/// accepts strict JSON (a subset). It throws on malformed input; callers
/// wrap it in try/catch and treat a throw as "not parseable".
class _LenientParser {
  _LenientParser(this._s);

  final String _s;
  int _i = 0;

  Object? parseValue() {
    _skipWhitespace();
    final c = _peek();
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == '"' || c == "'") return _string(c);
    if (c == 't' || c == 'f') return _bool();
    if (c == 'n') return _null();
    return _number();
  }

  Map<String, Object?> _object() {
    _expect('{');
    final map = <String, Object?>{};
    _skipWhitespace();
    if (_peek() == '}') {
      _i++;
      return map;
    }
    while (true) {
      _skipWhitespace();
      final key = _key();
      _skipWhitespace();
      _expect(':');
      map[key] = parseValue();
      _skipWhitespace();
      final c = _s[_i++];
      if (c == ',') continue;
      if (c == '}') break;
      throw const FormatException('expected , or }');
    }
    return map;
  }

  List<Object?> _array() {
    _expect('[');
    final list = <Object?>[];
    _skipWhitespace();
    if (_peek() == ']') {
      _i++;
      return list;
    }
    while (true) {
      list.add(parseValue());
      _skipWhitespace();
      final c = _s[_i++];
      if (c == ',') continue;
      if (c == ']') break;
      throw const FormatException('expected , or ]');
    }
    return list;
  }

  String _key() {
    final c = _peek();
    if (c == '"' || c == "'") return _string(c);
    final start = _i;
    while (_i < _s.length && _isKeyChar(_s[_i])) {
      _i++;
    }
    if (_i == start) throw const FormatException('empty key');
    return _s.substring(start, _i);
  }

  String _string(String quote) {
    _expect(quote);
    final buf = StringBuffer();
    while (_i < _s.length) {
      final c = _s[_i++];
      if (c == r'\') {
        final next = _s[_i++];
        switch (next) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case 'r':
            buf.write('\r');
          default:
            buf.write(next);
        }
      } else if (c == quote) {
        return buf.toString();
      } else {
        buf.write(c);
      }
    }
    throw const FormatException('unterminated string');
  }

  bool _bool() {
    if (_s.startsWith('true', _i)) {
      _i += 4;
      return true;
    }
    if (_s.startsWith('false', _i)) {
      _i += 5;
      return false;
    }
    throw const FormatException('bad boolean');
  }

  Object? _null() {
    if (_s.startsWith('null', _i)) {
      _i += 4;
      return null;
    }
    throw const FormatException('bad null');
  }

  Object _number() {
    final start = _i;
    while (_i < _s.length && _isNumberChar(_s[_i])) {
      _i++;
    }
    final token = _s.substring(start, _i);
    if (token.isEmpty) throw const FormatException('not a number');
    final asInt = int.tryParse(token);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(token);
    if (asDouble != null) return asDouble;
    throw FormatException('bad number: $token');
  }

  void _skipWhitespace() {
    while (_i < _s.length && _isWhitespace(_s[_i])) {
      _i++;
    }
  }

  String _peek() {
    if (_i >= _s.length) throw const FormatException('unexpected end of input');
    return _s[_i];
  }

  void _expect(String c) {
    if (_i >= _s.length || _s[_i] != c) {
      throw FormatException("expected '$c'");
    }
    _i++;
  }

  static bool _isWhitespace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';
  static bool _isKeyChar(String c) => RegExp(r'[\w.\-]').hasMatch(c);
  static bool _isNumberChar(String c) => RegExp(r'[-+0-9.eE]').hasMatch(c);
}

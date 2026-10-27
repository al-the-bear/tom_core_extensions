// Tests for the multi-format tool-call text parser.
//
// Many LLMs cannot (or will not) use a provider's native structured
// tool-call channel and instead emit the tool call as text in their own
// chat-template dialect. `parseToolCallsFromText` recognises the usual
// dialects and lowers them to one uniform `ParsedToolCall` shape, so a
// caller can recover a tool call regardless of which family the model
// belongs to. These tests pin each dialect plus the lenient argument
// parsing and the known-name filter.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('parseToolCallsFromText — Gemma/Google sentinel + call:name{args}', () {
    test('parses the <|tool_call>call:web.search{...}<tool_call|> dialect', () {
      // The exact shape observed live from Gemma-on-oMLX: a sentinel-wrapped
      // functional call whose argument object uses *unquoted* keys.
      const text =
          '<|tool_call>call:web.search{query: "reliable sources for news online"}'
          '<tool_call|>';

      final calls = parseToolCallsFromText(text);

      expect(calls, hasLength(1));
      expect(calls.single.name, 'web.search');
      expect(calls.single.arguments, <String, Object?>{
        'query': 'reliable sources for news online',
      });
    });

    test(
      'parses a bare call:file.search{pattern: "..."} without sentinels',
      () {
        const text = 'call:file.search{pattern: "answer_with_memory_v1.dart"}';

        final calls = parseToolCallsFromText(text);

        expect(calls, hasLength(1));
        expect(calls.single.name, 'file.search');
        expect(calls.single.arguments, <String, Object?>{
          'pattern': 'answer_with_memory_v1.dart',
        });
      },
    );

    test('functional call with no args yields an empty argument map', () {
      final calls = parseToolCallsFromText(
        '<|tool_call>call:memory.read{}<tool_call|>',
      );
      expect(calls, hasLength(1));
      expect(calls.single.name, 'memory.read');
      expect(calls.single.arguments, isEmpty);
    });
  });

  group('parseToolCallsFromText — JSON object dialects', () {
    test('OpenAI-ish {"tool", "arguments"} object', () {
      final calls = parseToolCallsFromText(
        '{"tool": "memory.read", "arguments": {"q": "x"}}',
      );
      expect(calls, hasLength(1));
      expect(calls.single.name, 'memory.read');
      expect(calls.single.arguments, <String, Object?>{'q': 'x'});
    });

    test('{"name", "parameters"} variant', () {
      final calls = parseToolCallsFromText(
        '{"name": "web.search", "parameters": {"query": "news"}}',
      );
      expect(calls.single.name, 'web.search');
      expect(calls.single.arguments, <String, Object?>{'query': 'news'});
    });

    test(
      'OpenAI nested {"function": {"name", "arguments": "<json-string>"}}',
      () {
        // The arguments here are a JSON *string* (as OpenAI tool_calls encode
        // them) and must be decoded a second time.
        final calls = parseToolCallsFromText(
          '{"function": {"name": "file.search", "arguments": "{\\"pattern\\": \\"x\\"}"}}',
        );
        expect(calls.single.name, 'file.search');
        expect(calls.single.arguments, <String, Object?>{'pattern': 'x'});
      },
    );

    test('markdown-fenced JSON tool call', () {
      final calls = parseToolCallsFromText(
        '```json\n{"tool": "memory.read", "arguments": {}}\n```',
      );
      expect(calls.single.name, 'memory.read');
      expect(calls.single.arguments, isEmpty);
    });

    test('a JSON array of calls yields one ParsedToolCall each', () {
      final calls = parseToolCallsFromText(
        '[{"tool": "a", "arguments": {}}, {"tool": "b", "arguments": {"n": 1}}]',
      );
      expect(calls.map((c) => c.name), <String>['a', 'b']);
      expect(calls[1].arguments, <String, Object?>{'n': 1});
    });
  });

  group('parseToolCallsFromText — Hermes/Qwen + Mistral dialects', () {
    test('<tool_call>{...}</tool_call> (Hermes/Qwen)', () {
      final calls = parseToolCallsFromText(
        'Sure.\n<tool_call>{"name": "web.search", "arguments": {"query": "q"}}</tool_call>',
      );
      expect(calls.single.name, 'web.search');
      expect(calls.single.arguments, <String, Object?>{'query': 'q'});
    });

    test('[TOOL_CALLS] [ {...} ] (Mistral)', () {
      final calls = parseToolCallsFromText(
        '[TOOL_CALLS] [{"name": "memory.read", "arguments": {"id": "n1"}}]',
      );
      expect(calls.single.name, 'memory.read');
      expect(calls.single.arguments, <String, Object?>{'id': 'n1'});
    });

    test('multiple <tool_call> blocks are all parsed in order', () {
      final calls = parseToolCallsFromText(
        '<tool_call>{"name":"a","arguments":{}}</tool_call>'
        '<tool_call>{"name":"b","arguments":{}}</tool_call>',
      );
      expect(calls.map((c) => c.name), <String>['a', 'b']);
    });
  });

  group('parseToolCallsFromText — JSON family robustness', () {
    test('a single JSON object wrapped in surrounding prose is recovered', () {
      // Not a delimited dialect (no fence, no <tool_call>, no [TOOL_CALLS]):
      // a bare object the model buried in a sentence. The whole-text decode
      // fails; the embedded-span scan recovers it.
      final calls = parseToolCallsFromText(
        'Here is the call you asked for: '
        '{"tool": "memory.read", "arguments": {"id": "n1"}} — done.',
      );
      expect(calls, hasLength(1));
      expect(calls.single.name, 'memory.read');
      expect(calls.single.arguments, <String, Object?>{'id': 'n1'});
    });

    test('a JSON array wrapped in prose is recovered', () {
      final calls = parseToolCallsFromText(
        'Sure, running these: '
        '[{"tool": "a", "arguments": {}}, {"tool": "b", "arguments": {"n": 1}}]'
        ' now.',
      );
      expect(calls.map((c) => c.name), <String>['a', 'b']);
      expect(calls[1].arguments, <String, Object?>{'n': 1});
    });

    test('multiple concatenated bare objects (no array) are all parsed', () {
      final calls = parseToolCallsFromText(
        '{"tool": "a", "arguments": {}}'
        '{"tool": "b", "arguments": {"n": 1}}',
      );
      expect(calls.map((c) => c.name), <String>['a', 'b']);
      expect(calls[1].arguments, <String, Object?>{'n': 1});
    });

    test('multiple bare objects separated by prose are all parsed', () {
      final calls = parseToolCallsFromText(
        'first {"tool": "a", "arguments": {}} then '
        '{"tool": "b", "arguments": {}} please',
      );
      expect(calls.map((c) => c.name), <String>['a', 'b']);
    });

    test(
      'an embedded non-tool JSON object inside prose still yields no calls',
      () {
        // Robustness must not turn ordinary data-bearing prose into a call.
        expect(
          parseToolCallsFromText('The record is {"answer": 42} for you.'),
          isEmpty,
        );
      },
    );

    test('knownToolNames still filters embedded calls', () {
      final filtered = parseToolCallsFromText(
        'Do this: {"tool": "web.search", "arguments": {}} '
        'and {"tool": "rm_rf", "arguments": {}}',
        knownToolNames: <String>{'web.search'},
      );
      expect(filtered.map((c) => c.name), <String>['web.search']);
    });

    test('a string containing braces does not desync the span scan', () {
      // The brace inside the quoted value must not break balance tracking.
      final calls = parseToolCallsFromText(
        'note: {"tool": "echo", "arguments": {"text": "a } b { c"}} end',
      );
      expect(calls.single.name, 'echo');
      expect(calls.single.arguments, <String, Object?>{'text': 'a } b { c'});
    });
  });

  group('parseToolCallsFromText — lenient argument values', () {
    test('single-quoted strings, numbers, booleans and null', () {
      final calls = parseToolCallsFromText(
        "call:t{a: 'hi', b: 3, c: 1.5, d: true, e: null}",
      );
      expect(calls.single.arguments, <String, Object?>{
        'a': 'hi',
        'b': 3,
        'c': 1.5,
        'd': true,
        'e': null,
      });
    });

    test('nested objects and arrays', () {
      final calls = parseToolCallsFromText(
        'call:t{outer: {inner: "v"}, list: [1, 2, "x"]}',
      );
      expect(calls.single.arguments, <String, Object?>{
        'outer': <String, Object?>{'inner': 'v'},
        'list': <Object?>[1, 2, 'x'],
      });
    });
  });

  group('parseToolCallsFromText — known-name filter & non-calls', () {
    test('plain prose yields no calls', () {
      expect(parseToolCallsFromText('The answer is 42.'), isEmpty);
    });

    test('a JSON object without a tool key yields no calls', () {
      // Valid JSON, but it is data, not a tool call.
      expect(parseToolCallsFromText('{"answer": 42}'), isEmpty);
    });

    test('knownToolNames filters out calls to unknown tools', () {
      const text = 'call:web.search{query: "x"} call:rm_rf{path: "/"}';
      final filtered = parseToolCallsFromText(
        text,
        knownToolNames: <String>{'web.search'},
      );
      expect(filtered.map((c) => c.name), <String>['web.search']);
    });

    test('malformed input never throws — returns empty', () {
      expect(parseToolCallsFromText('<|tool_call>call:broken{a: '), isEmpty);
      expect(
        parseToolCallsFromText('{"tool": "x", "arguments": {bad'),
        isEmpty,
      );
    });

    // An unbounded bare-JSON scan is quadratic on a long run of unbalanced
    // openers — for every `{`/`[` it scans to end-of-string, then the outer
    // loop advances one char and rescans, Θ(n²). A model completion (steerable
    // by prompt injection) of a few hundred KB of a single bracket char would
    // peg the agent isolate for minutes. The work is bounded instead, so a
    // large unbalanced run returns empty well within a small fixed time budget.
    test('a large unbalanced bracket run is bounded and yields no calls', () {
      final huge = '{' * 200000; // ~200 KB of unbalanced openers
      final sw = Stopwatch()..start();
      final calls = parseToolCallsFromText(huge);
      sw.stop();
      expect(calls, isEmpty);
      // Quadratic behaviour would take many seconds here; the bounded scan is
      // linear. A generous 2 s ceiling fails loudly on a regression without
      // flaking on a slow CI box.
      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason: 'scan must stay linear on adversarial input',
      );
    });

    test('a balanced JSON call embedded after prose is still recovered', () {
      // The work bound must not blind the scanner to a real call once the
      // (well-formed) input is comfortably under budget.
      const text = 'here you go: {"tool": "echo", "arguments": {"x": 1}} done';
      final calls = parseToolCallsFromText(text);
      expect(calls.map((c) => c.name), <String>['echo']);
    });
  });

  group('looksLikeToolCallAttempt', () {
    test('true for an object-leading or marker-bearing text', () {
      expect(looksLikeToolCallAttempt('{"answer": 42}'), isTrue);
      expect(looksLikeToolCallAttempt('<tool_call>...'), isTrue);
      expect(looksLikeToolCallAttempt('call:web.search{}'), isTrue);
      expect(looksLikeToolCallAttempt('[TOOL_CALLS] [...]'), isTrue);
    });

    test('false for plain prose', () {
      expect(looksLikeToolCallAttempt('The answer is 42.'), isFalse);
    });
  });
}

/// The stall bound's floor, re-measured on demand.
///
/// `defaultAiStallTimeout` is a *gap* bound: a completion is abandoned when
/// nothing at all arrives for that long. It is set at ten times the largest
/// silence a real completion was measured to contain, so it has to be
/// re-measured whenever the SDK, the model or the transport changes — and the
/// first measurement was made with throwaway probes. This is that probe, kept.
///
/// ```bash
/// export AGENT_SDK_LIVE_MEASURE=1
/// export AGENT_SDK_LIVE_HOSTED=1 # also measure the VS Code path
/// export AGENT_SDK_MEASURE_TOKENS=170000 # optional; the context size
/// dart test test/agent_sdk/stall_gap_measure_live_test.dart
/// ```
///
/// **Its own gate**, because one run spends about the context size in input
/// tokens per transport (~170k by default) plus a 32k thinking budget — a
/// cost the ordinary live suite (`AGENT_SDK_LIVE`) must not carry. The
/// hosted half additionally needs `AGENT_SDK_LIVE_HOSTED` and a running CLI
/// server (`tomAi.cliServer.start`).
///
/// **What it measures.** One query per transport: a generated ledger of
/// [_contextTokens] tokens, a question that takes a long stretch of reasoning
/// over it, and a fixed thinking budget, with partial messages on — the channel's own options,
/// plus the thinking budget, which is what makes a long silence possible.
/// Every `SdkMessage` is timed, and two numbers are printed:
///
/// * the **largest gap** between consecutive messages, and where it fell;
/// * the **prefill gap** — from the query to the first `message_start` —
///  which is the other long silence, and grows with the context.
///
/// It **fails** when the largest gap exceeds a tenth of
/// `defaultAiStallTimeout`, which is the margin that constant claims. A run
/// that did not read the whole context or did not reason at length fails as
/// NOT MEASURED: it holds no long silence, and a small figure from it says
/// nothing about the bound.
///
/// **Why it talks to `AgentSdkClient` directly.** The channel abandons a
/// completion on a gap but does not expose per-message timing, and its
/// request carries no thinking budget. So this opens its own connection to
/// the same server — the shipped standalone script, started here, and the
/// hosted CLI server found by the same port scan the transport uses — and
/// drives the same wire.
///
/// **Deadline.** A run is bounded at [_runBound] (the longest measured
/// completion took 188 s); the file allows twice that per transport, plus
/// the server start.
@Timeout(Duration(minutes: 20))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';
import 'package:tom_core_agentic/agent_sdk.dart';

import 'package:tom_core_agentic/agent_sdk_testing.dart';

const _gateVar = 'AGENT_SDK_LIVE_MEASURE';
const _hostedVar = 'AGENT_SDK_LIVE_HOSTED';
const _tokensVar = 'AGENT_SDK_MEASURE_TOKENS';

/// The default context size: the context assembler's ceiling, and the
/// size the original measurement found the longest prefill at.
const _defaultTokens = 170000;

/// The thinking budget the original measurement used.
const _thinkingBudget = 32000;

/// How long one measured run may take before it is reported as not finished.
const _runBound = Duration(minutes: 6);

int get _contextTokens =>
    int.tryParse(Platform.environment[_tokensVar] ?? '') ?? _defaultTokens;

bool _set(String name) => (Platform.environment[name] ?? '').isNotEmpty;

/// Output (thinking included) below which a run is not a measurement. The
/// original long run produced 8,538; this task produced 4,048 and 4,494 on
/// 2026-10-01, and one asking about 400 entries only ~2,500, which is the
/// short run this floor exists to refuse.
const _minimumOutputTokens = 3000;

/// What one measured query showed.
class _Measurement {
  _Measurement({
    required this.messages,
    required this.largestGap,
    required this.largestGapAt,
    required this.prefill,
    required this.total,
    required this.answered,
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
  });

  final int messages;
  final Duration largestGap;
  final String largestGapAt;
  final Duration? prefill;
  final Duration total;
  final bool answered;
  final String? model;

  /// Every input token the run was billed for, cached or not.
  final int inputTokens;

  /// Output tokens, thinking included.
  final int outputTokens;

  @override
  String toString() =>
      'model=$model messages=$messages total=${_s(total)} '
      'input=$inputTokens output=$outputTokens '
      'largestGap=${_s(largestGap)} at $largestGapAt '
      'prefill=${prefill == null ? 'none' : _s(prefill!)}';

  static String _s(Duration d) =>
      '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
}

const _accounts = [
  'atlas', 'birch', 'cobalt', 'delta', 'ember', 'fjord', //
  'garnet', 'harbor', 'indigo', 'juniper', 'kestrel', 'lumen',
];
const _flags = ['clear', 'review', 'hold', 'clear', 'clear', 'review'];

/// How many of the ledger's last entries the question asks about. Large
/// enough that answering means a long stretch of reasoning — the condition in
/// which the original measurement found its longest silences, between
/// `thinking_delta` bursts.
const _questionWindow = 1200;

/// A deterministic ledger of about [tokens] tokens.
String _context(int tokens) {
  final out = StringBuffer('<ledger>\n');
  // About 22 tokens per entry for this shape — measured: 12,142 entries
  // were billed as 265k input tokens.
  final entries = tokens ~/ 22;
  for (var n = 0; n < entries; n++) {
    out.writeln(
      'T$n account=${_accounts[(n * 7) % _accounts.length]} '
      'amount=${(n * 37) % 991 + 10} flag=${_flags[(n * 5) % _flags.length]}',
    );
  }
  out.write('</ledger>');
  return out.toString();
}

String _prompt(int tokens) =>
    '${_context(tokens)}\n\n'
    'Using only the ledger above and no tools: take the last '
    '$_questionWindow entries. For each account, add up the amounts of its '
    'entries flagged "review" among them. Work through it carefully, then '
    'answer with one line per account giving its total, and name the three '
    'accounts with the largest totals.';

/// The label a message is reported under: its wire type, and what it carries.
String _label(SdkMessage message) {
  final raw = message.raw;
  final type = raw['type'];
  if (type == 'stream_event') {
    final event = (raw['event'] as Map?) ?? const {};
    final delta = (event['delta'] as Map?)?['type'];
    return 'stream_event/${event['type']}${delta == null ? '' : '/$delta'}';
  }
  final subtype = raw['subtype'];
  return subtype == null ? '$type' : '$type/$subtype';
}

int _tokens(Map<String, dynamic>? usage, String key) =>
    (usage?[key] as num?)?.toInt() ?? 0;

/// Runs the measured query over [client] and times every message.
Future<_Measurement> _measure(VSCodeBridgeClient client) async {
  final agent = AgentSdkClient(VSCodeBridgeAgentSdkTransport(client));
  final started = DateTime.now();
  var last = started;
  var largest = Duration.zero;
  var largestAt = '(none)';
  Duration? prefill;
  var count = 0;
  var answered = false;
  String? model;
  Map<String, dynamic>? usage;

  final query = agent.query(
    prompt: _prompt(_contextTokens),
    options: Options(
      tools: const ToolsList([]),
      allowedTools: const [],
      maxTurns: 1,
      includePartialMessages: true,
      thinking: const ThinkingEnabled(budgetTokens: _thinkingBudget),
    ),
  );
  await for (final message in query.timeout(_runBound)) {
    final now = DateTime.now();
    final gap = now.difference(last);
    last = now;
    count++;
    final label = _label(message);
    if (gap > largest) {
      largest = gap;
      largestAt = label;
    }
    if (prefill == null && label == 'stream_event/message_start') {
      prefill = now.difference(started);
    }
    if (label == 'system/init') model = message.raw['model'] as String?;
    if (message is SdkAssistantMessage &&
        message.content.any((b) => b is TextBlock && b.text.isNotEmpty)) {
      answered = true;
    }
    if (message is SdkResultMessage) {
      if (message.isError) fail('the measured run failed: ${message.result}');
      usage = (message.raw['usage'] as Map?)?.cast<String, dynamic>();
    }
  }
  return _Measurement(
    messages: count,
    largestGap: largest,
    largestGapAt: largestAt,
    prefill: prefill,
    total: DateTime.now().difference(started),
    answered: answered,
    model: model,
    inputTokens:
        _tokens(usage, 'input_tokens') +
        _tokens(usage, 'cache_creation_input_tokens') +
        _tokens(usage, 'cache_read_input_tokens'),
    outputTokens: _tokens(usage, 'output_tokens'),
  );
}

/// The assertions every transport shares.
void _expectWithinMargin(String transport, _Measurement m) {
  // ignore: avoid_print — the measurement is the point of this suite.
  print('[$transport] $m');
  expect(
    m.answered,
    isTrue,
    reason: 'the run produced no answer, so its gaps measure nothing',
  );
  expect(
    m.prefill,
    isNotNull,
    reason:
        'no message_start arrived, so partial messages were not on '
        'and the gaps are not the ones the bound sees',
  );
  // NOT MEASURED, rather than a pass: a run that did not read the whole
  // context, or did not reason at length, has no long silence in it to find,
  // and a small largest gap from it says nothing about the bound.
  expect(
    m.inputTokens,
    greaterThanOrEqualTo(_contextTokens * 8 ~/ 10),
    reason:
        'NOT MEASURED: the run read ${m.inputTokens} input tokens of '
        'the ~$_contextTokens the context was built to hold',
  );
  expect(
    m.outputTokens,
    greaterThanOrEqualTo(_minimumOutputTokens),
    reason:
        'NOT MEASURED: the run produced ${m.outputTokens} output tokens '
        '(thinking included); without a long stretch of reasoning there is '
        'no long silence to measure',
  );
  final margin = defaultAiStallTimeout ~/ 10;
  expect(
    m.largestGap,
    lessThanOrEqualTo(margin),
    reason:
        '[$transport] the largest silence was ${m.largestGap}, more '
        'than a tenth of defaultAiStallTimeout ($defaultAiStallTimeout). '
        'Either raise the bound to ten times the new figure, or find out '
        'what made the far end go quiet for that long',
  );
}

void main() {
  if (!_set(_gateVar)) {
    test(
      'skipped — set $_gateVar=1 to spend ~$_defaultTokens '
      'tokens per transport measuring the stall gap',
      () {},
      skip: 'set $_gateVar=1 to enable',
    );
    return;
  }

  group('the standalone server', () {
    final node = findNodeForTests();
    final script = resolveDefaultServerScript();
    final installed = Directory(
      '${File(script).parent.path}/node_modules',
    ).existsSync();

    test('the largest silence of a long thinking completion is '
        'within a tenth of the stall bound', () async {
      if (node == null || !installed) {
        fail(
          '$_gateVar is set, so this may not skip — but '
          '${node == null ? 'no Node >= 20 was found' : 'the server has no node_modules (run `npm ci --omit=dev` in tom_core_agentic/node)'}.',
        );
      }
      final server = await Process.start(node, [script]);
      addTearDown(() async {
        await server.stdin.close();
        server.kill();
      });
      server.stderr
          .transform(utf8.decoder)
          .listen((line) => printOnFailure('[server] $line'));
      final ready = await server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((l) => l.startsWith(standaloneReadyPrefix))
          .timeout(const Duration(seconds: 60));
      final port =
          (jsonDecode(ready.substring(standaloneReadyPrefix.length))
                  as Map<String, dynamic>)['port']
              as int;

      final client = VSCodeBridgeClient(host: '127.0.0.1', port: port);
      expect(await client.connect(), isTrue);
      addTearDown(client.disconnect);

      _expectWithinMargin('standalone', await _measure(client));
    }, timeout: Timeout(_runBound * 2 + const Duration(minutes: 1)));
  });

  group('the hosted CLI server', () {
    test('the largest silence of a long thinking completion is '
        'within a tenth of the stall bound', () async {
      if (!_set(_hostedVar)) {
        markTestSkipped(
          'set $_hostedVar=1 with VS Code running and the CLI '
          'server started to measure the hosted path',
        );
        return;
      }
      final servers = await scanBridgePorts();
      expect(
        servers,
        isNotEmpty,
        reason:
            '$_hostedVar is set, but no CLI server answered — start it '
            'with the extension command tomAi.cliServer.start',
      );
      final port = (servers.keys.toList()..sort()).first;

      final client = VSCodeBridgeClient(host: '127.0.0.1', port: port);
      expect(await client.connect(), isTrue);
      addTearDown(client.disconnect);

      _expectWithinMargin('hosted', await _measure(client));
    }, timeout: Timeout(_runBound * 2));
  });
}

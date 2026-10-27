/// What the README example prints, asserted.
///
/// The README's fences appear in `example/readme_example.dart` verbatim, and
/// the analyzer holds that file to the API. Neither shows that the example produces what its trailing comments
/// say it produces. This does: it runs the example's own `main` and asserts
/// the lines. The expectations are written here rather than parsed out of the
/// comments, so the test states a claim of its own and does not agree with the
/// example by construction.
///
/// **Deadline.** The precondition probes the standalone transport, which runs
/// `node --version` under a 5 s bound; 60 s keeps the harness out of its way.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/io.dart';

import '../../example/agent_sdk/readme.dart' as example;

/// Runs [body] and returns every line it printed, in order.
///
/// A zone rather than a subprocess: the point is the values, and a subprocess
/// re-resolves the package to learn them.
Future<List<String>> _printed(FutureOr<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    () async => body(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.addAll(line.split('\n')),
    ),
  );
  return lines;
}

void main() {
  test('the example prints the prompt and, with no AI '
      'server present, stops at the shut gate', () async {
    // The example builds its own transports, so what it reaches is a fact
    // about the machine. Where a server would answer, running it is a real,
    // paid completion and its output is a model's — neither belongs in a
    // suite, so the precondition is checked and said rather than assumed.
    //
    // Three ways one can be: a hosted responder, a key in the environment,
    // or a standalone server this machine can start — a Node at the floor
    // and an installed `node/` tree, whose SDK then falls back to the
    // ambient Claude Code login with no key set at all. The last is asked
    // through the transport's own probe, which starts nothing and sends
    // nothing.
    final responders = await discoverHostedAiWorkspaces();
    final standalone = await StandaloneNodeAiTransport(
      node: llmNodeResolverFor(),
    ).probe();
    if (responders.isNotEmpty ||
        standalone ||
        Platform.environment.containsKey('ANTHROPIC_API_KEY')) {
      markTestSkipped(
        'an AI backend is reachable from this machine '
        '(${responders.length} hosted responder(s), a standalone server '
        'that can start: $standalone, or an API key in the environment); '
        'the example would stream a real completion',
      );
      return;
    }

    expect(await _printed(example.main), [
      'The formula engine now recalculates transitively.',
      '',
      'Summarize this in five words.',
      'AI unavailable',
    ]);
  });
}

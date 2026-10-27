/// The gate's rule, enforced as a rule: when the availability gate
/// shuts, the message says what to fix.
///
/// `unreachable` is the one error kind that closes the gate, and its
/// MESSAGE, not its kind, is what reaches the user. Three conditions had a test
/// of their own sentence; nothing held the rule, so a fourth site could raise
/// `unreachable` with a bare message and nothing would notice.
///
/// So the construction sites are FOUND, not listed: every
/// `LlmTransportException(LlmErrorKind.unreachable, …)` in
/// `lib/` is discovered by a source walk and must appear in [_sites], either as
/// a remedy site — whose message, read out of the source, must contain the
/// phrases that name the remedy — or as an exemption carrying its reason. A new
/// site is unclassified, so it fails; the count is asserted as well, so a site
/// the walk cannot see does not pass by being invisible.
///
///  spawns a stand-in server whose startup bound is 10 s.
@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_llm/tom_llm.dart';

/// How each discovered site is judged. Keyed by file and by the start of the
/// message expression as it appears in source (whitespace collapsed).
final _sites = <String, _Site>{
  // ── remedy sites: the message names what to do ──────────────────────────
  'standalone_transport.dart|\'The standalone AI server script was not found':
      const _Site.remedy(['was not found at', 'Set ', 'configure the path']),
  'standalone_transport.dart|\'Could not start the standalone AI server: \$nodeProblem':
      // The sentence is `_nodeProblem`'s; its two answers are checked there.
      const _Site.remedy(
        ['Upgrade Node', 'Install ', 'point the setting'],
        via: [
          'Future<String?> agentSdkNodeProblemFor(',
          'Future<String?> agentSdkNodeProblem(',
          'String agentSdkNodeMissingReason(',
          'String agentSdkNodeNotRunnableReason(',
          'String agentSdkNodeTooOldReason(',
        ],
      ),
  'standalone_transport.dart|\'Could not start the standalone AI server: \$installProblem':
      // The server is not installed (or is outdated); the remedy is
      // the Install action, and the sentence links the explanation.
      const _Site.remedy(
        ['select Install', 'Select Install', 'agentSdkInstallExplanationUrl'],
        via: ['String? _installProblem('],
      ),
  'standalone_transport.dart|\'Could not start the standalone AI server: "\$nodeExecutable" is not':
      const _Site.remedy(['is not ', 'Install Node.js', 'point the setting']),
  'standalone_transport.dart|\'Could not start the standalone AI server: no private configuration \'':
      // The per-child configuration directory an explicit key
      // needs could not be made; the remedy is a writable data directory.
      const _Site.remedy(['directory can be written']),
  'hosted_transport.dart|_noServerMessage': const _Site.remedy(
    ['No VS Code CLI server', 'reports the', 'workspace'],
    via: ['String get _noServerMessage'],
  ),
  'cli_server_channel.dart|\'Could not connect to the AI server on':
      const _Site.remedy(['answered moments ago', 'Try again', 'restart']),

  // ── exemptions: named, with the reason there is no remedy to state ──────
  'hosted_transport.dart|\'The hosted AI transport is not connected.':
      const _Site.exempt(
        'an ordering error inside the provider — it always '
        'connects before completing — so no user state reaches it',
      ),
  'standalone_transport.dart|\'The standalone AI transport is not connected.':
      const _Site.exempt('the same ordering error, on the standalone side'),
  'session_manager.dart|message,': const _Site.exempt(
    're-raises, for the availability gate in the main isolate, the failure a session '
    'isolate\'s transport already reported — its message is that '
    'transport\'s own, classified at the transport\'s site',
  ),
  'standalone_transport.dart|_closing ?': const _Site.exempt(
    'two exits: a close the user asked for mid-start (no '
    'fault to fix), and the child crashing before it was ready — whose '
    'cause only the child knows, so the message carries its last stderr '
    'lines instead of a remedy',
  ),
};

class _Site {
  final List<String> phrases;
  final List<String>? via;
  final String? reason;
  const _Site.remedy(this.phrases, {this.via}) : reason = null;
  const _Site.exempt(this.reason) : phrases = const [], via = null;
}

class _Found {
  final String file;
  final String source;
  final String key;
  final String message;
  _Found(this.file, this.source, this.key, this.message);
}

String _flat(String s) => s
    .split('\n')
    .map((l) => l.replaceFirst(RegExp(r'^\s*//.*$'), ''))
    .join(' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

List<_Found> _discover() {
  final found = <_Found>[];
  for (final f in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final src = f.readAsStringSync();
    const marker = 'LlmErrorKind.unreachable,';
    var at = src.indexOf(marker);
    while (at >= 0) {
      // The kind is the constructor's first argument, but comments may sit
      // between them — so: the nearest constructor before it, with no
      // statement ending in between (comments stripped before looking).
      final ctor = src.lastIndexOf('LlmTransportException(', at);
      final between = ctor < 0
          ? ';'
          : src.substring(ctor, at).replaceAll(RegExp(r'//[^\n]*'), '');
      if (!between.contains(';')) {
        final end = src.indexOf('transportId:', at);
        final message = _flat(src.substring(at + marker.length, end));
        final name = f.uri.pathSegments.last;
        final head = message.length > 70 ? message.substring(0, 70) : message;
        found.add(_Found(name, src, '$name|$head', message));
      }
      at = src.indexOf(marker, at + marker.length);
    }
  }
  return found;
}

/// The member [signature] opens: a `=>` body to its `;`, a block body to its
/// matching brace.
String _member(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, isNot(-1), reason: '"$signature" not found');
  final arrow = src.indexOf('=>', start);
  final block = src.indexOf('{', start);
  if (arrow >= 0 && (block < 0 || arrow < block)) {
    return _flat(src.substring(start, src.indexOf(';\n', arrow)));
  }
  var depth = 0;
  for (var i = block; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) {
      return _flat(src.substring(start, i + 1));
    }
  }
  fail('unbalanced braces after "$signature"');
}

_Site? _classify(String key) {
  for (final entry in _sites.entries) {
    if (key.startsWith(entry.key)) return entry.value;
  }
  return null;
}

void main() {
  group('every shut gate says what to fix', () {
    late final List<_Found> found = _discover();

    test('every unreachable construction site is classified', () {
      final unclassified = [
        for (final f in found)
          if (_classify(f.key) == null) '${f.key}…',
      ];
      expect(
        unclassified,
        isEmpty,
        reason:
            'these raise `unreachable` — which closes the AI gate — and '
            'nobody decided whether their message tells the user what to '
            'fix. Add each to _sites: a remedy site with the phrases that '
            'name the fix, or an exemption with its reason:\n'
            '${unclassified.join('\n')}',
      );
    });

    test('the count of sites is the count of classifications', () {
      // Both directions: a site the walk cannot see would leave a
      // classification with nothing behind it.
      expect(
        found,
        hasLength(_sites.length),
        reason: 'found: ${found.map((f) => f.key).join('\n')}',
      );
      for (final key in _sites.keys) {
        expect(
          found.where((f) => f.key.startsWith(key)),
          hasLength(1),
          reason: 'classification "$key" matches no single site',
        );
      }
    });

    test('every remedy site\'s message names the remedy', () {
      for (final f in found) {
        final site = _classify(f.key);
        if (site == null || site.reason != null) continue;
        final text = site.via == null
            ? f.message
            : site.via!.map((v) => _member(f.source, v)).join(' ');
        for (final phrase in site.phrases) {
          expect(
            text,
            contains(phrase),
            reason: '${f.key}…: the message no longer says "$phrase"',
          );
        }
      }
    });

    test('every exemption says why', () {
      for (final site in _sites.values.where((s) => s.reason != null)) {
        expect(site.reason!.length, greaterThan(30));
      }
    });
  });

  group('the exempt crash still says what happened', () {
    test(
      'a server that dies before it is ready is reported with its '
      'last stderr lines, not just its exit code',
      () async {
        // The one exemption with a user-visible cause: only the child knows why
        // it died, so its own words go into the message. The interpreter is a
        // shell script — the version probe passes an answer it cannot parse —
        // that writes two lines and exits.
        final dir = Directory.systemTemp.createTempSync(
          'agent_sdk_unreachable',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final script = File('${dir.path}/server.mjs')..writeAsStringSync('');
        final node = File('${dir.path}/fake-node')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'if [ "\$1" = "--version" ]; then echo "fake"; exit 0; fi\n'
            'echo "Error: Cannot find module \'@anthropic-ai/claude-agent-sdk\'" >&2\n'
            'echo "code: ERR_MODULE_NOT_FOUND" >&2\n'
            'exit 7\n',
          );
        Process.runSync('chmod', ['755', node.path]);
        final transport = StandaloneNodeAiTransport(
          node: llmNodeAt(node.path),
          serverScript: script.path,
          startupTimeout: const Duration(seconds: 10),
        );
        addTearDown(transport.close);

        final error = await transport.connect().then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        expect(error, isA<LlmTransportException>());
        final e = error! as LlmTransportException;
        expect(e.kind, LlmErrorKind.unreachable);
        expect(e.message, contains('exited with code 7'));
        expect(
          e.message,
          contains('Cannot find module'),
          reason: 'the cause, in the child\'s own words',
        );
        expect(e.message, contains('ERR_MODULE_NOT_FOUND'));
      },
      skip: Platform.isWindows
          ? 'a POSIX shell script stands in for node'
          : null,
    );

    // . The exit code and the child's stderr travel on different
    // pipes, and the exit can arrive first: under load, one full-suite run in
    // twenty reported "wrote nothing to stderr" for a child that had written
    // its cause, and a stress of this scenario lost the cause 4 times in 200.
    // Both tests below make the ordering deterministic with a grandchild that
    // inherits the stderr pipe, so the pipe outlives the child.

    Future<LlmTransportException> earlyExit(String body) async {
      final dir = Directory.systemTemp.createTempSync('agent_sdk_config');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/server.mjs')..writeAsStringSync('');
      final node = File('${dir.path}/fake-node')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'if [ "\$1" = "--version" ]; then echo "fake"; exit 0; fi\n'
          '$body'
          'exit 7\n',
        );
      Process.runSync('chmod', ['755', node.path]);
      final transport = StandaloneNodeAiTransport(
        node: llmNodeAt(node.path),
        serverScript: script.path,
        startupTimeout: const Duration(seconds: 10),
      );
      addTearDown(transport.close);
      final error = await transport.connect().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      return error! as LlmTransportException;
    }

    test(
      'stderr that arrives after the exit code is still in the '
      'report',
      () async {
        final e = await earlyExit(
          '(sleep 0.3; echo "Error: late cause" >&2) &\n',
        );
        expect(e.message, contains('exited with code 7'));
        expect(
          e.message,
          contains('late cause'),
          reason: 'the report was composed before stderr had drained',
        );
      },
      skip: Platform.isWindows
          ? 'a POSIX shell script stands in for node'
          : null,
    );

    test(
      'a pipe held open by a grandchild delays the report by the '
      'bound, not indefinitely',
      () async {
        final watch = Stopwatch()..start();
        final e = await earlyExit(
          'echo "Error: early cause" >&2\n'
          '(sleep 15) &\n',
        );
        watch.stop();
        expect(e.message, contains('early cause'));
        expect(
          watch.elapsed,
          lessThan(
            StandaloneNodeAiTransport.stderrDrainBound +
                const Duration(seconds: 3),
          ),
          reason:
              'the report must not wait for a pipe the child no longer '
              'holds',
        );
      },
      skip: Platform.isWindows
          ? 'a POSIX shell script stands in for node'
          : null,
    );
  });
}

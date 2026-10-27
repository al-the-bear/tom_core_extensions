/// Writes a recorded Agent SDK run as the run events the transports make of
/// it — the replay an application's UI test feeds a stand-in transport.
///
/// The input is one of `test/agent_sdk/fixtures/sdk_messages/<transport>_agent_run.json`
/// (recorded by `test/agent_sdk/event_stream_live_test.dart`); the output is a JSON list
/// of `LlmEvent.toMap` maps, liveness dropped. The translation is the one a
/// live run goes through (`SdkTrailTranslator`), so the replay is what the
/// trail would have shown, not a paraphrase of it.
///
/// ```
/// dart run tool/write_trail_replay.dart \
///  test/agent_sdk/fixtures/sdk_messages/hosted_agent_run.json out.json [tool-server]
/// ```
///
/// `tool-server` is the in-process MCP server the recording's tools were
/// declared on (default `tools`, the name the recordings use), so the replay
/// names each tool without its `mcp__<server>__` prefix.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/src/agent_sdk/transport/sdk_trail_translator.dart';
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';

void main(List<String> args) {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'usage: write_trail_replay.dart <recording.json> <out.json> '
      '[tool-server]',
    );
    exitCode = 64;
    return;
  }
  final recording = jsonDecode(File(args[0]).readAsStringSync()) as List;
  final translator = SdkTrailTranslator(
    providerId: 'hosted',
    toolServerName: args.length == 3 ? args[2] : 'tools',
  );
  final events = [
    for (final raw in recording)
      for (final event in translator.translate(
        SdkMessage.fromJson((raw as Map).cast<String, dynamic>()),
      ))
        if (event case AgentSdkTrailed(:final event)) event.toMap(),
  ];
  File(args[1])
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(events)}\n',
    );
  stdout.writeln('${events.length} events -> ${args[1]}');
}

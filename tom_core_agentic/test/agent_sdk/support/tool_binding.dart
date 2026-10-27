/// A tool binding a suite can hand a request: one tool, `set_headline`, over
/// an in-memory map, recording every call it is asked to make.
library;

import 'package:tom_llm/tom_llm.dart';

/// The in-process MCP server name the suites declare tools on.
const testToolServer = 'tools';

/// A store of section headlines with one tool that sets one.
final class HeadlineToolBinding implements LlmToolBinding {
  /// The headlines the tool has set, by section id.
  final Map<String, String> headlines = {};

  /// The name of every call the binding answered, in order.
  final List<String> calls = [];

  @override
  List<ToolDescriptor> get declarations => const [
    ToolDescriptor(
      name: 'set_headline',
      description: 'Sets the headline of the section with the given id.',
      parametersSchema: {
        'type': 'object',
        'properties': {
          'sectionId': {'type': 'string'},
          'headline': {'type': 'string'},
        },
        'required': ['sectionId', 'headline'],
      },
    ),
  ];

  @override
  Future<LlmToolAnswer> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    calls.add(name);
    if (name != 'set_headline') {
      return (isError: true, text: 'E_UNKNOWN_TOOL: no tool $name');
    }
    final id = arguments['sectionId'];
    final headline = arguments['headline'];
    if (id is! String || headline is! String) {
      return (isError: true, text: 'E_INVALID_ARGUMENT: sectionId, headline');
    }
    headlines[id] = headline;
    return (isError: false, text: 'Headline of $id set.');
  }
}

/// A tool surface for LLM agents: declared tools, a permission scope with a
/// fixed gate order, an invocation record that carries execution consent, an
/// append-only audit trail, the presentations a model sees (native tool
/// declarations, an in-process MCP server) and preview-then-apply runs.
library;

export 'src/agent_tools/audit.dart';
export 'src/agent_tools/binding.dart';
export 'src/agent_tools/errors.dart';
export 'src/agent_tools/invocation.dart';
export 'src/agent_tools/preview_then_apply.dart';
export 'src/agent_tools/schema.dart';
export 'src/agent_tools/scope.dart';
export 'src/agent_tools/tool.dart';

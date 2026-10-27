/// Generic, domain-free building blocks for agentic systems.
///
/// Everything exported here depends only on `tom_basics` (plus `yaml`
/// for [YamlConfigReader] and `path` for [PathScope]) and is safe to
/// reuse across the brain, the assistant, and any future agent runtime.
library;

export 'src/agent/agent.dart';
export 'src/argument_guards.dart';
export 'src/async_shutdown.dart';
export 'src/bearer_auth/bearer_auth.dart';
export 'src/category_log.dart';
export 'src/close_guard.dart';
export 'src/collection_equality.dart';
export 'src/day_boundary.dart';
export 'src/deadline.dart';
export 'src/dedup_by_id.dart';
export 'src/deliberation_cue.dart';
export 'src/exception_format.dart';
export 'src/http_date.dart';
export 'src/isolate_streaming/isolate_streaming.dart';
export 'src/json_helpers.dart';
export 'src/latency_summary.dart';
export 'src/llm/llm.dart';
export 'src/map_field_reader.dart';
export 'src/mcp_auth/mcp_auth.dart';
export 'src/path_scope.dart';
export 'src/path_scope_io.dart';
export 'src/placeholders/placeholders.dart';
export 'src/plan_ordering.dart';
export 'src/procedure_rerank.dart';
export 'src/prompt_sha256.dart';
export 'src/sql_helpers.dart';
export 'src/system_clock.dart';
export 'src/text_preview.dart';
export 'src/token_bucket.dart';
export 'src/token_estimate.dart';
export 'src/tool_call_text_parser.dart';
export 'src/ttl_cache.dart';
export 'src/yaml_config_reader.dart';
export 'src/yaml_to_map.dart';

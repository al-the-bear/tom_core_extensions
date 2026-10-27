// Editor-facing agent data models.
//
// The TomSpecs editor's persisted domain objects — profiles, the prompt
// queue, chat / trail messages, reminder templates, timed requests — plus
// the YAML codec they round-trip through and the editor placeholder binder.
// They live in `tom_core_agentic` so the editor and any future agent runtime
// share one model layer. All models are domain-neutral and depend
// only on `tom_basics`, `yaml` / `yaml_edit`, and the in-package placeholder
// engine.
library;

export 'agent_profile.dart';
export 'agent_profile_store.dart';
export 'agent_send.dart';
export 'agent_settings.dart';
export 'agent_settings_store.dart';
export 'agent_sidecar.dart';
export 'agent_yaml.dart';
export 'bridge_connection.dart';
export 'chat_message.dart';
export 'chat_variable.dart';
export 'chat_variable_store.dart';
export 'editor_placeholder_bindings.dart';
export 'prompt_queue.dart';
export 'prompt_queue_store.dart';
export 'prompt_template.dart';
export 'prompt_template_store.dart';
export 'prompt_trail_store.dart';
export 'queue_template.dart';
export 'queue_template_store.dart';
export 'reconnect.dart';
export 'reminder_template.dart';
export 'reminder_template_store.dart';
export 'timed_request.dart';
export 'timed_request_store.dart';

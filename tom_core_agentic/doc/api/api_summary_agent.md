# Tom Core Agentic API Reference: Agent Module

The symbol-level mirror of `lib/src/agent/`: 52 exported types, 13 top-level
functions, 4 constants and 3 public statics, each with a section.

[`doc/agent.md`](../agent.md) explains how the unit behaves — the degradation
rule, the bridge protocol, the back-off, the retry conditions. This document is
arranged for lookup instead: one heading per symbol, grouped by the concern the
symbol belongs to.

## Table of Contents

- [Overview](#overview)
- [The models](#the-models)
  - [AgentProfile](#agentprofile)
  - [ToolApprovalMode](#toolapprovalmode)
  - [AgentSettings](#agentsettings)
  - [ChatRole](#chatrole)
  - [ChatMessage](#chatmessage)
  - [TrailPair](#trailpair)
  - [ChatVariable](#chatvariable)
  - [QueuedPrompt](#queuedprompt)
  - [QueuedPrePrompt](#queuedpreprompt)
  - [QueuedFollowUpPrompt](#queuedfollowupprompt)
  - [QueuedPromptStatus](#queuedpromptstatus)
  - [QueuedPrePromptStatus](#queuedprepromptstatus)
  - [QueuedPromptType](#queuedprompttype)
  - [QueuedTransport](#queuedtransport)
  - [PromptTemplate](#prompttemplate)
  - [QueueTemplate](#queuetemplate)
  - [ReminderTemplate](#remindertemplate)
  - [TimedRequest](#timedrequest)
  - [ScheduleMode](#schedulemode)
  - [TimedRequestStatus](#timedrequeststatus)
  - [ScheduledTime](#scheduledtime)
- [The stores](#the-stores)
  - [AgentProfileStore](#agentprofilestore)
  - [AgentSettingsStore](#agentsettingsstore)
  - [ChatVariableStore](#chatvariablestore)
  - [PromptQueueStore](#promptqueuestore)
  - [PromptTemplateStore](#prompttemplatestore)
  - [QueueTemplateStore](#queuetemplatestore)
  - [TimedRequestStore](#timedrequeststore)
  - [PromptTrailStore](#prompttrailstore)
  - [ReminderTemplateStore](#remindertemplatestore)
  - [SpecSessionStore](#specsessionstore)
  - [BridgeChoiceStore](#bridgechoicestore)
- [The YAML plumbing](#the-yaml-plumbing)
  - [readAgentYamlFile](#readagentyamlfile)
  - [decodeAgentYamlList](#decodeagentyamllist)
  - [decodeAgentYamlValue](#decodeagentyamlvalue)
  - [decodeAgentYamlEntries](#decodeagentyamlentries)
  - [encodeAgentYaml](#encodeagentyaml)
  - [decodeAgentYaml](#decodeagentyaml)
  - [deepPlainYaml](#deepplainyaml)
  - [yamlValue](#yamlvalue)
  - [yamlStringList](#yamlstringlist)
  - [yamlEnum](#yamlenum)
- [Bridge discovery and binding](#bridge-discovery-and-binding)
  - [BridgeServer](#bridgeserver)
  - [BridgeServerStatus](#bridgeserverstatus)
  - [BridgePortScanner](#bridgeportscanner)
  - [BridgeConnectionService](#bridgeconnectionservice)
  - [BridgeChoice](#bridgechoice)
  - [connectAgentSdkClient](#connectagentsdkclient)
  - [AgentSdkClientFactory](#agentsdkclientfactory)
- [Reconnect](#reconnect)
  - [ReconnectCoordinator](#reconnectcoordinator)
  - [ReconnectResult](#reconnectresult)
  - [ReconnectResolution](#reconnectresolution)
  - [ReconnectDelay](#reconnectdelay)
  - [composeInterruptRetry](#composeinterruptretry)
- [The send engine](#the-send-engine)
  - [AgentSendEngine](#agentsendengine)
  - [AgentSendConfig](#agentsendconfig)
  - [AgentSendEvent](#agentsendevent)
  - [AgentSendStarted](#agentsendstarted)
  - [AgentSendChunk](#agentsendchunk)
  - [AgentSendSessionRefreshed](#agentsendsessionrefreshed)
  - [AgentSendCompleted](#agentsendcompleted)
  - [AgentSendFailed](#agentsendfailed)
  - [specSessionLooksLikeError](#specsessionlookslikeerror)
  - [permissionModeForApproval](#permissionmodeforapproval)
  - [thinkingConfigFor](#thinkingconfigfor)
- [Placeholders](#placeholders)
  - [EditorPlaceholderBindings](#editorplaceholderbindings)
  - [PlaceholderExpressionsUnsupportedError](#placeholderexpressionsunsupportederror)
- [Constants](#constants)
  - [defaultBridgeHost](#defaultbridgehost)
  - [bridgeScanMinPort](#bridgescanminport)
  - [bridgeScanMaxPort](#bridgescanmaxport)
  - [defaultReconnectBackoff](#defaultreconnectbackoff)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

Sources: `lib/src/agent/agent.dart`, `lib/src/agent/agent_profile.dart`, `lib/src/agent/agent_profile_store.dart`, `lib/src/agent/agent_send.dart`, `lib/src/agent/agent_settings.dart`, `lib/src/agent/agent_settings_store.dart`, `lib/src/agent/agent_sidecar.dart`, `lib/src/agent/agent_yaml.dart`, `lib/src/agent/bridge_connection.dart`, `lib/src/agent/chat_message.dart`, `lib/src/agent/chat_variable.dart`, `lib/src/agent/chat_variable_store.dart`, `lib/src/agent/editor_placeholder_bindings.dart`, `lib/src/agent/prompt_queue.dart`, `lib/src/agent/prompt_queue_store.dart`, `lib/src/agent/prompt_template.dart`, `lib/src/agent/prompt_template_store.dart`, `lib/src/agent/prompt_trail_store.dart`, `lib/src/agent/queue_template.dart`, `lib/src/agent/queue_template_store.dart`, `lib/src/agent/reconnect.dart`, `lib/src/agent/reminder_template.dart`, `lib/src/agent/reminder_template_store.dart`, `lib/src/agent/timed_request.dart`, `lib/src/agent/timed_request_store.dart`.

The module `lib/src/agent/` is barrelled by `agent.dart`, which re-exports 24
libraries.

Four layers, and the grouping below follows them:

- **The models** — the persisted domain objects, each with a `toYaml()` /
  `fromYaml()` pair and no behaviour beyond validation.
- **The stores** — one per model set, each resolving a YAML sidecar path and
  degrading rather than throwing on a damaged file.
- **The YAML plumbing** — the codec and the shared read-and-decode path every
  sidecar goes through.
- **The session layer** — bridge discovery and binding, the reconnect
  protocol, and the send engine.

`test/agent_api_summary_test.dart` derives the required set from the barrel and
fails on a symbol with no section here, so this document cannot fall behind the
code.

## The models

### AgentProfile

`final class`. A named persona supplying the system prompt and per-send
behaviour. Carries the `Options` overlay fields a send reads (model, turn cap,
thinking, prompt caching, tool approval) and `interruptRetryPrefix`, the text
prepended to a prompt re-sent after a reconnect. Its one public static is
`AgentProfile.defaultInterruptRetryPrefix`, the value seeded when a VS Code
profile is copied into the editor.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `allowInteractiveQuestions` | `final bool? allowInteractiveQuestions` |  |
| `autoInjectMemory` | `final bool? autoInjectMemory` |  |
| `configurationId` | `final String? configurationId` |  |
| `description` | `final String description` |  |
| `enabledTools` | `final List<String>? enabledTools` |  |
| `fromYaml` | `factory AgentProfile.fromYaml(Map<String, dynamic> yaml)` |  |
| `historyMode` | `final String? historyMode` |  |
| `id` | `final String id` |  |
| `interactiveQuestionsTemplateId` | `final String? interactiveQuestionsTemplateId` |  |
| `isDefault` | `final bool? isDefault` |  |
| `maxRounds` | `final int? maxRounds` |  |
| `maxTokens` | `final int? maxTokens` |  |
| `name` | `final String name` |  |
| `promptCachingEnabled` | `final bool? promptCachingEnabled` |  |
| `retryMaxTotalWaitMinutes` | `final int? retryMaxTotalWaitMinutes` |  |
| `systemPrompt` | `final String systemPrompt` |  |
| `thinkingBudgetTokens` | `final int? thinkingBudgetTokens` |  |
| `thinkingEnabled` | `final bool? thinkingEnabled` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |
| `toolApprovalMode` | `final ToolApprovalMode? toolApprovalMode` |  |
| `toolsEnabled` | `final bool? toolsEnabled` |  |
| `useBuiltInTools` | `final bool? useBuiltInTools` |  |
| `userPromptWrapper` | `final String? userPromptWrapper` |  |

### ToolApprovalMode

`enum`: `always`, `never`. The approval gate for write tool calls.
`ToolApprovalMode.fromValue` reads one back from its persisted token.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `value` | `final String value` |  |

### AgentSettings

`final class`. The global settings a profile overlays: the bridge target
(`bridgeHost`, `portScanStart`, `portScanEnd`), the profile selected on launch,
and defaults that apply where a profile leaves a field unset.
`AgentSendConfig.fromProfile` applies that overlay to `maxRounds` (the turn cap),
`toolApprovalMode` (the permission mode) and `thinkingEnabled` (the thinking
configuration). `maxTokens` and `promptCachingEnabled` are stored and edited but
not sent: the Agent SDK's `Options` has no field for them.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `copyWith` | `AgentSettings copyWith({ String? bridgeHost, int? portScanStart, int? portScanEnd, String? defaultProfileId, int? maxTokens, int? maxRounds, bool? thinkingEnabled, bool? promptCachingEnabled, ToolApprovalMode? toolApprovalMode})` |  |
| `defaultProfileId` | `final String? defaultProfileId` | Profile selected on launch; null = first available. |
| `fromYaml` | `factory AgentSettings.fromYaml(Map<String, dynamic> yaml)` |  |
| `hasValidPortRange` | `bool get hasValidPortRange` | Whether the port-scan range is well-formed (start ≤ end, both positive). |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |

### ChatRole

`enum`: `user`, `assistant`, `system`, `tool`. Who authored a message.
`ChatRole.fromValue` reads one back from its token.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `value` | `final String value` |  |

### ChatMessage

`final class`. A single message in a chat exchange: its role, its text, and
when it was made.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `createdAt` | `final String createdAt` |  |
| `fromYaml` | `factory ChatMessage.fromYaml(Map<String, dynamic> yaml)` |  |
| `id` | `final String id` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |
| `toolCallId` | `final String? toolCallId` | Tool-call correlation id when [role] is [ChatRole.tool]. |
| `toolName` | `final String? toolName` | Tool name when [role] is [ChatRole.tool]. |

### TrailPair

`final class`. One request/answer pair from an SDK exchange, as the trail
displays it.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `costUsd` | `final double? costUsd` |  |
| `createdAt` | `final String createdAt` |  |
| `fromYaml` | `factory TrailPair.fromYaml(Map<String, dynamic> yaml)` |  |
| `id` | `final String id` |  |
| `modelId` | `final String? modelId` |  |
| `providerId` | `final String? providerId` |  |
| `summaryMarkdown` | `final String? summaryMarkdown` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |
| `tokensIn` | `final int? tokensIn` |  |
| `tokensOut` | `final int? tokensOut` |  |

### ChatVariable

`final class`. One placeholder binding, identified by `name`.
`ChatVariable.bindingsOf` turns a list of them into the `name → value` map the
placeholder resolver takes, which is the only shape a caller needs.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `builtIn` | `final bool builtIn` | Whether this is a composer-supplied built-in (read-only in the editor) rather than a user-authored variable. |
| `description` | `final String description` | Optional human-readable note shown in the chat-variables editor. |
| `fromYaml` | `factory ChatVariable.fromYaml(Map<String, dynamic> yaml)` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |

### QueuedPrompt

`final class`. A prompt queued for dispatch, with its optional pre-prompts,
follow-ups, transport and repeat settings. Identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `answerText` | `final String? answerText` |  |
| `answerWaitMinutes` | `final int? answerWaitMinutes` |  |
| `answerWrapper` | `final bool? answerWrapper` |  |
| `anthropicConfigId` | `final String? anthropicConfigId` |  |
| `anthropicProfileId` | `final String? anthropicProfileId` |  |
| `createdAt` | `final String createdAt` |  |
| `error` | `final String? error` |  |
| `expandedText` | `final String expandedText` |  |
| `expectedRequestId` | `final String? expectedRequestId` |  |
| `followUpIndex` | `final int? followUpIndex` |  |
| `followUps` | `final List<QueuedFollowUpPrompt>? followUps` |  |
| `fromYaml` | `factory QueuedPrompt.fromYaml(Map<String, dynamic> yaml)` |  |
| `lastReminderAt` | `final String? lastReminderAt` |  |
| `originalText` | `final String originalText` |  |
| `prePrompts` | `final List<QueuedPrePrompt>? prePrompts` |  |
| `reminderEnabled` | `final bool? reminderEnabled` |  |
| `reminderQueued` | `final bool? reminderQueued` |  |
| `reminderRepeat` | `final bool? reminderRepeat` |  |
| `reminderSentCount` | `final int? reminderSentCount` |  |
| `reminderTemplateId` | `final String? reminderTemplateId` |  |
| `reminderTimeoutMinutes` | `final int? reminderTimeoutMinutes` |  |
| `repeatCount` | `final Object? repeatCount` |  |
| `repeatIndex` | `final int? repeatIndex` |  |
| `repeatPrefix` | `final String? repeatPrefix` |  |
| `repeatSuffix` | `final String? repeatSuffix` |  |
| `requestId` | `final String? requestId` |  |
| `resolvedRepeatCount` | `final int? resolvedRepeatCount` |  |
| `sentAt` | `final String? sentAt` |  |
| `status` | `final QueuedPromptStatus status` |  |
| `template` | `final String template` |  |
| `templateRepeatCount` | `final Object? templateRepeatCount` |  |
| `templateRepeatIndex` | `final int? templateRepeatIndex` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |
| `type` | `final QueuedPromptType type` |  |

### QueuedPrePrompt

`final class`. A prompt sent *ahead* of a queue item's main prompt. Keyed by
its `text` rather than by an id — a pre-prompt is identified by its body.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `answerText` | `final String? answerText` |  |
| `answerWaitMinutes` | `final int? answerWaitMinutes` |  |
| `anthropicConfigId` | `final String? anthropicConfigId` |  |
| `anthropicProfileId` | `final String? anthropicProfileId` |  |
| `fromYaml` | `factory QueuedPrePrompt.fromYaml( Map<String, dynamic> yaml)` |  |
| `reminderEnabled` | `final bool? reminderEnabled` |  |
| `reminderRepeat` | `final bool? reminderRepeat` |  |
| `reminderTemplateId` | `final String? reminderTemplateId` |  |
| `reminderTimeoutMinutes` | `final int? reminderTimeoutMinutes` |  |
| `repeatCount` | `final Object? repeatCount` |  |
| `repeatIndex` | `final int? repeatIndex` |  |
| `resolvedRepeatCount` | `final int? resolvedRepeatCount` |  |
| `status` | `final QueuedPrePromptStatus status` |  |
| `template` | `final String? template` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |
| `transport` | `final QueuedTransport? transport` |  |

### QueuedFollowUpPrompt

`final class`. A prompt sent *after* the main prompt is answered. Keyed by
`id`. Both it and `QueuedPrePrompt` carry `answerWaitMinutes`; the field sets
otherwise differ, so neither is a subset of the other.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `answerText` | `final String? answerText` |  |
| `anthropicConfigId` | `final String? anthropicConfigId` |  |
| `anthropicProfileId` | `final String? anthropicProfileId` |  |
| `createdAt` | `final String createdAt` |  |
| `fromYaml` | `factory QueuedFollowUpPrompt.fromYaml(Map<String, dynamic> yaml)` |  |
| `originalText` | `final String originalText` |  |
| `reminderEnabled` | `final bool? reminderEnabled` |  |
| `reminderRepeat` | `final bool? reminderRepeat` |  |
| `reminderTemplateId` | `final String? reminderTemplateId` |  |
| `reminderTimeoutMinutes` | `final int? reminderTimeoutMinutes` |  |
| `repeatCount` | `final Object? repeatCount` | Literal count or chat-variable name (`number \| string` in the source). |
| `repeatIndex` | `final int? repeatIndex` |  |
| `resolvedRepeatCount` | `final int? resolvedRepeatCount` |  |
| `template` | `final String? template` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |
| `transport` | `final QueuedTransport? transport` |  |

### QueuedPromptStatus

`enum`: `staged`, `pending`, `sending`, `sent`, `error`. The lifecycle of a
queued prompt. `QueuedPromptStatus.fromValue` reads one back.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `value` | `final String value` |  |

### QueuedPrePromptStatus

`enum`: `pending`, `sent`, `error` — deliberately narrower than the main
prompt's set, because a pre-prompt is never staged or in a sending state of its
own.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromValue` | `static QueuedPrePromptStatus fromValue(String? value)` |  |
| `value` | `final String value` |  |

### QueuedPromptType

`enum`: `normal`, `timed`, `reminder`. What kind of queued prompt this is.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromValue` | `static QueuedPromptType fromValue(String? value)` |  |
| `value` | `final String value` |  |

### QueuedTransport

`enum`: `copilot`, `anthropic`. Which backend the item dispatches through; an
item without one follows the default.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromValue` | `static QueuedTransport? fromValue(String? value)` |  |
| `value` | `final String value` |  |

### PromptTemplate

`final class`. A reusable prompt body, identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromYaml` | `factory PromptTemplate.fromYaml(Map<String, dynamic> yaml)` |  |
| `isUserMessage` | `final bool isUserMessage` | Whether this template seeds the composer's user-message field (vs. |
| `name` | `final String name` | Human-readable label shown in the prompt-templates editor. |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |

### QueueTemplate

`final class`. A named, ordered set of prompt bodies, identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromYaml` | `factory QueueTemplate.fromYaml(Map<String, dynamic> yaml)` |  |
| `name` | `final String name` | Human-readable label. |
| `prompts` | `final List<String> prompts` | The ordered prompt bodies applied to the queue, head first. |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |

### ReminderTemplate

`final class`. A reusable reminder body, identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromYaml` | `factory ReminderTemplate.fromYaml(Map<String, dynamic> yaml)` |  |
| `isDefault` | `final bool isDefault` | Whether this is the fallback template when none is selected. |
| `name` | `final String name` | Human-readable label shown in editors. |
| `prompt` | `final String prompt` | Template body using `{{token}}` mustache syntax (see the extension's `REMINDER_PLACEHOLDER_HELP` for the supported token set). |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |

### TimedRequest

`final class`. A timed or repeating prompt entry: its schedule, its status and
its body. `id`, `originalText` and **`scheduleMode` are required** — the mode
is not defaulted, so a caller has to say whether the entry repeats on an
interval or at fixed times rather than discovering which it got.
`intervalMinutes` and `scheduledTimes` are both nullable, because each belongs
to one mode and neither is meaningful under the other.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `answerWrapper` | `final bool? answerWrapper` |  |
| `enabled` | `final bool enabled` |  |
| `fromYaml` | `factory TimedRequest.fromYaml(Map<String, dynamic> yaml)` | Reads a request from a persisted mapping. |
| `lastSentAt` | `final String? lastSentAt` |  |
| `reminderEnabled` | `final bool? reminderEnabled` |  |
| `reminderRepeat` | `final bool? reminderRepeat` |  |
| `reminderTemplateId` | `final String? reminderTemplateId` |  |
| `reminderTimeoutMinutes` | `final int? reminderTimeoutMinutes` |  |
| `template` | `final String template` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |

### ScheduleMode

`enum`: `interval`, `scheduled`. How a timed request fires.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromValue` | `static ScheduleMode fromValue(String? value)` |  |
| `value` | `final String value` |  |

### TimedRequestStatus

`enum`: `active`, `paused`, `completed`. The lifecycle of a timed entry.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromValue` | `static TimedRequestStatus fromValue(String? value)` |  |
| `value` | `final String value` |  |

### ScheduledTime

`final class`. One scheduled slot. A bare `time` repeats daily; adding a `date`
makes it a one-shot.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `fromYaml` | `factory ScheduledTime.fromYaml(Map<String, dynamic> yaml)` |  |
| `toYaml` | `Map<String, dynamic> toYaml() => <String, dynamic>` |  |

## The stores

Each is constructed with a `File`, and each carries a `resolveDefault()`
factory that honours an environment override and otherwise falls back to a
fixed name under `<cwd>/.tom/`. The paths and overrides are tabulated in
[`doc/agent.md`](../agent.md#the-sidecar-stores); `load()` never throws.

### AgentProfileStore

Loads and saves `List<AgentProfile>` under the `profiles` key, identified by
`id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `List<AgentProfile> load()` | Loads the persisted profiles, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory AgentProfileStore.resolveDefault()` | Resolves the profiles file. |
| `save` | `void save(List<AgentProfile> profiles)` | Persists [profiles], creating the parent directory if needed. |

### AgentSettingsStore

Loads and saves the singleton `AgentSettings` under the `settings` key. Being a
singleton it falls back to defaults rather than skipping, since there is
nothing to skip to.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `AgentSettings load()` | Loads the persisted settings, or the defaults when the file is missing, unreadable, malformed or shaped unlike [AgentSettings]. |
| `resolveDefault` | `factory AgentSettingsStore.resolveDefault()` | Resolves the agent-settings file. |
| `save` | `void save(AgentSettings settings)` | Persists [settings], creating the parent directory if needed. |

### ChatVariableStore

Loads and saves `List<ChatVariable>` under `variables`, identified by `name` —
the one store whose identity field is not `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `List<ChatVariable> load()` | Loads the persisted variables, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory ChatVariableStore.resolveDefault()` | Resolves the chat-variables file. |
| `save` | `void save(List<ChatVariable> variables)` | Persists [variables], creating the parent directory if needed. |

### PromptQueueStore

Loads and saves `List<QueuedPrompt>` under `items`, identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `List<QueuedPrompt> load()` | Loads the persisted queue, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory PromptQueueStore.resolveDefault()` | Resolves the queue file. |
| `save` | `void save(List<QueuedPrompt> queue)` | Persists [queue], creating the parent directory if needed. |

### PromptTemplateStore

Loads and saves `List<PromptTemplate>` under `templates`, identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `List<PromptTemplate> load()` | Loads the persisted templates, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory PromptTemplateStore.resolveDefault()` | Resolves the prompt-templates file. |
| `save` | `void save(List<PromptTemplate> templates)` | Persists [templates], creating the parent directory if needed. |

### QueueTemplateStore

Loads and saves `List<QueueTemplate>` under `templates`, identified by `id` —
the same key as the prompt templates, in a different file.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `load` | `List<QueueTemplate> load()` | Loads the persisted templates, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory QueueTemplateStore.resolveDefault()` | Resolves the queue-templates file. |
| `save` | `void save(List<QueueTemplate> templates)` | Persists [templates], creating the parent directory if needed. |

### TimedRequestStore

Loads and saves `List<TimedRequest>` under `requests`, identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `List<TimedRequest> load()` | Loads the persisted requests, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory TimedRequestStore.resolveDefault()` | Resolves the timed-requests file. |
| `save` | `void save(List<TimedRequest> requests)` | Persists [requests], creating the parent directory if needed. |

### PromptTrailStore

Loads and saves `List<TrailPair>` under `pairs`, identified by `id`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `List<TrailPair> load()` | Loads the persisted trail, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory PromptTrailStore.resolveDefault()` | Resolves the trail file. |
| `save` | `void save(List<TrailPair> trail)` | Persists [trail], creating the parent directory if needed. |

### ReminderTemplateStore

Loads and saves `List<ReminderTemplate>` under `templates`, identified by `id`.
The store that makes `QueuedPrompt.reminderTemplateId` and
`TimedRequest.reminderTemplateId` resolvable — both of those models are
themselves persisted, so without it a restored queue named a body nothing could
find.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `file` | `final File file` | The backing YAML file. |
| `load` | `List<ReminderTemplate> load()` | Loads the persisted templates, or an empty list when the file is missing, unreadable or malformed. |
| `resolveDefault` | `factory ReminderTemplateStore.resolveDefault()` | Resolves the reminder-templates file. |
| `save` | `void save(List<ReminderTemplate> templates)` | Persists [templates], creating the parent directory if needed. |

### SpecSessionStore

The per-specification SDK session id. The one sidecar holding a bare scalar
(`sessionId`) rather than a model, so it reads the shared file loader directly.
`load()` answers `null` for an absent or empty id as well as for a damaged
file; `save` persists; `clear` forgets, which is what a session error triggers.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resolveDefault` | `factory SpecSessionStore.resolveDefault()` | Resolves the sidecar location. |

### BridgeChoiceStore

The persisted binding. `load()` answers `null` when the file cannot supply one,
`save` writes it, and `clear` removes the file — an explicit unbind.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resolveDefault` | `factory BridgeChoiceStore.resolveDefault()` | Resolves the sidecar location. |

## The YAML plumbing

### readAgentYamlFile

```dart
Map<String, dynamic>? readAgentYamlFile(File file)
```

Reads and parses one sidecar, answering `null` for missing, empty, unreadable
and malformed alike. The four collapse into one result on purpose: to a caller
about to fall back on its defaults, a file it cannot use and a file that is not
there are the same file.

### decodeAgentYamlList

```dart
List<T> decodeAgentYamlList<T>(
  Map<String, dynamic>? root, {
  required String key,
  required String identity,
  required T Function(Map<String, dynamic>) fromYaml,
})
```

Builds the models under `key`, skipping an entry that is not a mapping, whose
`identity` field is not a non-empty string, or whose `fromYaml` throws. Skips
per entry rather than failing the load, so one bad row costs one row.

### decodeAgentYamlValue

```dart
T decodeAgentYamlValue<T>(
  Map<String, dynamic>? root, {
  required String key,
  required T Function(Map<String, dynamic>) fromYaml,
  required T orElse,
})
```

The singleton counterpart. With nothing to skip *to*, an unusable value falls
back to `orElse`.

### decodeAgentYamlEntries

Builds a list of models from a raw value, with the identity requirement
optional — which is what separates a store's top-level list from a nested list
inside one entry.

### encodeAgentYaml

```dart
String encodeAgentYaml(Map<String, dynamic> data)
```

Serialises to a YAML document through `yaml_edit`: stable key order, block
style.

### decodeAgentYaml

```dart
Map<String, dynamic> decodeAgentYaml(String yaml)
```

Parses a document into a plain map. **Throws** `FormatException` when the root
is not a mapping — the one function here that throws, which is why
`readAgentYamlFile` wraps it.

### deepPlainYaml

Recursively converts a parsed `YamlMap` / `YamlList` tree into plain Dart
collections, coercing map keys to `String`, so a model's `fromYaml` never sees
a YAML view type.

### yamlValue

```dart
T? yamlValue<T>(Map<String, dynamic> yaml, String key)
```

Reads `key` when it holds a `T`, and `null` when it does not — whether absent or
present with the wrong type. Type-testing rather than casting is what stops a
hand-edited `name: 7` from throwing past a store's catch.

### yamlStringList

The list counterpart: a `List<String>` when every element is one, `null`
otherwise.

### yamlEnum

Reads an enum by its persisted token, answering `null` for a token the enum
does not define.

## Bridge discovery and binding

### BridgeServer

One responsive VS Code bridge: its `port`, its `host`, the `workspace` its
window reported through the identity handshake, and its `status`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `copyWith` | `BridgeServer copyWith({BridgeServerStatus? status})` |  |

### BridgeServerStatus

`enum`: `available`, `bound`. How a discovered server relates to the editor
right now. Every scan result is `available`; binding is the caller's concern.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `token` | `final String token` | Stable token for display / persistence. |

### BridgePortScanner

```dart
typedef BridgePortScanner =
    Future<Map<int, String>> Function({
      required String host,
      required int minPort,
      required int maxPort,
    });
```

The injected scan seam, so a test supplies fake bridges without opening a
socket.

### BridgeConnectionService

Scans the port range and returns the responsive servers in ascending port
order. Takes the host, the range and the scanner, all defaulted.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `maxPort` | `final int maxPort` | Last port scanned (inclusive). |
| `minPort` | `final int minPort` | First port scanned (inclusive). |
| `scan` | `Future<List<BridgeServer>> scan() async` | Scans the port range and returns the responsive servers in ascending port order. |

### BridgeChoice

The persisted binding — `host` and `port`, nothing else. `fromMap` type-tests
both fields and defaults either it cannot use. `matches(BridgeServer)` is the
comparison that matters: equal port, and a host naming the same *endpoint*,
which is weaker than the same string. Deliberately not folded into
`operator ==`, which is value equality on the record that was persisted.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toMap` | `Map<String, Object?> toMap() =>` |  |

### connectAgentSdkClient

```dart
Future<AgentSdkClient> connectAgentSdkClient({
  required String host,
  required int port,
})
```

The production `AgentSdkClientFactory`: opens a bridge socket and wraps it in
the bridge-backed transport. **Throws** `StateError` when the socket does not
come up, so a caller can surface a connect failure.

### AgentSdkClientFactory

```dart
typedef AgentSdkClientFactory =
    Future<AgentSdkClient> Function({required String host, required int port});
```

The transport seam. It lives in this pure-Dart layer rather than in the Flutter
controller so the UI hands down a factory (or a fake) and stays
transport-agnostic.

## Reconnect

### ReconnectCoordinator

Runs the back-off: after each delay it rescans and, the first time the bound
endpoint answers, classifies the result. Takes an injectable
`BridgeConnectionService`, the back-off list, and a `ReconnectDelay`.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `backoff` | `final List<Duration> backoff` | The per-attempt back-off durations. |
| `reconnect` | `Future<ReconnectResult> reconnect({ required BridgeChoice bound, String? boundWorkspace}) async` | Attempts to recover the connection to [bound], whose window served [boundWorkspace] when it was bound. |
| `service` | `final BridgeConnectionService service` | The scan service used to rediscover the bound port. |

### ReconnectResult

The outcome: the `resolution`, the `server` found (`null` when still gone), and
`attempts` — 1-based for a server that came back, the full schedule length when
it did not.

### ReconnectResolution

`enum`: `sameWorkspace`, `differentWorkspace`, `stillGone`.

### ReconnectDelay

```dart
typedef ReconnectDelay = Future<void> Function(Duration duration);
```

The delay seam, so a test runs the protocol instantly instead of waiting the
real schedule.

### composeInterruptRetry

```dart
String composeInterruptRetry(String prefix, String prompt)
```

Composes the auto-resend body: the prefix, a blank line, then the prompt. An
empty prefix yields the prompt unchanged, and composition never stacks —
repeated drops re-send one prefix because the *original* prompt is what is
composed each time.

## The send engine

### AgentSendEngine

Wraps one connected client, one `SpecSessionStore` and one `AgentSendConfig`.
`send(prompt, {cancelToken})` is a **cold** stream: each listen runs one query.
It retries once with a fresh session under four conditions together, and ends
**silently** on cancellation — no terminal event at all.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `config` | `final AgentSendConfig config` | The assembled `Options` inputs. |
| `sessionStore` | `final SpecSessionStore sessionStore` | The per-spec session id sidecar. |

### AgentSendConfig

The editor-assembled inputs to one `query` `Options`, minus the session id the
engine supplies: model, system prompt (sent additively, never as an override),
permission mode, turn cap, thinking configuration, working directory, and the
MCP servers. `fromProfile(profile, settings: ...)` overlays the profile on
`AgentSettings`: for the turn cap, the permission mode and thinking, an explicit
argument wins, then the profile's field, then the settings'.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `buildOptions` | `Options buildOptions({String? resumeSessionId})` | Builds the SDK [Options] for one `query`, with [resumeSessionId] threaded into `resume` (omitted from the wire when `null`, so a fresh session is started). |
| `cwd` | `final String? cwd` | The agent working directory — the document/spec folder, or `null`. |
| `maxTurns` | `final int? maxTurns` | Claude Code's agentic-loop turn cap, or `null` for the SDK default. |
| `mcpServers` | `final Map<String, McpServerConfig>? mcpServers` | The navigation/mutation MCP servers, or `null` when none are wired. |
| `permissionMode` | `final PermissionMode? permissionMode` | Permission posture for Claude Code's tool loop, or `null` for the default. |
| `systemPrompt` | `final String? systemPrompt` | The profile's system prompt, sent as an additive [SystemPromptText] (never an override — Claude Code's own system prompt stays in place). |
| `thinking` | `final ThinkingConfig? thinking` | Extended-thinking configuration, or `null` for the SDK default. |

### AgentSendEvent

`sealed class`. One step of a send run, so a consumer can switch exhaustively.

### AgentSendStarted

Emitted once, first.

### AgentSendChunk

A streamed chunk of assistant answer text, in order. Only `TextBlock` content
becomes one — thinking and tool blocks are not answer text.

### AgentSendSessionRefreshed

Emitted when a session error caused the stored id to be dropped, immediately
before the retried attempt's chunks.

### AgentSendCompleted

Terminal success, carrying the session id of the completed turn (or `null` when
the result carried none).

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `sessionId` | `final String? sessionId` | The Claude-Code session id of the completed turn, persisted for resume, or `null` if the result carried none. |

### AgentSendFailed

Terminal failure: a non-session error, an error that failed one of the four
retry conditions, or a stream that ended with no result message.

### specSessionLooksLikeError

```dart
bool specSessionLooksLikeError(String message)
```

The editor's session-error rule: the text contains `session`, `message` or
`msg`, case-insensitively. Deliberately broader than the brain's matcher — the
editor would rather refresh a per-spec session id once too often than leave a
stale one wedged in place.

### permissionModeForApproval

```dart
PermissionMode permissionModeForApproval(ToolApprovalMode mode)
```

The SDK permission mode a tool-approval setting asks for: `always` is the SDK's
default mode, which prompts for dangerous operations; `never` is `acceptEdits`,
which auto-accepts file edits — not `bypassPermissions`, which would turn every
check off.

### thinkingConfigFor

```dart
ThinkingConfig? thinkingConfigFor(bool? enabled, {int? budgetTokens})
```

The SDK thinking configuration a profile's thinking settings ask for: `false`
is `ThinkingDisabled`; `true` with a budget is `ThinkingEnabled` with that
budget; `true` without one is `ThinkingAdaptive`, which lets the model decide;
`null` sends nothing and leaves the SDK default.

## Placeholders

### EditorPlaceholderBindings

Resolves the editor's supported placeholder forms — `${name}`, `{{name}}`,
`${env:NAME}` — against a fixed set of bindings, through the package's own
placeholder engine. It does no I/O: the reserved `${file:…}` and `${state:…}`
forms pass through verbatim, and a caller that wants a file's contents or a
workspace path in a template passes the value in as a binding.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resolve` | `String resolve(String template)` | Expands the supported placeholder forms in [template]. |
| `strict` | `final bool strict` | When true, an unknown `${name}` / `${env:NAME}` throws instead of rendering empty. |

### PlaceholderExpressionsUnsupportedError

`final class`. Thrown when a template carries the `${{ … }}` expression form.
The refusal is a decision rather than a gap: an editor has no evaluator, and
refusing before the mustache pass is what stops an expression being quietly
rewritten into something resolvable.

## Constants

### defaultBridgeHost

`'127.0.0.1'` — the host every bridge default in the package points at, named
once so the defaults cannot diverge.

### bridgeScanMinPort

The lowest port scanned, inclusive: 19900, taken from the transport package's
own constant.

### bridgeScanMaxPort

The highest port scanned, inclusive: 19909.

### defaultReconnectBackoff

`[10 s, 30 s, 60 s]` — the default reconnect schedule.

## Global Functions and Constants

| Name | Declaration | Description |
| ---- | ----------- | ----------- |
| `composeInterruptRetry` | `String composeInterruptRetry(String prefix, String prompt)` | Composes the auto-resend body for an interrupted prompt: the active profile's [prefix] followed by the original [prompt]. |
| `connectAgentSdkClient` | `Future<AgentSdkClient> connectAgentSdkClient({ required String host, required int port}) async` | The production [AgentSdkClientFactory]: opens a [VSCodeBridgeClient] socket and wraps it in the bridge-backed transport. |
| `decodeAgentYaml` | `Map<String, dynamic> decodeAgentYaml(String yaml)` | Parses a YAML document [yaml] into a plain `Map<String, dynamic>`. |
| `decodeAgentYamlEntries` | `List<T>? decodeAgentYamlEntries<T>( Object? node, T Function(Map<String, dynamic>) fromYaml, { String? identity})` | Builds models from the YAML list [node], skipping the elements it cannot build, or returns `null` when [node] is not a list at all. |
| `decodeAgentYamlList` | `List<T> decodeAgentYamlList<T>( Map<String, dynamic>? root, { required String key, required String identity, required T Function(Map<String, dynamic>) fromYaml})` | Builds the models in the list under [key] of [root], skipping the entries the file cannot supply. |
| `decodeAgentYamlValue` | `T decodeAgentYamlValue<T>( Map<String, dynamic>? root, { required String key, required T Function(Map<String, dynamic>) fromYaml, required T orElse})` | Builds the single model under [key] of [root], or [orElse] when the file cannot supply it. |
| `deepPlainYaml` | `Object? deepPlainYaml(Object? node)` | Recursively converts a parsed YAML tree ([YamlMap] / [YamlList] / scalar) into plain Dart collections. |
| `encodeAgentYaml` | `String encodeAgentYaml(Map<String, dynamic> data)` | Serialises [data] to a YAML document string. |
| `permissionModeForApproval` | `PermissionMode permissionModeForApproval(ToolApprovalMode mode)` | The SDK permission mode a [ToolApprovalMode] asks for. |
| `readAgentYamlFile` | `Map<String, dynamic>? readAgentYamlFile(File file)` | Reads and parses the sidecar at [file], or `null` when it is missing, empty, unreadable or malformed. |
| `specSessionLooksLikeError` | `bool specSessionLooksLikeError(String message)` | True when [message] should be treated as an SDK **session error** under the editor rule: its text contains `session`, `message`, or `msg` (case-insensitive). |
| `thinkingConfigFor` | `ThinkingConfig? thinkingConfigFor(bool? enabled, {int? budgetTokens})` | The SDK thinking configuration a profile's thinking settings ask for, or `null` when unset. |
| `yamlEnum` | `T? yamlEnum<T>( Map<String, dynamic> yaml, String key, T Function(String?) fromValue)` | Reads [key] as a string and maps it through [fromValue], or `null` when [key] holds no string. |
| `yamlStringList` | `List<String>? yamlStringList(Map<String, dynamic> yaml, String key)` | Reads [key] as a list of strings, keeping the elements that are strings, or `null` when [key] does not hold a list. |
| `yamlValue` | `T? yamlValue<T>(Map<String, dynamic> yaml, String key)` | Reads [key] from [yaml] when it holds a [T], and `null` when it does not — whether the key is absent or present with the wrong type. |

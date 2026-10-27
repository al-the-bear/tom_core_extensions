## 1.9.0

### Added

- **`agent_sdk.dart`: Anthropic's Claude Agent SDK as a `tom_llm` provider**,
  with `agent_sdk_live_probe.dart`, `agent_sdk_testing.dart`, the
  `install_agent_sdk_server` executable and the Node server under `node/`.
  Formerly the package `tom_core_agent_sdk`, which is deleted, with no
  re-export:

  - **Transports.** `AgentSdkServerTransport` with the hosted VS Code CLI server
    transport (port scan, identity handshake, workspace pin) and the standalone
    Node child transport (credential isolation, ready line, stderr on death).
  - **The channel.** `CliServerAiChannel` with the stall bound as a gap and
    401-retry detection, and `SdkTrailTranslator` from Agent SDK messages to
    `tom_llm` run events.
  - **Selection.** `AgentSdkTransportSelector` and the availability gate with a
    reason a program can branch on.
  - **Sessions.** `AgentSdkSessionProvider` and one isolate per session.
  - **The server.** `agent_sdk_server.js`, its on-demand install
    (`install_agent_sdk_server`) and payload verification.
  - **Live probe.** `live_probe.dart`; test doubles in `testing.dart`.

- **`agent_tools.dart`: the tool surface for LLM agents.** Formerly the
  package `tom_core_agent_tools`, which is deleted, with no re-export:

  - **Tools.** `AgentTool` with a validated argument schema, `AgentToolRegistry`
    with `where`, and `AgentToolContext` with the guard and the transaction
    hooks an application implements.
  - **Scope and consent.** `AgentScope` and the five-gate `agentGuard`;
    `AgentInvocation` with execution granted only against an
    `AgentExecutionGrant` statement.
  - **Audit.** `AgentAuditEntry`, `AgentAuditLog`, `AgentMemoryAuditLog` and
    `AgentFileAuditLog` over an `AgentAuditStore`; the per-call
    `AgentAuditRecording`.
  - **Presentations.** `AgentToolBinding` (an `LlmToolBinding`) and
    `AgentInProcessMcpServer`.
  - **Runs.** `AgentRun` with its dry run, and `AgentPreviewThenApply`.

### Removed

- **Breaking: the cancellation token and the YAML config writer.**
  `CancellationToken`, `CancellationTokenSource`, `OperationCancelled` and
  `YamlConfigWriter` are gone from the barrel, with no re-export. Use
  `tom_basics`' `TomCancellationToken`, `TomCancellationSource`,
  `TomOperationCancelled` and `TomYamlConfigWriter`
  (`package:tom_basics/utilities.dart`, tom_basics 3.3.0). The shared token
  also carries a reason: `cancel([reason])`, and `whenCancelled` completes
  with it. `AgentSend.send`'s `cancelToken` is a `TomCancellationToken`.

### Changed

- The Dart SDK floor is 3.10.8, and `tom_vscode_scripting_api` is taken from
  pub.dev (`^2.0.0`).
- **Breaking: the Agent SDK and agent tool classes are `final`**, under the
  package's class-modifier rule; none was subclassed or implemented anywhere.
- **`promptSha256`** is `'sha256:'` + `tom_basics`' `tomSha256OfText`; the
  digest is unchanged. `crypto` moves to `dev_dependencies` (the test checks
  the digest against it independently), and the `tom_basics` floor is 3.3.0.

### Tests

- **`test/ai_citation_test.dart`** fails the suite when an artefact of the
  package cites a document in the AI-state mount. It runs
  `tom_ai/core/tool/check_doc_ai_citations.py` over the package through
  `tom_ai/core/tool/package_gate.dart`; the rule and its one exemption (the
  runtime `_ai/trail/` directory) are stated in the checker alone.
- **`test/formatting_test.dart`** fails the suite when a Dart file the
  package authors is not `dart format`-clean. It states the package's file
  floor, landmark directories and generated output, and delegates the
  sweep to `tom_ai/core/tool/package_format_guard.dart`, which every
  package under `tom_ai/core` shares.

### Changed

- **The provider contract is `tom_llm`'s.** `LlmProvider`, `WirePrompt`,
  `LlmOptions`, `LlmCallReport`, `CapturedWirePrompt`, the tool types and the
  `LlmStream*` events are deleted here; the one contract the workspace has —
  `LlmProvider.run(LlmRequest)` as a stream of `LlmEvent`s, `complete` derived
  from it — lives in `tom_llm`, which this package depends on and its
  barrel re-exports. `AgentSdkLlmProvider` extends it: it implements `run`
  (`LlmRunStarted` naming purpose, provider, model and call; `LlmTextDelta`;
  `LlmRunCompleted` or `LlmRunFailed`, each naming the call), and through the
  derived `complete` a failure is an `LlmTransportException` of kind `remote`
  carrying the SDK's error as its cause. `LlmOptions.brainSessionId` is
  `LlmOptions.sessionId`, which `BrainSessionStrategy` keys on. The value-type
  tests moved with the types.

- **`thinkingEnabled` reaches the Agent SDK** as its thinking configuration,
  through the new `thinkingConfigFor`: `false` is `ThinkingDisabled`, `true`
  is `ThinkingEnabled` with the profile's `thinkingBudgetTokens` when it sets
  one and `ThinkingAdaptive` when it does not, and an unset value sends
  nothing. `AgentSendConfig` carries it as `thinking`, overlaid like the turn
  cap and the permission mode — an explicit argument, then the profile, then
  `AgentSettings`. `Options.thinking` exists in every `tom_vscode_scripting_api`
  release the package accepts, so it was never a field with no destination.
  `maxTokens` and `promptCachingEnabled` still have none and are still not sent.
- **No public class in the package is left without a modifier.** The 29 that
  carried none — the eleven `*Store` classes, the bridge and reconnect services,
  `AgentSendEngine` and `AgentSendConfig`, the value types, the two
  exceptions, `AsyncShutdownCoordinator` and `CancellationTokenSource` — are
  closed, as the rest of the package already was. Nothing in the workspace
  extends, implements or mixes in any of them. The five `AgentSendEvent`
  leaves are now `final class`, so the package's two sealed event hierarchies
  agree with `LlmStreamEvent`'s. `BridgeConnectionService` is varied through
  its injected `BridgePortScanner`, which is its documented seam; the
  reconnect tests use it instead of subclassing the service.
- **`EditorPlaceholderBindings` states its limits as decisions.** The
  library comment deferred file injection and workspace wiring to "later
  steps" and named capability tiers that exist nowhere. It now says what the
  binder does: one capability level, no I/O, with reserved `${file:…}` /
  `${state:…}` forms passing through verbatim and file or workspace values
  supplied by the caller as bindings. A test holds the pass-through.
- **Quest mode pays for a stale session once.** `QuestSessionStrategy.evict`
  remembers the rejected id in memory, and `resumeIdFor` no longer offers it
  while the editor's file still names it, so every later call starts fresh
  instead of failing a resume first. The file is still never written; a new id
  in it is resumed. The constructor is no longer `const`.
- **A guarded request that times out can cancel the work it abandons.**
  `IsolateRequestGuard.guard` takes an optional `cancellation` token and
  `cancel` callback (both or neither); on a deadline it fails the caller, then
  calls `cancel(token)` once so the host can send its cancel envelope. A
  completed request and a worker death never call it.
- **A profile's tool-approval mode reaches the Agent SDK**, as a permission
  mode: `always` is the SDK default (prompt for dangerous operations), `never`
  is `acceptEdits` (`permissionModeForApproval`).
- **`AgentSendConfig.fromProfile` takes `settings:` and applies the overlay
  `AgentSettings` documented**: for the turn cap and the permission mode an
  explicit argument wins, then the profile's field, then the settings'.
- **`maxTokens`, `thinkingEnabled` and `promptCachingEnabled` say what they do
  not do.** The Agent SDK's `Options` has no field for any of them, so they
  are stored and edited but not sent; `AgentSettings.maxTokens` no longer names
  an `Options.maxTokens` that does not exist.

### Fixed

- **The README's `dart:io` coupling figures were wrong, and are now derived
  (tcopen354).** It said "Fourteen files under `lib/` import `dart:io`" where
  there are 15 — the tenth sidecar store added an importer and only the test's
  pinned set was updated. Its `src/agent/agent.dart` row was wrong twice over:
  eleven file-backed stores where nine import `dart:io`, and no mention that
  the export also reaches `placeholder_resolver.dart` through the editor
  placeholder bindings.

  The section now states 15 direct importers, 5 of 36 coupled exports, 31
  clean, and a per-row reach count — and `test/dart_io_coupling_test.dart`
  reads the section and fails when any figure stops matching the import graph.
  The sets were already pinned; the prose about them was the half nothing
  checked, which is exactly how it drifted.

### Added

- **The shared-stack constructor parameter is covered (tcopen353).**
  `PlaceholderResolver`'s `stack` is what lets two resolvers share a namespace —
  the shape `placeholder_stack.dart`'s header describes, nested frames resolving
  against one set of bindings — and every construction in the package took the
  default, so a regression that dropped the parameter and always allocated a
  fresh stack would have passed the suite.

  Five cases: the resolver holds the caller's object rather than a copy; a
  binding made *after* construction reaches it; two resolvers over one stack
  read each other's bindings while keeping their own environment and mode;
  `push` and `pop` move both together; and, as the control, two resolvers left
  to default do **not** share. The control earns its place — without it every
  other assertion would also pass against one process-wide stack, which is the
  opposite defect and the worse one.

  `example/placeholders/placeholders_example.dart` gained an act showing the
  shape, since a parameter nothing demonstrates is a parameter nobody uses.

### Changed

- **The placeholder re-scan is documented as a trust boundary (tcopen352).**
  Both entry points loop while resolvable placeholders remain, so a substituted
  value is scanned again whatever form produced it — and what it can reference
  is every namespace the resolver has. Only the binding-to-binding half of that
  was ever stated, as the composition feature it is.

  All six source/namespace pairs were probed and behave identically: a binding
  value may reference the environment, an environment value may reference a
  binding, an expression result is text like any other, and `${name?}` differs
  only in the unbound case. A reserved `${file:…}` / `${state:…}` form is the
  one exemption, and not really an exception — it is never substituted at any
  level, so a value that looks like one survives verbatim.

  The source header, `doc/placeholders.md` and the API summary now say what is
  re-scanned, what it means for text arriving from outside the program, and the
  isolation available today: an empty `environment` over a fresh stack, in
  strict mode, refuses an unknown reference instead of rendering it away. Nine
  cases in `test/placeholder_resolver_test.dart` pin it.

  **The behaviour was not changed**, and special-casing the environment was
  rejected rather than deferred: it would leave binding-to-binding injection
  untouched while making the rule non-uniform, so it would not close the
  surface it was aimed at.

### Fixed

- **`api_summary_placeholders.md` stated a constructor signature
  `PlaceholderResolver` does not have.** It gave the class a
  `required PlaceholderStack stack` and a non-nullable `environment`. Every
  parameter is optional: `stack` defaults to a fresh standalone
  `PlaceholderStack` and `environment` to `Platform.environment`, so
  `PlaceholderResolver()` is a working strict resolver over its own empty scope.
  The page now says so, and says that both nullable parameters become
  non-nullable fields.

### Added

- **`doc/api/api_summary_placeholders.md` (tcopen349).** Six types, one function
  and three constants with a section each: the four placeholder forms and the
  two entry points, the lexical scope chain, the expression seam, and the three
  wire-coded failures.

### Changed

- **The summary threshold counts members, not types.** A unit earns a
  symbol-level summary at ten exported public *members*. Counting types put
  `placeholders` on the wrong side of the line — 6 types against
  `isolate_streaming`'s 12, but 35 members against its 47, which is also where
  its 647 lines put it. `PlaceholderResolver` and `PlaceholderStack` carry
  seventeen members between them and a type count sees none of them.

  The member figure partitions the package more decisively too: 0, 5 | 35, 47,
  107, 344 has nothing near the line, where 3, 6 | 12, 20, 52 is a factor of
  two. `test/api_summary_test.dart` measures members by brace depth rather than
  by pattern — a member sits at depth 1 and everything in a method body is
  deeper — and also holds the index's own table to the measured counts, so the
  numbers the rule argues from cannot go stale.

  `tom_flutter_ui` keeps the threshold over types, for a reason its own index
  states: it is a widget catalogue where a type *is* the unit of surface.
  Whether the two should be unified is `tcextension57_aivw`.

### Fixed

- **Twelve broken markdown reference links in `doc/` (tcopen347).** Three on
  `bearer_auth.md` and nine on `isolate_streaming.md` were written as
  `` [`SomeType`] `` — dartdoc's square-bracket syntax in a markdown file,
  where it renders as literal brackets around a code span rather than as a
  link. None had an anchor to point at, so the brackets are gone and the code
  spans remain, which is what the surrounding prose does throughout both pages.

### Added

- **All three `BearerAuthFailureReason` categories now have a producer
  (tcopen346).** `malformed` had none, and the reason was structural rather
  than an oversight: every authenticator in the package was a map lookup, and a
  lookup has no parse step for that category to describe. So the one reason
  that distinguishes the taxonomy from a boolean accept/reject was the one an
  implementer had no reference for.

  `example/mcp_auth/mcp_auth_example.dart` now parses a JWT-shaped token —
  three dot-separated segments with base64url JSON claims in the middle, and no
  signature verification, which it says loudly — and demonstrates all four
  outcomes. `test/bearer_auth_test.dart` pins each category and closes on the
  one comparison the distinction rests on: two tokens naming a subject the
  authenticator knows, differing only in whether the envelope parses.

  `doc/bearer_auth.md` states the rule the reasons follow — *did the server
  learn who was claimed?* — and the three cases most easily got backwards: an
  expired token and a signature that fails verification are `rejected`, while
  claims that parse but carry no subject are `malformed`.

- **`doc/api/api_summary_index.md` states which units get a summary
  (tcopen344).** A unit earns one at ten exported public types. The rule
  partitions the package with no exception: `agent` (52), `llm` (20) and
  `isolate_streaming` (12) have summaries; `placeholders` (6), `bearer_auth`
  (3) and `mcp_auth` (0 types, two constants) are mirrored by their prose
  page's Overview table instead.

  `test/api_summary_test.dart` now holds the whole arrangement rather than only
  the summaries that happen to exist: it derives every unit from `lib/src/`,
  fails a unit at or over the threshold with no summary, holds a sub-threshold
  unit's `## Overview` to every exported type, function **and** constant, and
  requires the index to account for every unit and link no summary that is not
  there.

  That last part closes a hole. `tool/check_doc_overview_types.py` compares
  types and skips a unit that exports none — `mcp_auth` is named in its source
  as the reason — so the unit whose entire surface is two constants was the one
  no derived check read.

### Changed

- **The `bearerTokenMetaKey` naming guard is a closed rule, not a list.** It
  checked the key against four package names, which fails open: minting
  `tom_forge` and writing `tomForgeBearerToken` would have passed. The
  capitalised words in the key must now be exactly `Bearer` and `Token`, so a
  package name anywhere in it fails whether or not the test knows the package.

- **Two pointers to `test/agent_api_summary_test.dart`**, which was renamed to
  `test/api_summary_test.dart`, in `README.md` and `doc/agent.md`; and
  `doc/agent.md`'s exported-type count, which stayed at 51 when the tenth
  sidecar store added a type.

- **`WirePrompt.combined` no longer documents a migration (tcopen343).** Its
  dartdoc called `combined` the fallback used "transitionally [by] any provider
  until its native-channel mapping lands". There is no such mapping to wait
  for: routing `system` and `user` to native channels, or sending `combined`
  when the backend has none, is the choice itself, made once per provider. The
  clause is gone, and the getter now states the part it never had — that
  `promptHash` is the content hash of `combined` for *every* provider, sender
  or not, which makes the join part of the hash contract rather than of
  formatting. `LlmProvider`'s no-mutation rule had the same elision, telling
  implementers to translate `combined` where a channel-aware provider does not,
  and now names both routes.

- **The `agent` and `llm` module documents state their dependencies as the
  standard table.** Both had a prose list, which `check_module_dependencies.py`
  reported as a shape fault and which was also wrong: the `agent` list claimed
  `tom_basics`, which no file in the module imports, and omitted `dart:async`,
  `cancellation.dart` and `placeholders`; the `llm` list omitted `dart:async`,
  `dart:convert` and `prompt_sha256.dart`.

### Added

- **The Agent SDK provider is tested against a two-channel prompt (tcopen343).**
  Every existing assertion rode a system-only `WirePrompt`, where
  `combined == system`, so a provider that put the system channel on the wire
  and fingerprinted it would have passed all of them; the buffered `complete`
  asserted two fields and never the provenance triple. A new group drives both
  entry points with both channels filled, with a control on the fixture itself.

- **Tests for the llm unit's value types (tcopen342).**
  `test/llm_value_types_test.dart` covers the four pieces the provider tests
  reached only in passing. `LlmOptions.copyWith`'s `_unset` sentinel exists to
  distinguish omitting a parameter from passing `null`, and both arms are now
  asserted — including that each of the five nullable fields clears
  independently, and that `stopSequences` and `toolCatalogue` cannot be cleared
  because they are non-nullable with defaults.

  `WirePrompt.combined` gets its three branches. It feeds `promptSha256`, which
  stamps `LlmCallReport.promptHash`, so a change to the join would silently
  change every prompt hash ever recorded with nothing failing.

  `ToolCatalogue` and `ToolDescriptor` are exercised through `LlmOptions`, and
  `LlmStreamToolCallProposed` through an exhaustive `switch` — which is how a
  consumer of a sealed family meets a variant the shipped provider never emits.

- **A runnable example for the `llm` unit (tcopen339).**
  `example/llm/llm_example.dart` implements `LlmProvider` end to end and drives
  it through `complete` and `completeStream`. It asserts the three invariants
  an implementer most easily breaks — the anchor stamp, the unmodified body,
  and one route announced once — with the route check made under a per-call
  model override, because under default options a provider that resolved the
  model twice would look correct.

  It also shows that one failure takes two shapes: a terminal
  `LlmStreamFailed` carrying a still-attributable report on the streaming
  path, and an exception on the buffered one.

- **An API mirror for the `llm` unit (tcopen338).**
  `doc/api/api_summary_llm.md` gives each of the twenty exported types a
  section, plus `agentSdkLooksLikeSessionError` and both public statics. With
  it `test/api_summary_test.dart` now holds three mirrors, discovered from
  `doc/api/` rather than listed.

- **A prose page for the `llm` unit (tcopen337).** `doc/llm.md` documents the
  provider seam a reader could previously only reconstruct from dartdoc: the
  `LlmProvider` contract and its anchor, no-mutation and provenance
  invariants; the stream lifecycle and why a non-streaming backend still
  implements `completeStream`; the value types, including why `WirePrompt` is
  `final` and why `combined` preserves the anchor guarantee; and for
  `AgentSdkLlmProvider`, the control inversion, the dropped thinking blocks
  whose tokens still count, the tool-call event that is deliberately never
  emitted, the four conditions on its single retry, and the conservative
  two-cue session matcher that separates it from the editor's broader one.

  The three session strategies get a table and the rule that matters most:
  **no method may throw because the session state is damaged**, write included
  — the provider awaits `record` on the success path, so a throwing store would
  destroy a call that has already been billed.

- **`markWorkerDead` says that it is terminal (tcopen335).** A guard told its
  worker died fails every future request for the rest of its life; a host that
  respawns builds a new guard. That followed from "one-shot" and is now stated
  on the method, with the reason a resettable guard would be worse — it would
  have to decide what it owed the requests that were in flight at the death.

- **The cancellation discriminator's precondition is enforced (tcopen334).**
  `IsolateCancellationRegistry.register` asserts that token ids arrive strictly
  increasing — the property that lets the high-water mark tell a pre-open
  cancel from a post-close one, and which holds only for a single host
  allocator over an ordered transport. Two allocators into one registry, or a
  reordering transport, previously made a genuine pre-open cancel
  indistinguishable from a post-close one: it was dropped, and the request ran
  to completion having been cancelled with no error anywhere.

  Four tests pin it, including a control over the ordinary in-order sequence
  and one that demonstrates the silent mis-read the assert replaces.

- **Disposal is documented as an obligation, and the example proves it
  (tcopen333).** `IsolateCancellationHandle.dispose()` removes a request's
  entry from the registry; skipping it holds one entry per request served for
  the life of the isolate, with nothing failing and `inFlightCount` the only
  reading that would show it. `doc/isolate_streaming.md` states that under
  Concurrency and Lifecycle and `doc/api/api_summary_isolate_streaming.md`
  states it on the handle.

  `example/isolate_streaming/` now asks its worker for `inFlightCount` after
  both cancelled requests have ended and asserts it is zero. Removing the
  `finally` that disposes makes the demo print `2 in flight` and fail — so the
  example shows what the obligation buys instead of performing it silently.

- **An API mirror for the `isolate_streaming` unit (tcopen332).**
  `doc/api/api_summary_isolate_streaming.md` gives each of the twelve exported
  types a section; the unit declares no top-level function, constant or public
  static, so twelve sections are the whole of it. It leads with the fact the
  prose had wrong twice — which side of the boundary each type lives on — as a
  table: only `IsolateCancellationToken` is sendable, the registry and handle
  hold live completers and never leave the executor's isolate, and the guard
  and the exception registry are host-side.

  `test/agent_api_summary_test.dart` is now `test/api_summary_test.dart` and
  holds **every** `doc/api/api_summary_<unit>.md`, deriving each one's required
  symbols from `lib/src/<unit>/<unit>.dart`. Neither a unit name nor a symbol
  name is written out in it, so a third mirror is covered the day it lands.

- **`ReminderTemplateStore` (tcopen331).** `ReminderTemplate` was the one
  persisted-shaped model in the unit with no store — a `fromYaml`/`toYaml` pair
  like the nine that had one, and nothing that could read or write a set of
  them. That mattered because two models which *are* persisted hold a
  `reminderTemplateId`: `QueuedPrompt` and `TimedRequest`. A queue restored on
  the next launch therefore named a reminder body nothing in the package could
  load, which is a reference in name only.

  The store is the tenth instance of an already-uniform pattern — `Store(File)`,
  a `resolveDefault()` honouring `TOM_SPECS_REMINDER_TEMPLATES_FILE` and
  falling back to `<cwd>/.tom/reminder_templates.yaml`, a `load()` degrading to
  an empty list, a `save()` writing the `version: 1` envelope — so it inherits
  the shared degradation rule rather than restating it.

### Fixed

- **Three citations of documents the package does not ship (tcopen341).**
  `lib/src/llm/llm.dart` explained which providers were deliberately left
  behind and pointed at a workspace-internal deferral note that a package
  reader cannot reach — and which said nothing about the providers, so the
  sentence pointed at a document that neither shipped nor carried the claim. The reason is now stated inline. The README and
  `doc/placeholders.md` each cited another such note for the deferred
  `dart:io` removal; both now say the work is deferred without naming a file
  nobody outside this workspace can open.

- **`doc/api/api_summary_agent.md` described `TimedRequest.scheduleMode` as
  optional (tcopen331).** It is required, and deliberately so: a caller states
  whether an entry repeats on an interval or at fixed times instead of
  discovering which one they got. The summary said the opposite because it
  followed an older finding's description of the defect rather than the
  constructor, which is the one source it claims to be written from.

- **A runnable example for the `agent` unit (tcopen329).**
  `example/agent/agent_example.dart` walks it end to end in four acts: a
  sidecar round-trip and both degradation rules (parse damage costs the file,
  shape damage costs one entry — shown with three rows of which two are
  unusable), bridge discovery with a `localhost` binding matched back against a
  `127.0.0.1` scan result, the reconnect back-off resolving `sameWorkspace`,
  `differentWorkspace` and `stillGone`, and a send that refreshes a stale
  session id and then declines to refresh a second time.

  No network, no VS Code, no API key: the port scanner, the reconnect delay and
  the Agent SDK transport are injected, which is possible only because the unit
  already takes each of them as a seam. It runs in under a second and touches
  only a temporary directory it deletes.

- **An API mirror for the `agent` unit (tcopen328).**
  `doc/api/api_summary_agent.md` gives each of the unit's 51 exported types, 13
  top-level functions and 4 constants its own section and names all three
  public statics — 68 symbols whose only listing was a table in a quest
  document the package does not ship.

  It is held rather than trusted: `test/agent_api_summary_test.dart` derives the
  required set from `lib/src/agent/agent.dart` and fails on a symbol with no
  section, a public static never named, or a section naming something the
  barrel does not export. No symbol name is written out in the test, so it
  cannot go stale in the same direction as the document it guards.

- **A prose page for the `agent` unit (tcopen327).** `doc/agent.md` documents
  what a caller cannot infer from signatures: the ten sidecar paths and their
  environment overrides, the payload key and identity field each list store
  uses, and the two halves of the degradation rule — parse damage costs the
  file, shape damage costs one entry. Then the bridge protocol (the 19900–19909
  scan range, the workspace-identity handshake, and why a binding matches a
  scan endpoint-wise rather than by string), the reconnect back-off with its
  10/30/60-second schedule and three resolutions, and the send engine: the
  event lifecycle, the four conditions that together permit one retry with a
  fresh session, and the fact that **cancellation ends the stream with no
  terminal event at all**, so a consumer waiting for one to re-enable its UI
  must also watch the token.

  The README gains a table linking all five of the package's doc pages, none of
  which it referenced before.

## 1.8.0

### Changed

- **Every example refuses to run without `--enable-asserts`.** The examples
  verify themselves with `assert`, and `dart run` strips asserts unless given
  the flag, so a flagless run printed a plausible transcript and exited 0 having
  checked nothing — a result that cannot be told from success.
  `test/examples_test.dart` already ran each example under its documented
  command, which kept the examples honest; it did nothing for a reader running
  one from memory. Each example now opens with `requireAsserts()`
  (`example/require_asserts.dart`), which exits with status 2 and the corrected
  command when asserts are off, and the test requires that refusal of every
  example. `tom_core_kernel`'s samples refuse the same way.


- **`isolate_streaming` closed its last two open classes.**
  `IsolateRequestGuard` and `IsolateExceptionRegistry` were plain `class` while
  the module's other eight public types were `final`. Nothing in the workspace
  extended, implemented or mixed in either — the two consumers
  (`tom_brain_substrate`, `tom_brain_memory`) use both by composition — so the
  split bought no extension point and recorded no decision; it read as
  whichever modifier each file happened to be written with.
  Both are now `final`, and each says in its dartdoc *why*, because that is the
  part a modifier alone cannot convey: neither type is varied by subclassing.
  The guard is adjusted by `defaultTimeout` and `guard`'s per-call `timeout`,
  and learns of a death through `markWorkerDead` rather than an overridable
  hook; the registry is specialised by the `IsolateExceptionFactory` closures
  you register, which is already a function type. A subclass of either would
  have nothing to override that is not already a parameter.
  The module's two *private* helpers, `_GuardEntry` and `_RegistryEntry`, were
  deliberately **not** given the keyword. A class modifier governs subtyping
  from outside the declaring library and a private class is invisible there, so
  `final` on them would permit exactly what its absence permits while reading
  as a decision. Each now carries a line saying so, which is the honest form of
  the same consistency.
  No API is lost: both classes were only ever constructed and called, and both
  consumer packages still analyze clean.
  `doc/isolate_streaming.md` moves to `final class` in both rows, which is what
  makes this stick — `tool/check_doc_kinds.py` compares the `Kind` cell to the
  declaration's modifiers verbatim, so dropping `final` again now fails a gate
  rather than passing unnoticed as it did before.

### Fixed

- **A mis-typed optional field cost the whole agent entry.** The nine models in
  `agent/` read their optional fields through 123 nullable casts of the shape
  `yaml['name'] as String? ?? ''`. That shape answers an *absent* field — it
  defaults — and not a field that is *present* holding the wrong type:
  `name: 7` is not a `String?`, so the cast threw. `decodeAgentYamlEntries`
  caught the `TypeError`, so nothing escaped, but the entry was dropped in
  full — a profile whose `description` was a number lost its prompt, its model,
  its tool list and its id, when defaulting `description` to `''` would have
  cost the user nothing they notice.
  Three leaf readers in `agent/agent_yaml.dart` replace the idiom at every one
  of those sites: `yamlValue<T>` (type-tests rather than casts, so absent and
  unusable give the same answer), `yamlStringList` (keeps the elements that are
  strings) and `yamlEnum` (absent stays `null`; an unrecognised string falls
  back inside the enum's own `fromValue`). Damage below the identity now costs
  the *field*, at its documented default.
  The identity fields are deliberately untouched and still cast: an entry whose
  `id` — or a `ChatVariable`'s `name`, or a `TrailPair`'s `request` — cannot be
  read cannot be addressed, updated or deleted, so there is nothing to salvage,
  and `decodeAgentYamlEntries`'s `on TypeError` remains the last resort that
  drops it. `test/sidecar_shape_damage_test.dart` asserts both halves.
  Two models gain the guarantee they never had, because neither is read through
  a list store and so nothing was catching for them: `AgentSettings`, where an
  all-or-nothing read reset every option the user set because one was
  unreadable, and `ReminderTemplate`, whose `fromYaml` propagated the `TypeError`
  to its caller.
  `QueueTemplate.prompts` changes shape with them: it stringified whatever the
  list held (`- 7` became `'7'`) and now keeps the strings and drops the rest,
  matching `AgentProfile.enabledTools` and the nested-list rule everywhere else
  in the package.

- **`isSimpleIdentifier` was documented as the simple form's grammar. The
  simple form has no grammar.** Three texts called it "the shape the simple
  `${name}` fast path accepts". Nothing in this package applies it: the scanner
  routes on prefix alone, so any body that is not `env:` / `file:` / `state:`
  is a lookup key, and `PlaceholderStack.bind` accepts any string as a name.
  That latitude is load-bearing, not accidental — the brain substrate's
  `role.anchor` built-in is a dotted name, and `SystemScaffold.template` leads
  with it. Enforcing the documented rule in `bind` or `_classify` would have
  broken the assistant's system prompt, which is why the texts were corrected
  instead of the code.
  The *second* half of the same sentence — "the only binding names that can be
  injected as d4rt expression locals" — is true, and is enforced, just not
  here: `D4rtExpressionContext.evaluate` in `tom_brain_procedure` filters
  `flatten()` through this predicate before synthesising its parameter list.
  The constraint is d4rt's (a local becomes a parameter name), so it belongs
  to the backing, in the same tier-design that keeps this package free of a
  d4rt dependency. The dartdoc now says which layer applies it.
  The real consequence is milder than a failure and was undocumented: a
  non-identifier binding is visible to `${name}` and silently absent from
  `${{ … }}`. Four tests pin it (520 → 524), plus one in `tom_brain_procedure`
  at the enforcement point.

- **`${name}` was documented as "equivalent to `${{ name }}`". It is not.**
  The resolver header and `doc/placeholders.md` both invited a reader to
  substitute one form for the other, when the forms agree on exactly one case
  — a **bound** name, resolved through **`resolve`**, against a configured
  backing — and diverge on three axes everywhere else. `${{ name }}` requires
  a `PlaceholderExpressions` backing and throws without one; it throws on
  `resolveSync` even *with* a backing, so the config loaders can never reach
  it at all; and on an unbound name it consults **neither** `strict` nor
  lenient, because that case belongs to the backing. The third axis is the one
  the docs hid most effectively: the divergence is not "strict is bypassed",
  it survives switching to lenient.
  Both texts now state the qualified relationship rather than an equivalence,
  and three tests pin each axis (517 → 520). The alternative — short-circuiting
  an identifier-shaped `${{ … }}` body to the simple lookup, making the
  equivalence true — was rejected: `placeholder_expressions.dart` documents the
  no-backing failure as deliberate ("a stray `${{ … }}` in a config value fails
  fast rather than silently passing through"), so short-circuiting would let
  `${{ name }}` pass in a config value while `${{ name + 1 }}` still failed,
  and it contradicts an existing test asserting the backing receives an unbound
  body.

- **The package-wide `dart:io`-free claim was false, and the carve-out that
  qualified it was too.** Four documents stated that `PlaceholderResolver` held
  the package's *only* `dart:io` import. A grep returns fourteen importers, and
  five of the thirty-six barrel exports reach one — `agent/`, `llm/`,
  `path_scope_io.dart`, `placeholders/`, and `yaml_config_reader.dart`, the last
  coupled only transitively through the placeholder resolver it uses for `${…}`
  expansion. The claim was **true when written** (2026-06-15) and went stale the
  next day, when `agent_sdk_session.dart` landed; nothing rechecked it as the
  package grew. The carve-out made this worse than silence would have, because
  it told a reader the exception had been counted.
  The claim is now restated at the level where it holds: the package is not
  `dart:io`-free, the other **31 exports are**, and that subset is what
  `dart:io`-forbidding consumers use — `tom_brain_shared`, the one named
  consumer, draws seven symbols and all seven are in it.
  The documents also had the *mechanism* wrong. `dart compile js` does not
  reject `dart:io`: it compiles, stubs the library, and throws
  `UnsupportedError` only when a stubbed member is reached, so a web consumer
  can import the barrel — or `show` a symbol from a coupled export — and fail at
  runtime instead of at build time. Since no compiler catches this,
  `test/dart_io_coupling_test.dart` now pins both the importer set and the
  coupled/clean export split (514 → 517), which is what makes the README table
  checkable rather than a second count waiting to rot.

- **`Kind` columns in `doc/` named things Dart does not declare.** Eight
  Overview rows across `doc/bearer_auth.md` and `doc/placeholders.md` described
  a symbol's *role* in the column that is asked what its *declaration* is:
  `BearerTokenAuthenticator<P>` was `interface` while being an
  `abstract interface class`, `BearerAuthFailure` was `exception` while being a
  plain `class`, and the six placeholder types were `class` / `interface` /
  `exception` while being `final class` and `abstract interface class`. Each
  cell was true as a description and useless as an answer to the question the
  column exists for — may I extend this, or only implement it? — and the two
  restrictive kinds are exactly the ones the informal words cannot express.
  `doc/mcp_auth.md` and `doc/isolate_streaming.md` were checked the same way and
  were already correct.

### Changed

- **Wire key `tomBrainBearerToken` → `tomBearerToken`** (`bearerTokenMetaKey`).
  The value named `tom_brain` — a package this one does not depend on and never
  will — from when the constant lived there, so every future MCP server in the
  framework (a planning server, a procedure server) would have presented its
  token under a key named for someone else's package, in a package whose barrel
  and README both advertise "generic, domain-free building blocks". Of the five
  symbols in the module this is the only one that had to be *renamed* rather
  than re-exported: the other four are Dart symbols a consumer can rename at
  will, whereas the `_meta` key is the single thing a client and a server agree
  on **out of band** — the compiler renames a symbol, only a coordinated
  release renames a wire key, which is why it was done now, before publication,
  rather than left. Every Dart consumer reads the constant rather than the
  literal, so the compiler carried the rename; the only edits were prose and two
  test expectations. Downstream: `tom_brain_memory`'s MCP server and its
  `a76_bearer_auth_test.dart` were swept in the same pass — its full suite
  (1496 tests, including a two-OS-process client/server run over HTTP) is green,
  so the rename is verified end-to-end on the wire and not merely
  compile-clean. Coverage: `test/mcp_auth_test.dart` gains a case asserting the
  key is scoped to the framework and names no package in it, pinning the
  invariant the rename restored so it cannot quietly regress (513 → 514).
- **`mcp_auth/` → `bearer_auth/` + `mcp_auth/`**: the bearer-auth module was one
  file holding two unrelated things — a transport-neutral failure taxonomy
  (`BearerTokenAuthenticator<P>`, `BearerAuthFailure`,
  `BearerAuthFailureReason`) and two MCP wire constants (`bearerTokenMetaKey`,
  `bearerAuthRpcErrorCode`) — and three documents claimed its existence was what
  stopped servers re-deriving that taxonomy. The claim was false: the HTTP edge
  in `tom_brain_access` declares its own copy with a byte-identical `toString`,
  and does so *while already depending on `tom_core_agentic`*, so availability
  was never the obstacle — reaching the taxonomy meant importing a `_meta` key
  and a JSON-RPC error code an HTTP edge has no use for. The three neutral types
  now live in `lib/src/bearer_auth/`, whose contract file has no imports at all;
  `mcp_auth/` keeps only the two constants and imports the contract, so the
  dependency runs MCP → taxonomy and not back. Their dartdoc was de-MCP-ified in
  the move (the prose described the `initialize` handshake as the only place a
  token could arrive, and `BearerAuthFailure` cross-referenced
  `bearerAuthRpcErrorCode` as *the* translation rather than one edge's mapping)
  — moving the file without that would have carried the coupling along in the
  one form a compiler cannot check. **No call site changes**: all five symbols
  are still exported from the package barrel under the same names with the same
  values and behaviour. Coverage: the six taxonomy tests moved verbatim to
  `test/bearer_auth_test.dart`, which imports
  `src/bearer_auth/bearer_auth_contract.dart` rather than the barrel — so the
  separation is a compile-time fact and folding the types back in beside the
  constants would stop that file compiling. `doc/mcp_auth.md` split accordingly,
  gaining `doc/bearer_auth.md`.

### Fixed

- **`llm/`**: the `llm` unit's flagship worked example — the `EchoProvider` a
  reader copies to write their own provider — broke both of the contracts the
  prose around it is about. It announced `LlmStreamStarted(providerId: 'echo',
  modelId: 'echo')` from a `const` constructor while completing with
  `providerId: id, modelId: options.model ?? 'echo'`, so
  `EchoProvider('primary')` under `LlmOptions(model: 'sonnet')` opened on one
  route and terminated on another; the `const` is what forced it, since a const
  constructor cannot read either value, making the mistake structural rather
  than a typo. Its `complete()` was
  `completeStream(...).whereType<LlmStreamCompleted>().first`, which on a
  failed stream raises a bare `StateError: No element` and discards the
  `LlmStreamFailed` carrying the reason — every failure reported identically
  and uninformatively. The example now stamps `id`/`modelId` on Started and
  drains the stream, rethrowing `failure.cause` or the failure message, which
  is the shape the shipped provider already had. Root cause: the invariant was
  real and tested but stated nowhere a copier would read it —
  `LlmProvider.completeStream` and `LlmStreamStarted`'s field dartdoc only ever
  constrained the *terminal report*, so nothing said Started had to agree with
  it. Both now say so. Coverage: the two tests that touched Started asserted
  its fields against literals that happened to match the report's, which pins
  two values but not the relationship between them; they now assert the
  agreement directly, so a provider that hardcoded the pair fails instead of
  passing.

- **`llm/`**: four documents promised that a provider emits only
  `classCode: 'unknown'`, which the one shipped provider has never done — a
  stream that ends without a terminal result yields `'format'`. The promise was
  the thing a consumer would most reasonably rely on ("I only ever have to
  handle `unknown` from this layer"), and it was false at the single place it
  could be checked, so a consumer switching on `classCode` mishandled exactly
  the malformed-stream case. Resolved by correcting the documents rather than
  narrowing the provider: `format` already appears in the dartdoc's own
  taxonomy list, it is asserted by a test, and flattening it to `unknown` would
  discard the one thing the provider genuinely observed for itself. The four
  now state the actual contract — a provider settles the two classes it can
  determine without interpreting the backend (`format` for a malformed stream,
  `unknown` for everything else) and leaves the rest of the taxonomy to the
  caller, so a consumer must handle both. The same paragraphs called `classCode`
  "kebab-case" in three places while every example listed, and the two values
  actually emitted, are snake_case; nothing in the module is kebab-case.
  Coverage: the two paths that emit `unknown` had tests asserting `message` and
  the report but never `classCode`, which is why the claim could drift
  unnoticed — both now pin it, so all three emission sites are held.

- **`llm/`**: `AgentSdkLlmProvider` misreported both retry fields of every
  `LlmCallReport`. `_buildReport` hardcoded `retries: 0` — including on the
  report emitted *after* the evict-and-retry-fresh path had just burned a
  retry — and `wallClockMs` preferred the SDK result's `duration_ms` over the
  provider's own stopwatch. The two defects compound: `duration_ms` times a
  single attempt on the backend, so on a retried call it silently dropped the
  failed first attempt and the wait between them, which is exactly the case the
  retry counter was supposed to flag. The contract on `LlmCallReport` was right
  all along ("in-caller retries burned before this report", "total wall-clock
  between submission and completion (includes retry waits)"); only the provider
  disagreed. This reached further than the trail: `LlmRouter._foldRetries`
  computes `report.retries + retries`, so the hardcoded zero under-counted the
  router's aggregate too. The provider's retry flag is now an `int retries`
  that `_buildReport` takes as a required argument — required rather than
  defaulted, because a default is what let every report claim a first-shot
  success — and `wallClockMs` always reads the stopwatch, which is started once
  at submission and deliberately read without stopping it, since the
  costed-error branch may still continue into a retry. The agent-SDK provider
  is the only provider affected: the HTTP and stub providers hardcode `0`
  correctly, having no internal retry (the router owns retry for them).
  Coverage: the existing evict-and-retry test now scripts a delay into both
  attempts and asserts `retries: 1` plus a wall clock spanning both, and the
  first-shot test pins `retries: 0`. One existing assertion had to be corrected
  rather than kept — `agent_sdk_provider_test.dart` asserted
  `wallClockMs == 1234`, the scripted `duration_ms`, so it was pinning the
  defect in place; it now asserts the figure is a real elapsed measurement and
  specifically not the backend number.

- **`llm/`**: `AgentSdkSessionStore` honoured its no-throw contract on reads
  only. `_load` degraded a missing, corrupt or unreadable file to an empty map,
  but `_flush` caught nothing — and the provider awaits it twice on paths where
  an exception destroys work already done. `put` runs on the **success** path,
  immediately before the terminal event, so an unwritable store turned a
  completed, billed model call into a stream error: no `LlmStreamCompleted`, no
  report, no usage or cost, and `complete()` throwing too. `remove` runs from
  the evict-and-retry-fresh decision, which the provider awaits *outside* its
  try/catch, so the same store turned a classified `LlmStreamFailed` into an
  unhandled stream error. `_flush` now degrades exactly as `_load` does. The
  guard went into the store rather than into the provider's call ordering
  because that is where the contract is stated, and because it covers both call
  sites: making `record` fire-and-forget would have left the evict path open and
  converted the throw into an unhandled async error. Little is actually lost —
  both mutators update the in-memory cache before flushing, so the session
  survives in-process and only a restart pays the one fresh call the contract
  allows for. Coverage: four tests driving an unwritable store (a path whose
  parent is an ordinary file, so it reproduces without depending on the uid the
  suite runs as) through `put`, `remove`, a successful call, and the evict path.

- **`isolate_streaming/`**: `doc/isolate_streaming.md` had drifted from the
  module in three places at once, all of them the same failure — the prose was
  written before the module reached its current shape and was not re-read as
  the module moved. The `Kind` column called 8 of its 12 rows something the
  declaration does not say (two `exception` rows for types that are
  `final class ... implements Exception`, and six `class` rows for
  `final class`); the Overview row for `IsolateCancellationRegistry` still
  summarised the unknown-token cancel as "remembers late cancels", the
  pre-fix half of a rule that has two branches; and the Concurrency section
  repeated that same half-truth a third time while asserting the tests use
  hand-held `Completer`s "rather than a real isolate" — which the sendability
  group (a live `SendPort`) and the real-isolate cancellation demo in
  `example/isolate_streaming/` had both already falsified. All corrected
  against the declarations and the tests. The workspace's completion mirror
  of this package was accurate throughout and was used as the reference; the drift was one-sided. Two of the three defects were found
  by auditing the file rather than from the report, and the reported counts
  were themselves off (8 of 12 rows, not nine).
- **`isolate_streaming/`**: `BackpressureTracker` let the closed flag decide
  whether an argument was valid. `grant` returned on `_closed` *before* its
  `n <= 0` check, so `grant(0)` threw while open and passed in silence once
  closed — the same call answered two ways by state the caller may not know,
  and both documents stated the guard unconditionally. `consume` had no closed
  check at all, so it kept drawing down a ledger nobody was keeping, and could
  raise the over-consume `StateError` against a balance that had stopped
  meaning anything. The two methods disagreed with each other and `grant`
  disagreed with its own documentation. Both now follow one rule: **validate
  the argument, then consult the closed flag.** A nonsensical count is a caller
  bug in either state; a state-dependent effect is skipped once the ledger
  closes. Coverage: four tests beside the existing close test in
  `test/isolate_streaming_test.dart`.
- **`isolate_streaming/`**: neither document said what a *closed* tracker does
  with `consume`, which left the primitive's whole close path unspecified —
  the todo's own note called this the real question, the line move being the
  easy half. Written down now, on the class and in both documents: after
  `close` the ledger stops accounting (`grant`/`consume` no-op, `credits`
  freezes) and only `awaitCredit` reports the closure. Making `consume` throw
  instead was considered and rejected on evidence, not symmetry: a close
  routinely lands mid-iteration, after `awaitCredit` returned and the chunk
  went out but before the trailing `consume`, and in `tom_brain_memory`'s
  producer that throw would land outside its `on StateError` guard and in the
  generic catch — reporting a clean close to the host as a stream error.
  `awaitCredit` stays the single unwind point because it is the only one
  callers already handle.
- **`isolate_streaming/`**: `IsolateCancellationRegistry.isCancelled` was
  documented as answering "whether or not it is currently registered", which
  it has not done since the post-close-cancel fix and could not do cheaply.
  `dispose()` removes the entry, so a request that really was cancelled reads
  `false` from the registry a moment later — while its handle, which holds the
  entry directly, still reads `true`. The doc promised the durable reading and
  the code gives the in-flight one, and the difference is a silently wrong
  answer rather than an error. The contract is now the narrow one on both the
  dartdoc and in `doc/isolate_streaming.md`: the registry answers for what it
  currently holds (an in-flight entry, or a remembered pre-open cancel), the
  handle is the durable answer for one request, and callers should prefer the
  handle wherever one is in scope. Making the registry durable instead was
  rejected because it recreates the leak the post-close drop exists to prevent
  — ids are never recycled, so a cancelled-and-closed record can only grow for
  the executor's lifetime. Coverage: `registry isCancelled is scoped to the
  registration window` and `a remembered pre-open cancel is inside the window`
  in `test/isolate_streaming_test.dart`, which assert both sides of the
  divergence; the neighbouring post-close-cancel test now says in a comment
  that its `isFalse` follows from this contract rather than stating one of its
  own.
- **`isolate_streaming/`**: `doc/isolate_streaming.md` and the example
  described the cancellation split backwards — registry on the host, handle
  shipped across to the worker — where the source puts the registry and the
  handle inside the executor's isolate and sends only the token. The guide's
  snippet was not merely differently-worded but unrunnable: the handle holds a
  `Completer`, so the first `SendPort.send` raises `ArgumentError: object is
  unsendable`, with nothing to suggest the document had caused it. The prose
  also contradicted itself within four lines, calling the handle a
  "worker-side view" and then having the host construct it. Both now describe
  the split the source implements, and the cancellation demo spawns a real
  isolate instead of faking the boundary with futures — faking it is what let
  an inverted arrangement look as convincing as the correct one. Two adjacent
  inaccuracies found in the same pass are fixed too: the registry does **not**
  remember every late cancel (an id it has already seen is dropped, or the
  pending set would grow forever), and `IsolateRequestGuard` is host-side.
  Coverage: the new `sendability across an isolate boundary` group in
  `test/isolate_streaming_test.dart` pins which members may cross — the fact
  the whole design rests on, previously asserted nowhere, which is why the
  documents could disagree with the code for so long.
- **`agent/`**: a bound bridge that was up and answering could be reported as
  gone. Four defaults named the bridge host and one disagreed —
  `AgentSettings.bridgeHost` was `'localhost'` where `BridgeServer`,
  `BridgeConnectionService` and `BridgeChoice.fromMap` all said `'127.0.0.1'`
  — and both places that compare a binding to a discovered server compared the
  host *strings*. `localhost` and `127.0.0.1` are one endpoint and two
  strings, so in the package's own default configuration `ReconnectCoordinator`
  resolved `stillGone` for a live bridge (the §6.1 still-gone modal, and no
  auto-resend) and the picker's `isBound` showed the bound window as merely
  `available`. Fixed at both levels: the new `defaultBridgeHost` constant
  supplies every host default so they cannot drift again, and the new
  `BridgeChoice.matches` compares endpoints rather than strings, so a host
  typed by hand into the settings file costs nothing either. Coverage:
  `test/bridge_connection_test.dart`, `test/reconnect_test.dart`, and
  `connection_test.dart` in `tom_forge_agentic` for the picker side.
- **`agent/bridge_connection.dart`**: `BridgeChoiceStore.load()` had no `try`
  at all — alone among the ten sidecar stores. An unreadable file raised
  `FileSystemException` and a syntactically damaged one raised
  `YamlException`, so a hand-edited sidecar crashed the editor on launch
  instead of costing a re-pick. It now degrades like its nine siblings
  (`FileSystemException` / `FormatException` → `null`) and reads through the
  shared `decodeAgentYaml`, which makes the root-shape check the same one
  they make.
- **`agent/bridge_connection.dart`**: `BridgeChoice.fromMap` cast rather than
  type-tested, so a mis-typed value — `port: "19900"`, the classic hand-edit
  slip — threw a `TypeError` straight past the store's catch. It now defaults
  an unusable value exactly as it already defaulted an absent one. Coverage
  for both defects: `test/bridge_connection_test.dart`.
- **`agent/`**: every sidecar store caught `FileSystemException` and
  `FormatException` around its load, which answers a file that will not
  *parse* but not a file that parses into the wrong *shape*. An entry whose
  `id` was absent or non-string — the shape a hand-edit produces when a line
  is deleted — threw a `TypeError` out of `fromYaml`, past both catches and
  into the caller. Entries the file cannot supply are now skipped
  individually, so one damaged row costs that row rather than the whole file.
  The nested lists (`QueuedPrompt.prePrompts` / `.followUps`,
  `TimedRequest.scheduledTimes`, `AgentProfile.enabledTools`,
  `TrailPair.answer`) skip bad elements the same way. Coverage:
  `test/sidecar_shape_damage_test.dart`.

### Changed

- **`agent/timed_request.dart`**: `TimedRequest.scheduleMode` is now a required
  constructor parameter (it defaulted to `ScheduleMode.interval`). The default
  was introduced by the port — the upstream
  `tom_vscode_scripting_api.TimedRequest` requires it — and it meant a request
  built without the parameter became an interval request nobody chose, with
  `intervalMinutes` nullable beside it. Its payload stays optional: these are
  editor working state, and "scheduled, but no times entered yet" is a state
  the type has to be able to hold. The persisted key also stays optional,
  coerced by `ScheduleMode.fromValue`, so a hand-edited file costs a re-pick
  rather than the entry.
- **`agent/agent_sidecar.dart`** (new, exported): `readAgentYamlFile`,
  `decodeAgentYamlList` and `decodeAgentYamlValue` — plus
  `decodeAgentYamlEntries` in `agent/agent_yaml.dart` for the nested lists.
  The ten stores had ten copies of one `load()` body, and the copies had
  drifted exactly as copies do: one shipped with no `try` at all (above), and
  all ten mistook "parses as YAML" for "is shaped like the model". All ten now
  read through this one path, so "every sidecar degrades the same way" is a
  property of one function rather than a claim about ten bodies. No behaviour
  change beyond the fixes above.

### Features

- **`agent/`**: added the editor-facing agent data models for the TomSpecs
  editor (`tom_specs_editor_specification.md` §20 step 2) — `AgentProfile`
  (incl. the editor-specific `interruptRetryPrefix`, N10), the prompt-queue
  model (`QueuedPrompt` / `QueuedPrePrompt` / `QueuedFollowUpPrompt` with
  statuses, repeats, reminders and multi-transport routing), the chat / trail
  model (`ChatMessage` / `TrailPair`), `ReminderTemplate` and `TimedRequest`.
  All models round-trip through YAML via the new `encodeAgentYaml` /
  `decodeAgentYaml` codec.
- **`agent/`**: added `EditorPlaceholderBindings`, a sync + lenient binder over
  the shared `PlaceholderResolver` that supports `${name}`, `${name?}`,
  `${env:NAME}` and the `{{name}}` alias, and **rejects** the `${{ … }}`
  expression form with `PlaceholderExpressionsUnsupportedError` rather than
  executing it (§11.5, no JS). Coverage: `test/agent_models_test.dart`.

## 1.6.0

### Features

- **`llm/`**: migrated the LLM provider contract (`LlmProvider`, `WirePrompt`,
  `LlmOptions`, `LlmCallReport`, `CapturedWirePrompt`, the `LlmStreamEvent`
  family, `LlmFailure`) and the Anthropic Agent-SDK provider path
  (`AgentSdkLlmProvider`, the `AgentSdkSession*` strategies / store,
  `agentSdkLooksLikeSessionError`) out of the `tom_brain` substrate / run
  layers so the provider seam is reusable outside the brain (the TomSpecs
  editor consumes it over the VS Code bridge). Added the
  `tom_vscode_scripting_api` dependency. The substrate-coupled HTTP / stub
  providers are intentionally not migrated (see the quest's
  `completion_steps.tom_specs.md`, CS-04). Coverage:
  `test/agent_sdk_provider_test.dart`, `test/agent_sdk_session_test.dart`.

## 1.5.0

### Documentation

- **`isolate_streaming/`**: added `doc/isolate_streaming.md` (a module guide for
  the cancellation family, the per-stream close signal, the backpressure ledger,
  the request guard, and the exception registry) and a runnable
  `example/isolate_streaming/isolate_streaming_example.dart`. Filled the one
  remaining dartdoc gap (`IsolateStreamCloseSignal.closeRequested`). No public
  API change; the existing isolate-streaming test files remain the coverage.
- **`mcp_auth/`**: added `doc/mcp_auth.md` (the bearer-token wire contract, the
  authenticator interface, the closed failure taxonomy, and the tier boundary)
  and a runnable `example/mcp_auth/mcp_auth_example.dart` that plays both sides
  of an MCP `initialize` handshake. No public API change; the existing
  `mcp_auth_test.dart` remains the coverage.
- **`placeholders/`**: added `doc/placeholders.md` (the four placeholder forms,
  `resolve`/`resolveSync`, the lexical scope stack, the `${{ … }}` expression
  seam, strict/lenient + recursion policy, and the typed failures) and a runnable
  `example/placeholders/placeholders_example.dart`. No public API change; the
  existing `placeholder_resolver_test.dart` / `placeholder_stack_test.dart`
  remain the coverage. Flagged (for a follow-up) that `PlaceholderResolver` is
  the package's sole `dart:io` import, at odds with the `dart:io`-free design.
  (True on the day this shipped; the next commit added a second importer and the
  count has grown since. See 1.8.0 for the measured position.)

## 1.4.0

Consolidated record of the incremental feature development between `1.0.0` and
the current `pubspec.yaml` version `1.4.0`. These primitives were added across
several unversioned increments; the precise per-release (`1.1.0`–`1.3.0`)
boundaries were not recorded at the time, so they are grouped here under the
current package version. Reconstructed from the project's git history.

### Added

- **Isolate-streaming infrastructure** (`isolate_streaming/`): a domain-free
  worker-isolate streaming layer — cooperative `IsolateCancellation`, stream
  close-signalling, a `BackpressureTracker`, a per-request `IsolateRequestGuard`
  (worker-death + per-request deadline), and a generic `IsolateExceptionRegistry`
  that reconstructs typed errors across the isolate boundary.
- **MCP transport-auth contract** (`mcp_auth/`): the generic bearer-auth
  contract and MCP authentication helpers, hosted here so transports share one
  auth abstraction.
- **Placeholder engine** (`placeholders/`): `PlaceholderResolver` as the single
  `${…}` engine, with the expression grammar, a resolution stack, the optional
  `${name?}` form, and the placeholder error types.
- **Generic primitives**: `CategoryLog` (category-tag facade over `tomLog`),
  `systemClock`, `AsyncShutdownCoordinator`, `MapFieldReader`, `YamlConfigWriter`
  (AST-preserving config writes), `promptSha256` (content-hash convention),
  `percentileDuration` / `LatencySummary` (nearest-rank percentile maths),
  `deepValueEquals` / `deepValueHash` (collection equality), SQL helpers
  (`blobFromColumn` / `blobFromColumnOrNull`), JSON helpers (`decodeJsonObject`),
  `formatException`, a `TokenBucket` with snapshot/restore, token-estimate and
  `TtlCache` utilities, a Kahn topological plan ordering, a domain-free procedure
  re-rank scorer, a deliberation-cue classifier, a multi-format tool-call text
  parser, and the `PathScope` / `Deadline` / day-boundary / argument-guard
  sandbox primitives.

## 1.0.0

- Initial version. Generic agentic building blocks extracted from
  `tom_brain_substrate`: `CancellationToken` / `CancellationTokenSource`,
  `OperationCancelled`, `CloseGuard`, `buildUniqueById`, `textPreview`,
  `HttpDate`, and `YamlConfigReader`.

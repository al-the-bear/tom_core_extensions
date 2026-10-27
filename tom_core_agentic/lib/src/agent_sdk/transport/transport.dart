/// The [AgentSdkServerTransport] seam.
///
/// This file is deliberately host-free: it names nothing about VS Code, about
/// Node, about sockets or child processes. It is the whole contract the
/// provider is written against, so the hosted and standalone paths are two
/// implementations of one thing rather than two features that happen to do
/// something similar.
///
/// The surface is the minimum a provider needs:
///
///  - **send** a composed prompt (instruction + already-assembled context),
///  - **stream** the completion back,
///  - **report errors** in one typed shape with a machine-readable kind,
///  - **cancel** a running completion,
///  - **probe** reachability without side effects, so the availability gate
///  can be answered before any feature is offered.
///
/// Cancellation is the Dart-idiomatic form: **cancelling the subscription to
/// the stream returned by [AgentSdkServerTransport.complete] aborts the remote
/// completion.** There is no separate `cancel(requestId)` method, because a
/// request id would be a wire detail leaking into the seam and a second way to
/// express something `StreamSubscription.cancel` already expresses exactly.
///
/// **Liveness is reported by the transport and bounded above it.** The stream
/// carries [AgentSdkCompletionEvent]s rather than bare text: a
/// [AgentSdkTrailed] for everything the run does that its trail records
/// — thinking, text, tool calls and results, retries, usage — and
/// a [AgentSdkLiveness] whenever the far end shows it is alive without
/// saying anything the trail records. The transport holds **no** stall bound of its own — the
///  gap bound is applied by the provider over whatever stream any
/// transport returns (`boundedAiRun`), so a third implementation
/// that never touches the CLI-server wire is bounded exactly as the two that
/// do. What an implementation owes the bound is evidence: a transport that
/// emits nothing for the gap is abandoned as
/// [LlmErrorKind.timeout], so one whose far end thinks in
/// silence must translate that silence into events, or it will be read as
/// dead.
library;

import 'package:tom_llm/tom_llm.dart';

/// One completion request at the transport layer.
///
/// [context] is **already assembled and already password-free** — the
/// transport receives text, never sections, so it structurally cannot reach a
/// password field. Nothing in this class can hold an application's model
/// object; that is the point of it existing rather than passing an
/// [LlmRequest] straight through.
final class AgentSdkCompletionRequest {
  /// The feature-supplied instruction.
  final String prompt;

  /// The assembled, password-free document context. Empty when the feature
  /// sends none.
  final String context;

  /// An optional system prompt. Feature-supplied, never document-derived.
  final String? systemPrompt;

  /// An optional model override; null means the far end's default.
  final String? model;

  /// The tools the model may call during this request, or null
  /// for a plain completion that can act on nothing.
  ///
  /// Narrow on purpose, like [context]: the transport is handed declarations
  /// and a function that answers a call **with text**, never the binding, the
  /// registry or a document. The tool runs in the app, behind its own gates
  /// and its password-excluding proxy; the transport only relays.
  final AgentSdkToolSet? tools;

  const AgentSdkCompletionRequest({
    required this.prompt,
    this.context = '',
    this.systemPrompt,
    this.model,
    this.tools,
  });

  /// The single string actually put on the wire.
  ///
  /// Composition lives here, on the value object, so both transports send
  /// byte-identical prompts for the same request — the two paths differ in how
  /// they reach a server, never in what they say to it.
  String get wirePrompt =>
      context.isEmpty ? prompt : '$prompt\n\n---\n\n$context';
}

/// One tool as the model is told about it: the registry entry's name,
/// summary and JSON-Schema arguments, unchanged.
typedef AgentSdkToolDeclaration = ({
  String name,
  String description,
  Map<String, Object?> inputSchema,
});

/// The tools a request offers, reduced to what a transport needs to relay a
/// call.
final class AgentSdkToolSet {
  /// The in-process MCP server the tools are declared on; the model sees each
  /// as `mcp__<serverName>__<tool>` ([agentSdkMcpToolName]).
  final String serverName;

  /// Every tool the model may call, generated from the registry.
  final List<AgentSdkToolDeclaration> declarations;

  /// Runs the call `name` with `arguments` and answers the model. A refusal is
  /// an answer with `isError: true`, never a throw.
  final Future<LlmToolAnswer> Function(
    String name,
    Map<String, Object?> arguments,
  )
  call;

  const AgentSdkToolSet({
    required this.serverName,
    required this.declarations,
    required this.call,
  });

  /// The tool set of [binding], declared on the server [serverName]: its
  /// declarations, each call dispatched back into it — so whatever gates and
  /// records the binding applies to a call apply here, and nothing here can
  /// declare a tool the binding does not hold.
  factory AgentSdkToolSet.fromBinding(
    LlmToolBinding binding, {
    required String serverName,
  }) => AgentSdkToolSet(
    serverName: serverName,
    declarations: [
      for (final tool in binding.declarations)
        (
          name: tool.name,
          description: tool.description,
          inputSchema: tool.parametersSchema,
        ),
    ],
    call: binding.call,
  );
}

/// One thing a running completion says: an event of its trail, or the fact
/// that it is still alive.
///
/// Sealed, because the provider's stall bound counts every kind as evidence
/// of life and forwards exactly one of them: a third kind is a decision about
/// that bound, not a detail.
sealed class AgentSdkCompletionEvent {
  const AgentSdkCompletionEvent();
}

/// Something the run did, for its trail: the far end's start,
/// thinking, text, a tool call or its result, a retry, the usage, the end.
final class AgentSdkTrailed extends AgentSdkCompletionEvent {
  final LlmEvent event;

  const AgentSdkTrailed(this.event);

  @override
  String toString() => 'AgentSdkTrailed(${event.kind})';
}

/// The far end showed it is alive and said nothing the trail records: a
/// partial message's bookkeeping (`message_start`, a block opening or
/// closing), a progress event, a tool call being run.
///
/// Counted by the provider's gap bound and otherwise dropped. [source] names
/// the evidence. [unmappedType] is set when the far end sent a message kind
///  has no row for — the provider logs it once per run by type, so a
/// new SDK message is noticed rather than silently absorbed.
final class AgentSdkLiveness extends AgentSdkCompletionEvent {
  /// What the far end did — `stream_event`, `tool call`, …
  final String source;

  /// The type of a message the translator does not map, or null.
  final String? unmappedType;

  const AgentSdkLiveness(this.source, {this.unmappedType});

  @override
  String toString() => 'AgentSdkLiveness($source)';
}

/// The seam. One contract; the hosted and standalone paths implement it and
/// are selected at startup.
abstract class AgentSdkServerTransport {
  /// A stable, human-readable identifier used in diagnostics and in the
  /// settings UI ("AI: connected via …"). Not a display string.
  String get id;

  /// What the far end can do. Static per transport rather than a wire
  /// round-trip: both transports reach the same Anthropic models
  /// through the same Agent SDK, so the answer is known without asking, and a
  /// capability handshake would invent a question whose answer is fixed.
  LlmCapabilities get capabilities;

  /// Whether a live connection is currently held.
  bool get isConnected;

  /// Tests reachability **without side effects and without throwing**.
  ///
  /// Returns false rather than raising, because the caller is answering the gate's
  /// availability question, not performing an operation. A probe must not
  /// leave a connection behind that [connect] would then have to reconcile.
  Future<bool> probe();

  /// Why the last [probe] answered false, phrased as a remedy.
  ///
  /// A bool is the right answer for the *gate* and the wrong answer for the
  /// *user*: "not reachable" is true of a missing Node runtime, a missing
  /// server script and an editor whose CLI server was never started, and those
  /// three have nothing in common except that none of them is actionable from
  /// that sentence. [connect] already produces a remedy-naming message, but a
  /// candidate that fails to probe is never connected — so without this the
  /// careful message is only ever seen in the race where a server disappears
  /// between the scan and the handshake.
  ///
  /// Null means "no reason recorded" — either the transport was never probed,
  /// or the probe succeeded. Implementations set it on every false probe.
  String? get unavailableReason => null;

  /// Something the user should be told **once** about a transport that is
  /// working, or null when there is nothing to say.
  ///
  /// Distinct from [unavailableReason] in the one way that matters: this does
  /// not degrade anything. The gate stays open, the completion is served, and
  /// the note exists because the transport resolved an ambiguity the user could
  /// not see it resolve. A fact like that has to reach the user through the
  /// same channel as a failure — it is worth exactly one sentence and never a
  /// second — but it must not be phrased or delivered as one.
  String? get selectionNotice => null;

  /// A function that builds, in another isolate, an unconnected transport
  /// reaching the same far end as this one — what a session isolate
  /// runs on. It captures only values that can be sent to another isolate.
  ///
  /// Null for a transport that can only run where it was made (a suite's
  /// in-memory stand-in), or one that has not yet found its far end; such a
  /// transport serves sessions hosted in the main isolate only.
  AgentSdkServerTransport Function()? get sessionCopy => null;

  /// Establishes the connection. Throws [LlmTransportException] with
  /// [LlmErrorKind.unreachable] when no server can be reached.
  Future<void> connect();

  /// Streams a completion. The stream emits a [AgentSdkTrailed] for every
  ///  event in order — text in [LlmTextDelta]s — and a
  /// [AgentSdkLiveness] whenever the far end is alive and says nothing the
  /// trail records. It closes on completion, after [LlmRunEnded] when the
  /// far end reported its end, and emits a [LlmTransportException] as its
  /// error.
  ///
  /// Cancelling the subscription aborts the remote completion. The transport
  /// applies no stall bound — the provider does, over this stream, for every
  /// transport alike (see the library comment).
  Stream<AgentSdkCompletionEvent> complete(AgentSdkCompletionRequest request);

  /// Releases the connection and everything the transport owns — for the
  /// standalone path, that includes terminating the child process it started.
  Future<void> close();
}

/// Why the availability gate is shut, as a kind a program can branch on.
///
/// The reason sentence is for the user; this is for the code that decides what
/// to *offer* beside it. Three of the four conditions have a remedy only the
/// user can perform somewhere else (start an editor, install Node), and one —
/// [notInstalled] — has a remedy the app can perform itself when asked, which
/// is the whole reason the kinds are told apart rather than all reported as
/// "unreachable".
enum AgentSdkUnavailableKind {
  /// The build wired no transport at all.
  notConfigured,

  /// A backend was expected and did not answer (an editor's CLI server that is
  /// not running, a server that died while starting).
  unreachable,

  /// No usable Node.js runtime: none was found, or the one found is below
  /// `requiredNodeMajorVersion`. The user installs Node; the app cannot.
  noRuntime,

  /// Node is fine, but the AI server's dependencies — Anthropic's Claude Agent
  /// SDK and what it needs — are not installed in this app's data folder, or
  /// were installed for an earlier version of the server. the app does not
  /// ship the SDK; the user installs it, from the
  /// app, by pressing Install.
  notInstalled,
}

/// What an on-demand install of a transport's server ended with.
final class AgentSdkInstallOutcome {
  /// Whether the server is now installed and passed its post-install check.
  final bool ok;

  /// Why it is not, as a sentence for the user; null when [ok].
  final String? failure;

  const AgentSdkInstallOutcome.succeeded() : ok = true, failure = null;

  const AgentSdkInstallOutcome.failed(String this.failure) : ok = false;

  @override
  String toString() => ok
      ? 'AgentSdkInstallOutcome(ok)'
      : 'AgentSdkInstallOutcome(failed: $failure)';
}

/// A transport that can say **which kind** of unavailable it is, and that can
/// install what it is missing when the user asks it to.
///
/// A separate interface rather than two more members on [AgentSdkServerTransport],
/// because only the standalone transport has anything to install, and every
/// other implementation — the hosted one, the suites' stand-ins — would carry
/// a member whose only honest body is "nothing". The selector asks with `is`.
abstract interface class AgentSdkInstallableTransport
    implements AgentSdkServerTransport {
  /// The kind of the last false [probe], or null when the last probe
  /// succeeded or none has run.
  AgentSdkUnavailableKind? get unavailableKind;

  /// Installs the server's dependencies. Never throws: a failed install is an
  /// outcome the user is shown, not an error the caller has to catch.
  ///
  /// Only ever called because the user asked — it downloads third-party
  /// software, and nothing in the app may do that on its own initiative.
  Future<AgentSdkInstallOutcome> install({
    void Function(String line)? onProgress,
  });
}

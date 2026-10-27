/// The per-request binding a tool-capable provider receives, the in-process
/// MCP server rendered from it, and the multi-call agent run.
///
/// **One registry, presentations that render it.** A provider sees the tool
/// set either as the contract's tool declarations
/// ([AgentToolBinding.declarations], or their Anthropic shape
/// [AgentToolBinding.nativeDeclarations]) or through the in-process MCP server
/// ([AgentInProcessMcpServer]). Both are generated from
/// [AgentToolBinding.registry] on every call and both dispatch back into it
/// through [AgentToolRegistry.invoke] — so neither can declare a tool the
/// registry does not hold, nor run one without the gates and the audit.
///
/// **No transport.** Nothing here binds a port, opens a socket or listens on a
/// pipe: the MCP server is a method a caller calls with a message and awaits an
/// answer from.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:tom_llm/tom_llm.dart';

import 'audit.dart';
import 'errors.dart';
import 'invocation.dart';
import 'preview_then_apply.dart';
import 'tool.dart';

/// One tool call made during a run, as the preview shows it and the run
/// reports it.
final class AgentRunStep {
  /// 1-based, in the order the calls were made.
  final int index;
  final String toolName;

  /// Null when the call completed; the refusal otherwise.
  final AgentToolException? error;

  /// For a dry run: the call needs execution, which a dry run does not
  /// perform, so its outcome is unknown rather than simulated.
  final bool notSimulated;

  /// What the call was given — kept so the run can be dry-run again from where
  /// it started.
  final Map<String, Object?> arguments;

  /// What the call answered, when it completed.
  final Object? result;

  const AgentRunStep({
    required this.index,
    required this.toolName,
    this.error,
    this.notSimulated = false,
    this.arguments = const {},
    this.result,
  });

  bool get ok => error == null && !notSimulated;
}

/// What a dispatched call hands back to the model.
final class AgentToolResult {
  final bool isError;

  /// The tool's result, or `{code, message, argument?, step?}` for a refusal.
  final Object? value;

  const AgentToolResult._(this.isError, this.value);

  /// The result as text, for a presentation whose results are text.
  String toText() => jsonEncode(value);
}

/// `{invocation, registry}` for one request, plus the context the calls run
/// against.
///
/// **Per request, never installed.** A provider receives a binding on the
/// request that may use it and holds it for that request only, so an
/// invocation's scope and consent cannot outlive the action that granted them.
final class AgentToolBinding<C extends AgentToolContext>
    implements LlmToolBinding {
  AgentToolBinding({required this.context, required this.registry});

  final C context;
  final AgentToolRegistry<C> registry;

  AgentInvocation get invocation => context.invocation;

  final List<AgentRunStep> _steps = [];

  /// Every call made through [dispatch], in order.
  List<AgentRunStep> get steps => List.unmodifiable(_steps);

  /// The first call that was refused or failed, if any.
  AgentRunStep? get failure {
    for (final step in _steps) {
      if (step.error != null) return step;
    }
    return null;
  }

  /// The tool set as the contract declares tools — one descriptor per tool in
  /// [registry], generated every time.
  @override
  List<ToolDescriptor> get declarations => [
    for (final tool in registry.tools)
      ToolDescriptor(
        name: tool.name,
        description: tool.summary,
        parametersSchema: tool.arguments.toJsonSchema(),
      ),
  ];

  /// Runs the call [name] with [arguments] and answers what the model is told —
  /// a refusal included, as an error answer.
  @override
  Future<LlmToolAnswer> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final answer = await _dispatch(name, arguments, AgentAuditEntryPoint.agent);
    return (isError: answer.isError, text: answer.toText());
  }

  /// The tool set as native provider tool declarations —
  /// `{name, description, input_schema}`, the tool-use shape of the Anthropic
  /// Messages API. Generated from [registry] every time.
  List<Map<String, Object?>> nativeDeclarations() => [
    for (final tool in registry.tools)
      {
        'name': tool.name,
        'description': tool.summary,
        'input_schema': tool.arguments.toJsonSchema(),
      },
  ];

  /// Runs the call [name] with [input] and answers the full result.
  ///
  /// A refusal is an **answer**, not an exception: the model is told the code
  /// and message and may react. Once a call has failed, the run it belongs to
  /// will be rolled back, so every later call is refused with
  /// `E_TRANSACTION_FAILED` rather than performed — performing it would write
  /// into a unit that is about to be discarded. That refusal is recorded like
  /// any other.
  ///
  /// The seam a test drives a run through when it asserts on the result's
  /// value; [call] answers the model only.
  @visibleForTesting
  Future<AgentToolResult> dispatch(String name, Map<String, Object?> input) =>
      _dispatch(name, input, AgentAuditEntryPoint.agent);

  Future<AgentToolResult> _dispatch(
    String name,
    Map<String, Object?> input,
    AgentAuditEntryPoint entry,
  ) async {
    final index = _steps.length + 1;
    final earlier = failure;
    final arguments = Map<String, Object?>.unmodifiable(input);
    try {
      final Object? value;
      if (earlier != null) {
        value = await agentAuditEntering(
          entry,
          () => AgentToolRegistry.refuse(
            context,
            name,
            input,
            () => throw AgentToolException(
              AgentToolErrorCode.transactionFailed,
              'Step ${earlier.index} of this run failed, so the run will be '
              'rolled back; no further calls are performed.',
            ),
          ),
        );
      } else {
        value = await agentAuditEntering(
          entry,
          () => registry.invoke(context, name, input),
        );
      }
      _steps.add(
        AgentRunStep(
          index: index,
          toolName: name,
          arguments: arguments,
          result: value,
        ),
      );
      return AgentToolResult._(false, value);
    } on AgentToolException catch (e) {
      _steps.add(
        AgentRunStep(
          index: index,
          toolName: name,
          error: e,
          arguments: arguments,
        ),
      );
      return AgentToolResult._(true, e.toMap());
    } on Object {
      // A defect in a tool, not a refusal. The model is told the call failed
      // and nothing about why: an exception's text is not a refusal message and
      // may carry anything.
      const e = AgentToolException(
        AgentToolErrorCode.transactionFailed,
        'The call failed.',
      );
      _steps.add(
        AgentRunStep(
          index: index,
          toolName: name,
          error: e,
          arguments: arguments,
        ),
      );
      return AgentToolResult._(true, e.toMap());
    }
  }
}

// ---------------------------------------------------------------------------
// the in-process MCP presentation
// ---------------------------------------------------------------------------

/// An MCP server, **in-process**: a JSON-RPC 2.0 message handler a caller
/// invokes directly. It binds nothing and listens on nothing.
///
/// It is a presentation of [binding]'s registry: `tools/list` is generated from
/// it and `tools/call` dispatches into it, so an MCP-only tool or an MCP-only
/// bypass cannot exist. The session is the binding's invocation — there is no
/// session credential, because there is no remote party.
///
/// **It stamps its own calls.** Every audit entry a `tools/call` records
/// carries `entry: mcp`, whatever context the binding was built with: the
/// surface a call arrived on is this server's fact, not its caller's.
final class AgentInProcessMcpServer {
  AgentInProcessMcpServer(this.binding, {required this.serverName});

  final AgentToolBinding binding;

  /// The name `initialize` reports as `serverInfo.name`.
  final String serverName;

  /// The MCP protocol revision this server answers `initialize` with.
  static const protocolVersion = '2025-06-18';

  /// Handles one JSON-RPC message: answers a request, or null for a
  /// notification.
  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final id = message['id'];
    final method = message['method'];
    final isNotification = !message.containsKey('id');
    Map<String, Object?> result(Object? value) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': value,
    };
    Map<String, Object?> error(int code, String text) => {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': text},
    };

    if (message['jsonrpc'] != '2.0' || method is! String) {
      return isNotification ? null : error(-32600, 'Invalid request.');
    }
    if (isNotification) return null;
    final params = message['params'];

    switch (method) {
      case 'initialize':
        return result({
          'protocolVersion': protocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': serverName, 'version': '1'},
        });
      case 'ping':
        return result(const <String, Object?>{});
      case 'tools/list':
        return result({
          'tools': [
            for (final tool in binding.registry.tools) tool.toJsonSchema(),
          ],
        });
      case 'tools/call':
        if (params is! Map || params['name'] is! String) {
          return error(-32602, 'tools/call needs a "name".');
        }
        final arguments = params['arguments'] ?? const <String, Object?>{};
        if (arguments is! Map) {
          return error(-32602, '"arguments" must be an object.');
        }
        final answer = await binding._dispatch(
          params['name']! as String,
          arguments.cast<String, Object?>(),
          AgentAuditEntryPoint.mcp,
        );
        return result({
          'content': [
            {'type': 'text', 'text': answer.toText()},
          ],
          'isError': answer.isError,
        });
      default:
        return error(-32601, 'Method not found: $method');
    }
  }
}

// ---------------------------------------------------------------------------
// the multi-call run
// ---------------------------------------------------------------------------

enum AgentRunStatus {
  /// Every call completed and the user accepted.
  accepted,

  /// Every call completed and the user rejected the preview: rolled back.
  rejected,

  /// A call was refused or failed, or the model could not be reached: rolled
  /// back, with [AgentRunOutcome.failedStep] naming the call when a call was
  /// the cause.
  rolledBack,
}

final class AgentRunOutcome {
  final AgentRunStatus status;
  final List<AgentRunStep> steps;

  /// The model's closing answer, when it gave one.
  final String answer;

  /// Why a run ended without a failed call — the model could not be reached,
  /// or the drive itself threw.
  final Object? error;

  /// The dry run of [steps], as the preview shows it: each call performed
  /// again against copies of the resources **as they were before the run**,
  /// so the user sees which calls the guard would refuse before keeping
  /// anything. Empty outside a preview.
  ///
  /// It can disagree with [steps], and that is what it is for: a call that
  /// succeeded only because a program step before it wrote something is
  /// refused here, because a dry run does not run programs (`notSimulated`).
  final List<AgentRunStep> dryRun;

  const AgentRunOutcome({
    required this.status,
    required this.steps,
    this.answer = '',
    this.error,
    this.dryRun = const [],
  });

  /// The dry-run verdict for the call [index] (1-based), when there is one.
  AgentRunStep? dryRunOf(int index) {
    for (final step in dryRun) {
      if (step.index == index) return step;
    }
    return null;
  }

  /// The 1-based index of the call that ended the run.
  int? get failedStep {
    for (final step in steps) {
      if (step.error != null) return step.index;
    }
    return null;
  }
}

/// One agent run: a model-driven sequence of tool calls that is **atomic and
/// reversible as a unit**.
///
/// It adds no mechanism of its own. The run is a proposal under
/// [AgentPreviewThenApply] over [AgentToolContext.runAtomically]: the calls
/// write while the model works, so the user sees the result in place while
/// deciding; a refused call is a proposal that cannot be kept; and rejecting
/// is the scope's rollback.
abstract final class AgentRun {
  /// Runs [drive] — which asks the model and lets it call tools through
  /// [binding] — as one atomic run, then asks [confirm] whether to keep it.
  ///
  /// [binding]'s context must record into a **staging** log: its entries are
  /// appended to [audit] only when the run has ended, marked `rolled-back` if
  /// it did not survive, because an append-only trail cannot be corrected
  /// after the fact.
  static Future<AgentRunOutcome> execute<C extends AgentToolContext>({
    required AgentToolBinding<C> binding,
    required AgentAuditLog audit,
    required Future<String> Function(AgentToolBinding<C> binding) drive,
    Future<bool> Function(AgentRunOutcome preview)? confirm,
    String label = 'Agent run',
  }) async {
    final staging = binding.context.audit;
    if (identical(staging, audit)) {
      throw ArgumentError.value(
        audit,
        'audit',
        'must not be the binding\'s own log: a run stages its entries and '
            'commits them once it knows whether it survived',
      );
    }
    final before = staging.entries.length;
    // Taken before the first call, so the preview's dry run starts where the
    // run started rather than where it ended.
    final start = binding.context.dryRunCopy() as C;
    final outcome = await AgentPreviewThenApply.run<String>(
      atomically: binding.context.runAtomically,
      label: label,
      propose: () => drive(binding),
      // A refused call makes the run incomplete: it is rolled back without
      // asking, because there is nothing whole to decide about.
      refuse: (_) => binding.failure,
      confirm: (answer) async {
        final ask = confirm;
        if (ask == null) return true;
        final steps = binding.steps;
        return ask(
          AgentRunOutcome(
            status: AgentRunStatus.accepted,
            steps: steps,
            answer: answer,
            dryRun: await _simulate(start, binding.registry, steps),
          ),
        );
      },
    );
    final status = switch (outcome.status) {
      AgentProposalStatus.accepted => AgentRunStatus.accepted,
      AgentProposalStatus.rejected => AgentRunStatus.rejected,
      AgentProposalStatus.failed => AgentRunStatus.rolledBack,
    };
    final staged = staging.entries.sublist(before);
    audit.append(
      status == AgentRunStatus.accepted
          ? staged
          : [for (final entry in staged) entry.asRolledBack()],
    );
    return AgentRunOutcome(
      status: status,
      steps: binding.steps,
      answer: outcome.proposal ?? '',
      error: outcome.error,
    );
  }

  /// The dry run: performs [steps] against **copies** of what the binding's
  /// context reaches and reports what each would do, so a preview can say
  /// which calls would be refused before anything is written.
  ///
  /// Every step is attempted, in order, against the copy as the earlier steps
  /// left it. A step that needs execution is not performed — running a
  /// program is not a simulation — and is reported `notSimulated`.
  static Future<List<AgentRunStep>> dryRun<C extends AgentToolContext>(
    AgentToolBinding<C> binding,
    List<({String name, Map<String, Object?> arguments})> steps,
  ) => _simulate(binding.context.dryRunCopy() as C, binding.registry, [
    for (var i = 0; i < steps.length; i++)
      AgentRunStep(
        index: i + 1,
        toolName: steps[i].name,
        arguments: steps[i].arguments,
      ),
  ]);

  /// Performs [steps] in order on [scratch] — a dry-run copy — and reports
  /// each.
  ///
  /// A step that carries the [AgentRunStep.result] of a real call is replayed
  /// **as that call**: something the real call created has an id the copy's
  /// call did not mint, so every later argument naming the real id is
  /// rewritten to the copy's ([AgentToolContext.createdIdKeys]). Without that,
  /// a replayed run would refuse every call that touched what it had just
  /// created.
  static Future<List<AgentRunStep>> _simulate<C extends AgentToolContext>(
    C scratch,
    AgentToolRegistry<C> registry,
    List<AgentRunStep> steps,
  ) async {
    final ids = <String, String>{};
    final report = <AgentRunStep>[];
    for (final step in steps) {
      final arguments = _renamed(step.arguments, ids) as Map<String, Object?>;
      if (registry[step.toolName]?.needsExecution ?? false) {
        report.add(
          AgentRunStep(
            index: step.index,
            toolName: step.toolName,
            arguments: arguments,
            notSimulated: true,
          ),
        );
        continue;
      }
      try {
        final result = await registry.invoke(scratch, step.toolName, arguments);
        final live = step.result;
        if (live is Map && result is Map) {
          for (final key in scratch.createdIdKeys) {
            final from = live[key];
            final to = result[key];
            if (from is String && to is String && from != to) ids[from] = to;
          }
        }
        report.add(
          AgentRunStep(
            index: step.index,
            toolName: step.toolName,
            arguments: arguments,
            result: result,
          ),
        );
      } on AgentToolException catch (e) {
        report.add(
          AgentRunStep(
            index: step.index,
            toolName: step.toolName,
            arguments: arguments,
            error: e,
          ),
        );
      }
    }
    return report;
  }

  /// [value] with every string [ids] maps replaced, at any depth.
  static Object? _renamed(Object? value, Map<String, String> ids) {
    if (ids.isEmpty) return value;
    return switch (value) {
      final String text => ids[text] ?? text,
      final Map map => <String, Object?>{
        for (final entry in map.entries)
          entry.key as String: _renamed(entry.value, ids),
      },
      final List list => [for (final item in list) _renamed(item, ids)],
      _ => value,
    };
  }
}

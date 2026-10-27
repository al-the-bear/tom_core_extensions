/// The refusals a tool call can end in.
///
/// A caller-visible error is a **refusal, not a negotiation**: no code carries
/// a hint that would let a caller construct a call that widens its own
/// permissions, and a code that names a missing target says the same thing
/// whether the target is unknown or deliberately left out of the surface.
library;

import 'scope.dart';

/// One refusal kind: the stable `E_…` spelling every presentation reports and
/// the reason the audit trail records when the refusal carries no truer one.
///
/// A class rather than an enum so an application adds the codes its own tools
/// need ([AgentToolErrorCode.new]) beside the general ones declared here,
/// without a second exception type.
final class AgentToolErrorCode {
  /// The spelling on the wire, `E_` and upper case.
  final String wire;

  /// How the audit trail names a refusal with this code.
  final String auditReason;

  /// Whether the code reports work that passed every gate and then did not
  /// complete — a failure — rather than a refusal. The audit trail records the
  /// two differently.
  final bool isFailure;

  const AgentToolErrorCode(
    this.wire,
    this.auditReason, {
    this.isFailure = false,
  });

  /// Schema violation, unknown tool, malformed argument.
  static const invalidArgument = AgentToolErrorCode(
    'E_INVALID_ARGUMENT',
    'invalid-argument',
  );

  /// The target does not exist **for this caller**. Identical whether the
  /// target is unknown or is excluded from the surface, so the surface is not
  /// an existence oracle.
  static const notFound = AgentToolErrorCode('E_NOT_FOUND', 'not-found');

  /// Outside the invocation's scope. Names the gate that refused, never what
  /// the target is.
  static const outOfScope = AgentToolErrorCode(
    'E_OUT_OF_SCOPE',
    'out-of-scope',
  );

  /// A write under a read-only invocation.
  static const readOnly = AgentToolErrorCode('E_READ_ONLY', 'read-only');

  /// A step of the call failed and the call was rolled back.
  static const transactionFailed = AgentToolErrorCode(
    'E_TRANSACTION_FAILED',
    'transaction-failed',
    isFailure: true,
  );

  @override
  String toString() => wire;
}

/// A refused tool call.
///
/// Thrown rather than returned because a tool's body is ordinary Dart, and the
/// alternative — every step returning a result union — would put the refusal
/// check at every call site inside the tool rather than at its edge.
final class AgentToolException implements Exception {
  final AgentToolErrorCode code;
  final String message;

  /// The offending argument, when one argument is at fault.
  final String? argument;

  /// The 1-based step that failed, for a call or a run whose steps are the
  /// mutations it applied: one past the number it applied before it stopped.
  final int? step;

  /// The **true** reason, for the audit trail only — for instance the reason a
  /// target was excluded behind a [AgentToolErrorCode.notFound]. Never
  /// rendered by [toMap] or [toString]: the caller's refusal is the same
  /// whichever reason is behind it.
  final String? _auditReason;

  /// The scope gate that refused the call, for the audit trail only.
  final AgentScopeGate? _gate;

  const AgentToolException(
    this.code,
    this.message, {
    this.argument,
    this.step,
    String? auditReason,
    AgentScopeGate? gate,
  }) : _auditReason = auditReason,
       _gate = gate;

  /// What the audit records as the deny reason.
  String get auditReason =>
      _auditReason ?? _gate?.auditReason ?? code.auditReason;

  /// The guard gate behind the refusal, or null when no gate refused it.
  AgentScopeGate? get gate => _gate;

  Map<String, Object?> toMap() => {
    'code': code.wire,
    'message': message,
    'argument': ?argument,
    'step': ?step,
  };

  @override
  String toString() =>
      '${code.wire}: $message'
      '${argument == null ? '' : ' (argument: $argument)'}'
      '${step == null ? '' : ' (step: $step)'}';
}

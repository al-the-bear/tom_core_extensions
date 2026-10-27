/// The invocation record every entry into a tool surface carries.
///
/// Two properties are why it is a record rather than two flags on a context:
///
/// * **Consent is minted, not configured.** `allowExecution` — whether a tool
///   that runs a program may run one — exists only on an invocation, an
///   invocation is immutable, and the one constructor that sets it true takes
///   the application's residual-risk statement as proof it was shown. "Off
///   unless granted" is therefore an invariant of the type, not a default
///   someone can forget.
/// * **The origin is a closed set.** One value, [AgentOrigin.localAgent], so no
///   code path can construct a remote-origin invocation: there is no value to
///   construct it with.
library;

import 'dart:math';

import 'scope.dart';

/// Where an invocation came from. **One value.**
enum AgentOrigin {
  localAgent('local-agent');

  const AgentOrigin(this.wire);

  /// The spelling on the wire and in the audit.
  final String wire;

  /// The origin named [wire], or a refusal. Anything but `local-agent` is
  /// refused rather than mapped: a network origin must not be constructible
  /// by a typo, a configuration key or a test hook.
  static AgentOrigin parse(String wire) {
    for (final origin in values) {
      if (origin.wire == wire) return origin;
    }
    throw ArgumentError.value(
      wire,
      'origin',
      'is not an agent origin this surface admits (only "local-agent")',
    );
  }
}

/// The statement an application shows a user before execution is granted, as
/// the value an execution grant is checked against.
///
/// An application declares one, written once; its grant affordance renders
/// [statement] and hands back the text it showed to
/// [AgentInvocation.withExecution], which refuses to mint unless the two are
/// the same. So a grant cannot be made by code that never put the statement in
/// front of anyone.
final class AgentExecutionGrant {
  final String statement;

  const AgentExecutionGrant(this.statement);
}

/// One entry into the tool surface. Immutable once minted; widening requires
/// a **new** invocation minted by a new user action.
final class AgentInvocation {
  /// For correlating the audit entries of one invocation.
  final String invocationId;

  final AgentOrigin origin;

  /// False unless minted by [AgentInvocation.withExecution].
  final bool allowExecution;

  /// What this invocation may touch, read by the one guard for every target
  /// of every call.
  final AgentScope scope;

  /// How many mutations a tool-driven program run may apply, and how long it
  /// may take. Exceeding either aborts the run and rolls it back.
  final int stepBudget;
  final Duration timeBudget;

  static const defaultStepBudget = 1000;
  static const defaultTimeBudget = Duration(seconds: 30);

  const AgentInvocation._({
    required this.invocationId,
    required this.origin,
    required this.allowExecution,
    required this.scope,
    required this.stepBudget,
    required this.timeBudget,
  });

  /// An invocation without execution — the ordinary one.
  factory AgentInvocation.mint({
    required AgentScope scope,
    int stepBudget = defaultStepBudget,
    Duration timeBudget = defaultTimeBudget,
  }) => AgentInvocation._(
    invocationId: _newId(),
    origin: AgentOrigin.localAgent,
    allowExecution: false,
    scope: scope,
    stepBudget: stepBudget,
    timeBudget: timeBudget,
  );

  /// An invocation **with** execution — an explicit, per-invocation user act.
  ///
  /// [residualRiskShown] must be [grant]'s statement, exactly: the affordance
  /// that granted consent passes the text it showed.
  factory AgentInvocation.withExecution({
    required AgentExecutionGrant grant,
    required String residualRiskShown,
    required AgentScope scope,
    int stepBudget = defaultStepBudget,
    Duration timeBudget = defaultTimeBudget,
  }) {
    if (residualRiskShown != grant.statement) {
      throw ArgumentError.value(
        residualRiskShown,
        'residualRiskShown',
        'execution is granted only against the residual-risk statement',
      );
    }
    return AgentInvocation._(
      invocationId: _newId(),
      origin: AgentOrigin.localAgent,
      allowExecution: true,
      scope: scope,
      stepBudget: stepBudget,
      timeBudget: timeBudget,
    );
  }

  static final _random = Random.secure();

  static String _newId() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  @override
  String toString() =>
      'AgentInvocation($invocationId, ${origin.wire}, '
      'execution: $allowExecution, $scope)';
}

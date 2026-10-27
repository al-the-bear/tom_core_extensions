import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_tools.dart';

void main() {
  group('the argument schema', () {
    const schema = AgentToolSchema([
      AgentToolArgument('id', AgentToolValueType.string, required: true),
      AgentToolArgument('count', AgentToolValueType.integer),
      AgentToolArgument(
        'mode',
        AgentToolValueType.string,
        allowed: ['a', 'b'],
        description: 'Which mode.',
      ),
    ]);

    AgentToolException refusal(Map<String, Object?> raw) {
      try {
        schema.validate(raw);
      } on AgentToolException catch (e) {
        return e;
      }
      fail('validated $raw');
    }

    test('declared arguments pass and a null reads as absent', () {
      expect(schema.validate({'id': 'x', 'count': 2, 'mode': null}), {
        'id': 'x',
        'count': 2,
      });
    });

    test('an unknown key is refused by name rather than dropped', () {
      final e = refusal({'id': 'x', 'cuont': 1});
      expect(e.code, AgentToolErrorCode.invalidArgument);
      expect(e.argument, 'cuont');
    });

    test('a missing required argument, a wrong type and a value outside the '
        'allowed set are each refused naming the argument', () {
      expect(refusal({}).argument, 'id');
      expect(refusal({'id': 'x', 'count': '2'}).argument, 'count');
      expect(refusal({'id': 'x', 'count': true}).argument, 'count');
      expect(refusal({'id': 'x', 'mode': 'c'}).argument, 'mode');
    });

    test('the JSON schema lists every argument, the required ones, and no '
        'additional properties', () {
      final json = schema.toJsonSchema();
      expect(json['required'], ['id']);
      expect(json['additionalProperties'], isFalse);
      expect((json['properties']! as Map)['mode'], {
        'type': 'string',
        'description': 'Which mode.',
        'enum': ['a', 'b'],
      });
    });

    test('a refusal renders its code, message, argument and step, never its '
        'audit reason or gate', () {
      const e = AgentToolException(
        AgentToolErrorCode.notFound,
        'No such thing.',
        argument: 'id',
        step: 2,
        auditReason: 'secret-excluded',
        gate: AgentScopeGate.excluded,
      );
      expect(e.toMap(), {
        'code': 'E_NOT_FOUND',
        'message': 'No such thing.',
        'argument': 'id',
        'step': 2,
      });
      expect(e.toString(), isNot(contains('secret')));
      expect(e.auditReason, 'secret-excluded');
      expect(e.gate, AgentScopeGate.excluded);
    });

    test('a refusal without its own reason falls back to the gate, then the '
        'code', () {
      expect(
        const AgentToolException(
          AgentToolErrorCode.outOfScope,
          'Refused.',
          gate: AgentScopeGate.kind,
        ).auditReason,
        'type-out-of-scope',
      );
      expect(
        const AgentToolException(AgentToolErrorCode.readOnly, 'R.').auditReason,
        'read-only',
      );
    });
  });

  group('the guard', () {
    const excluded = AgentGuardTarget(id: 'x', kind: 'plain', excluded: true);
    const plain = AgentGuardTarget(id: 'x', kind: 'plain');

    test('gate 1 refuses an excluded target under every scope, before any '
        'grant — a read-only one, and one whose id set names it', () {
      for (final scope in [
        AgentScope(),
        AgentScope(allowWrite: false),
        AgentScope(allowedIds: {'x'}, allowedKinds: {'plain'}),
      ]) {
        expect(
          agentGuard(scope, excluded, write: true),
          AgentScopeGate.excluded,
        );
        expect(
          agentGuard(scope, excluded, write: false),
          AgentScopeGate.excluded,
        );
      }
    });

    test('gates 2, 3 and 4 in that order; reads never meet gate 2', () {
      final narrow = AgentScope(
        allowWrite: false,
        allowedKinds: {'todo'},
        allowedIds: {'y'},
      );
      expect(agentGuard(narrow, plain, write: true), AgentScopeGate.write);
      expect(agentGuard(narrow, plain, write: false), AgentScopeGate.kind);
      expect(
        agentGuard(
          narrow,
          const AgentGuardTarget(id: 'x', kind: 'todo'),
          write: false,
        ),
        AgentScopeGate.id,
      );
      expect(
        agentGuard(
          narrow,
          const AgentGuardTarget(id: 'y', kind: 'todo'),
          write: false,
        ),
        isNull,
      );
    });

    test('a target being created is admitted at gate 4 through its parent', () {
      final scope = AgentScope(allowedIds: {'p'});
      expect(
        agentGuard(
          scope,
          const AgentGuardTarget.creating('plain', parentId: 'p'),
          write: true,
        ),
        isNull,
      );
      expect(
        agentGuard(
          scope,
          const AgentGuardTarget.creating('plain', parentId: 'q'),
          write: true,
        ),
        AgentScopeGate.id,
      );
      expect(
        agentGuard(
          scope,
          const AgentGuardTarget.creating('plain'),
          write: true,
        ),
        AgentScopeGate.id,
      );
    });

    test('a scope copies what it is given, is immutable, and says whether it '
        'covers a set of kinds', () {
      final ids = {'x'};
      final scope = AgentScope(allowedIds: ids, allowedKinds: {'a', 'b'});
      ids.add('y');
      expect(scope.allowedIds, {'x'});
      expect(() => scope.allowedIds!.add('z'), throwsUnsupportedError);
      expect(() => scope.allowedKinds!.add('c'), throwsUnsupportedError);
      expect(scope.covers(['a']), isFalse, reason: 'an id set narrows it');
      expect(AgentScope(allowedKinds: {'a', 'b'}).covers(['a', 'b']), isTrue);
      expect(AgentScope(allowedKinds: {'a'}).covers(['a', 'b']), isFalse);
      expect(AgentScope().covers(['anything']), isTrue);
      expect(AgentScope().admitsKind('anything'), isTrue);
    });
  });

  group('the invocation', () {
    const grant = AgentExecutionGrant('Residual risk: it runs as you.');

    test(
      'an ordinary invocation carries no execution consent and its scope',
      () {
        final scope = AgentScope(allowWrite: false);
        final invocation = AgentInvocation.mint(scope: scope);
        expect(invocation.allowExecution, isFalse);
        expect(invocation.scope, same(scope));
        expect(invocation.origin, AgentOrigin.localAgent);
        expect(invocation.stepBudget, AgentInvocation.defaultStepBudget);
        expect(invocation.timeBudget, AgentInvocation.defaultTimeBudget);
      },
    );

    test('execution is granted only against the statement, exactly', () {
      final granted = AgentInvocation.withExecution(
        grant: grant,
        residualRiskShown: grant.statement,
        scope: AgentScope(),
        stepBudget: 5,
        timeBudget: const Duration(seconds: 1),
      );
      expect(granted.allowExecution, isTrue);
      expect(granted.stepBudget, 5);
      for (final shown in ['', 'Residual risk.', '${grant.statement} ']) {
        expect(
          () => AgentInvocation.withExecution(
            grant: grant,
            residualRiskShown: shown,
            scope: AgentScope(),
          ),
          throwsArgumentError,
          reason: shown,
        );
      }
    });

    test('every invocation has its own id', () {
      final ids = {
        for (var i = 0; i < 50; i++)
          AgentInvocation.mint(scope: AgentScope()).invocationId,
      };
      expect(ids, hasLength(50));
      expect(ids.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('the origin is a closed set of one', () {
      expect(AgentOrigin.values, [AgentOrigin.localAgent]);
      expect(AgentOrigin.parse('local-agent'), AgentOrigin.localAgent);
      for (final wire in ['rest', 'mcp-remote', 'LOCAL-AGENT', '']) {
        expect(() => AgentOrigin.parse(wire), throwsArgumentError);
      }
    });
  });
}

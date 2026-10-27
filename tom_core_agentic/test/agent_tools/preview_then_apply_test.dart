import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_tools.dart';

/// An atomic scope over one list: rolled back to its copy when the body throws.
AgentAtomicScope _over(List<String> list, List<String> labels) =>
    (label, body) async {
      labels.add(label);
      final saved = List.of(list);
      try {
        await body();
      } catch (_) {
        list
          ..clear()
          ..addAll(saved);
        rethrow;
      }
    };

void main() {
  test('an accepted proposal is applied inside the same scope it was made '
      'in', () async {
    final list = <String>[];
    final labels = <String>[];
    final outcome = await AgentPreviewThenApply.run<String>(
      atomically: _over(list, labels),
      label: 'Generate',
      propose: () async {
        list.add('draft');
        return 'text';
      },
      confirm: (p) async => true,
      apply: (p) => list.add(p),
    );
    expect(outcome.status, AgentProposalStatus.accepted);
    expect(outcome.proposal, 'text');
    expect(list, ['draft', 'text']);
    expect(labels, ['Generate']);
  });

  test('a rejected proposal leaves nothing behind', () async {
    final list = <String>[];
    final outcome = await AgentPreviewThenApply.run<String>(
      atomically: _over(list, []),
      label: 'L',
      propose: () async {
        list.add('draft');
        return 'text';
      },
      confirm: (p) async => false,
      apply: (p) => list.add(p),
    );
    expect(outcome.status, AgentProposalStatus.rejected);
    expect(outcome.proposal, 'text');
    expect(list, isEmpty);
  });

  test('a refused proposal is rolled back without being confirmed', () async {
    final list = <String>[];
    var asked = false;
    final outcome = await AgentPreviewThenApply.run<String>(
      atomically: _over(list, []),
      label: 'L',
      propose: () async {
        list.add('draft');
        return 'text';
      },
      refuse: (p) => 'incomplete',
      confirm: (p) async => asked = true,
    );
    expect(outcome.status, AgentProposalStatus.failed);
    expect(outcome.refusal, 'incomplete');
    expect(outcome.error, isNull);
    expect(asked, isFalse);
    expect(list, isEmpty);
  });

  test('a failure anywhere is a failed outcome, never a throw', () async {
    final list = <String>[];
    final outcome = await AgentPreviewThenApply.run<String>(
      atomically: _over(list, []),
      label: 'L',
      propose: () async => throw StateError('unreachable'),
      confirm: (p) async => true,
    );
    expect(outcome.status, AgentProposalStatus.failed);
    expect(outcome.proposal, isNull);
    expect(outcome.error, isA<StateError>());
  });
}

/// Preview-then-apply, as **one** mechanism every proposal goes through.
///
/// A proposal is a change somebody other than the user wants to make: a
/// generated paragraph, a set of suggested labels, an agent's sequence of tool
/// calls. Every one of them is shown before it is kept, and every one of them
/// is kept — or not — whole. That is a single shape, so it is a single
/// function, [AgentPreviewThenApply.run], whatever the proposal is:
///
///  1. **Propose**, inside one atomic scope over everything the proposal may
///     write. A proposal that writes while it is made (an agent run, whose
///     calls land so the user sees them in place) writes into that scope; one
///     that does not (a completion, which is text until accepted) leaves it
///     empty.
///  2. **Refuse** without asking, when the proposal cannot be kept — a call
///     was refused, so the run is incomplete. Nothing to decide.
///  3. **Confirm** — the user decides, looking at the preview.
///  4. **Apply** on acceptance, still inside the scope, so writes made while
///     proposing and writes made on acceptance are one undo entry.
///
/// Rejecting, refusing, and any failure along the way are the same act: the
/// scope is rolled back and records nothing. So "the user said no" leaves
/// everything exactly as "the model never answered" does, by construction
/// rather than by each caller remembering to undo.
library;

import 'dart:async';

/// How a proposal ended.
enum AgentProposalStatus {
  /// Accepted and applied.
  accepted,

  /// The user declined it. Rolled back; nothing recorded.
  rejected,

  /// It could not be kept — refused, or something threw while proposing,
  /// confirming or applying. Rolled back; nothing recorded.
  failed,
}

/// What [AgentPreviewThenApply.run] reports.
final class AgentProposalOutcome<P> {
  final AgentProposalStatus status;

  /// The proposal, or null when proposing itself failed.
  final P? proposal;

  /// What `refuse` answered, when the proposal was refused.
  final Object? refusal;

  /// What was thrown, when something was — never set together with [refusal].
  final Object? error;

  const AgentProposalOutcome({
    required this.status,
    this.proposal,
    this.refusal,
    this.error,
  });
}

/// Runs a body as one atomic unit — all of it rolled back together if it
/// throws. An application supplies one over whatever it writes (one undo group
/// per document, a database transaction, …).
typedef AgentAtomicScope =
    Future<void> Function(String label, Future<void> Function() body);

/// Preview-then-apply. See the library doc.
abstract final class AgentPreviewThenApply {
  /// Proposes, previews, and keeps or discards one proposal as a unit.
  ///
  /// [propose] runs inside [atomically] and may write. [refuse] answers
  /// non-null when a proposal cannot be kept, and then [confirm] is not asked.
  /// [confirm] answers whether the user keeps it. [apply] writes an accepted
  /// proposal, inside the same scope.
  ///
  /// Never throws: a failure is [AgentProposalStatus.failed] with the
  /// [AgentProposalOutcome.error], so a caller has one value to read whatever
  /// happened.
  static Future<AgentProposalOutcome<P>> run<P>({
    required AgentAtomicScope atomically,
    required String label,
    required Future<P> Function() propose,
    required Future<bool> Function(P proposal) confirm,
    FutureOr<void> Function(P proposal)? apply,
    Object? Function(P proposal)? refuse,
  }) async {
    P? proposal;
    Object? refusal;
    var status = AgentProposalStatus.accepted;
    Object? error;
    try {
      await atomically(label, () async {
        final made = await propose();
        proposal = made;
        refusal = refuse?.call(made);
        if (refusal != null) throw const _Discarded();
        if (!await confirm(made)) throw const _Discarded();
        await apply?.call(made);
      });
    } on _Discarded {
      status = refusal == null
          ? AgentProposalStatus.rejected
          : AgentProposalStatus.failed;
    } on Object catch (e) {
      status = AgentProposalStatus.failed;
      error = e;
    }
    return AgentProposalOutcome(
      status: status,
      proposal: proposal,
      refusal: refusal,
      error: error,
    );
  }
}

/// The internal signal that rolls a proposal back without being a failure.
class _Discarded implements Exception {
  const _Discarded();
}

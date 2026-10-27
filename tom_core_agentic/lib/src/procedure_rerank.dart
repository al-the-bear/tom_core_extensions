// Domain-free re-rank scoring for procedure selection.
//
// A procedure-selecting agent ranks candidate procedures for an incoming
// request by four factors: how close the candidate's intent embedding is to the
// request, how much of what the candidate needs (`requires`) the caller can
// supply, how often the candidate has succeeded, and how recently it last ran
// successfully. Folding those four scalars into one comparable number is pure
// arithmetic — it knows nothing about procedures, memory, or embeddings, only
// about four values in [0,1] and their relative weights. So it lives here,
// reusable from any agent runtime, exactly like `classifyDeliberationCue`.
//
// The owning layer (`tom_brain_procedure`) is responsible for *producing* the
// four factors from a Procedure node (cosine similarity, `CapabilitySet`
// coverage, the rolling success rate, the last-run timestamp). This scorer only
// combines them, so the policy — what counts as "similar enough", how a
// timestamp becomes a recency score — stays one decision in one place.

import 'dart:math' as math;

/// The relative importance of each of the four re-rank factors.
///
/// Weights are combined as a weighted average, so only their *ratios* matter;
/// `(2,1,1,1)` and `(4,2,2,2)` rank identically. A zero weight removes a factor
/// from the blend entirely.
final class ProcedureRerankWeights {
  /// Builds an explicit weighting. Negative weights are not meaningful and are
  /// treated as their absolute value would be by the average — callers should
  /// pass non-negative weights.
  const ProcedureRerankWeights({
    required this.embedding,
    required this.requiresOverlap,
    required this.successRate,
    required this.recency,
  });

  /// Weight on intent-embedding similarity.
  final double embedding;

  /// Weight on `requires`-set overlap with available capabilities.
  final double requiresOverlap;

  /// Weight on the candidate's rolling success rate.
  final double successRate;

  /// Weight on recency of the last successful run.
  final double recency;

  /// The default blend: embedding similarity leads, success rate next, then
  /// `requires` overlap, then recency. Tuned so a strong semantic match with a
  /// proven track record outranks a loosely-matching but recently-run
  /// candidate, while every factor still moves the result.
  static const ProcedureRerankWeights balanced = ProcedureRerankWeights(
    embedding: 0.40,
    requiresOverlap: 0.20,
    successRate: 0.25,
    recency: 0.15,
  );

  double get _total => embedding + requiresOverlap + successRate + recency;
}

/// Folds the four re-rank factors into one comparable score in `[0, 1]`.
///
/// Each factor is clamped to `[0, 1]` (so an out-of-range input cannot pull
/// the
/// score past the bounds), then combined as a weight-normalised average. A zero
/// total weight yields `0.0` rather than NaN — a degenerate weighting ranks
/// everything equally at the floor rather than crashing the sort.
double scoreProcedureCandidate({
  required double embeddingSimilarity,
  required double requiresOverlap,
  required double successRate,
  required double recencyScore,
  ProcedureRerankWeights weights = ProcedureRerankWeights.balanced,
}) {
  final total = weights._total;
  if (total <= 0) return 0.0;
  final weighted =
      weights.embedding * _unit(embeddingSimilarity) +
      weights.requiresOverlap * _unit(requiresOverlap) +
      weights.successRate * _unit(successRate) +
      weights.recency * _unit(recencyScore);
  return weighted / total;
}

/// Maps the age of a candidate's last successful run to a recency score in
/// `[0, 1]` via exponential half-life decay.
///
/// A run that just happened scores `1.0`; one a full [halfLifeMillis] old
/// scores `0.5`; older runs decay monotonically toward `0`. A negative age
/// (clock skew) clamps to the freshest score. A `null` [ageMillis] means the
/// candidate has never run successfully, which scores `0.0` — a never-run
/// procedure has no recency to credit.
double recencyDecay({required int? ageMillis, required int halfLifeMillis}) {
  if (ageMillis == null) return 0.0;
  if (ageMillis <= 0) return 1.0;
  if (halfLifeMillis <= 0) return 0.0;
  return math.pow(0.5, ageMillis / halfLifeMillis).toDouble();
}

double _unit(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

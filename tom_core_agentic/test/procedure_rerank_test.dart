// Tests for the domain-free procedure re-rank scorer.
//
// The procedure subsystem (`tom_brain_procedure`) ranks candidate procedures
// for an incoming request by four factors: intent-embedding similarity,
// `requires`-set overlap with available capabilities, recent success rate, and
// recency of the last successful run. The
// arithmetic that folds those four scalars into one comparable score is
// domain-free — it knows nothing about procedures, only about four numbers in
// [0,1] and their weights — so it lives here, reusable from any agent runtime.

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

void main() {
  group('scoreProcedureCandidate', () {
    test('is a weight-normalised average of the four factors', () {
      // With equal weights, the score is the plain mean of the four inputs.
      const weights = ProcedureRerankWeights(
        embedding: 1,
        requiresOverlap: 1,
        successRate: 1,
        recency: 1,
      );
      final score = scoreProcedureCandidate(
        embeddingSimilarity: 0.8,
        requiresOverlap: 0.4,
        successRate: 0.6,
        recencyScore: 0.2,
        weights: weights,
      );
      expect(score, closeTo((0.8 + 0.4 + 0.6 + 0.2) / 4, 1e-9));
    });

    test('all-1 inputs score 1.0 and all-0 inputs score 0.0', () {
      expect(
        scoreProcedureCandidate(
          embeddingSimilarity: 1,
          requiresOverlap: 1,
          successRate: 1,
          recencyScore: 1,
        ),
        closeTo(1.0, 1e-9),
      );
      expect(
        scoreProcedureCandidate(
          embeddingSimilarity: 0,
          requiresOverlap: 0,
          successRate: 0,
          recencyScore: 0,
        ),
        closeTo(0.0, 1e-9),
      );
    });

    test('a heavier weight pulls the score toward that factor', () {
      // Embedding dominates: score should be close to the embedding value.
      const weights = ProcedureRerankWeights(
        embedding: 10,
        requiresOverlap: 0,
        successRate: 0,
        recency: 0,
      );
      final score = scoreProcedureCandidate(
        embeddingSimilarity: 0.9,
        requiresOverlap: 0.1,
        successRate: 0.1,
        recencyScore: 0.1,
        weights: weights,
      );
      expect(score, closeTo(0.9, 1e-9));
    });

    test('inputs outside [0,1] are clamped, not extrapolated', () {
      final score = scoreProcedureCandidate(
        embeddingSimilarity: 1.5,
        requiresOverlap: -0.3,
        successRate: 2.0,
        recencyScore: 0.5,
        weights: const ProcedureRerankWeights(
          embedding: 1,
          requiresOverlap: 1,
          successRate: 1,
          recency: 1,
        ),
      );
      // Clamped to (1, 0, 1, 0.5) → mean 0.625.
      expect(score, closeTo((1 + 0 + 1 + 0.5) / 4, 1e-9));
    });

    test('zero total weight yields a zero score rather than NaN', () {
      final score = scoreProcedureCandidate(
        embeddingSimilarity: 0.9,
        requiresOverlap: 0.9,
        successRate: 0.9,
        recencyScore: 0.9,
        weights: const ProcedureRerankWeights(
          embedding: 0,
          requiresOverlap: 0,
          successRate: 0,
          recency: 0,
        ),
      );
      expect(score, 0.0);
    });

    test('the balanced default weights all four factors positively', () {
      const w = ProcedureRerankWeights.balanced;
      expect(w.embedding, greaterThan(0));
      expect(w.requiresOverlap, greaterThan(0));
      expect(w.successRate, greaterThan(0));
      expect(w.recency, greaterThan(0));
    });
  });

  group('recencyDecay', () {
    test('a brand-new run scores 1.0', () {
      expect(
        recencyDecay(ageMillis: 0, halfLifeMillis: 86400000),
        closeTo(1.0, 1e-9),
      );
    });

    test('an age of exactly one half-life scores 0.5', () {
      expect(
        recencyDecay(ageMillis: 86400000, halfLifeMillis: 86400000),
        closeTo(0.5, 1e-9),
      );
    });

    test('older runs decay monotonically toward 0', () {
      final fresh = recencyDecay(ageMillis: 1000, halfLifeMillis: 86400000);
      final stale = recencyDecay(
        ageMillis: 10 * 86400000,
        halfLifeMillis: 86400000,
      );
      expect(stale, lessThan(fresh));
      expect(stale, greaterThanOrEqualTo(0));
    });

    test('a negative age (clock skew) clamps to the freshest score', () {
      expect(
        recencyDecay(ageMillis: -5000, halfLifeMillis: 86400000),
        closeTo(1.0, 1e-9),
      );
    });

    test('a never-run candidate (null age) scores 0.0', () {
      expect(recencyDecay(ageMillis: null, halfLifeMillis: 86400000), 0.0);
    });
  });
}

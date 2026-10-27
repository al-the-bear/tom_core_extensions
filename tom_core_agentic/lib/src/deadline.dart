// Domain-free wall-clock deadline.
//
// Bounded agent work — a creation iteration, a procedure run, any timed loop —
// needs the same check: "has the wall-clock budget for this unit elapsed?".
// [Deadline] captures an expiry instant over an injectable clock so the loop is
// deterministically testable, and exposes the three operations every caller
// wants: a boolean expiry check, the remaining time, and a throw-on-expiry
// guard. The clock seam follows the framework convention (`systemClock`).

import 'system_clock.dart';

/// Raised by [Deadline.throwIfExpired] when the wall-clock budget has elapsed.
///
/// Domain-free on purpose: a caller that wants a wire-coded failure catches this
/// and rethrows its own; the primitive only signals "time is up".
final class DeadlineExceeded implements Exception {
  /// The expiry instant that was reached or passed.
  final DateTime expiresAt;

  /// Builds the failure for the passed [expiresAt].
  const DeadlineExceeded(this.expiresAt);

  @override
  String toString() =>
      'DeadlineExceeded: wall-clock deadline $expiresAt passed';
}

/// A wall-clock expiry instant evaluated against an injectable clock.
///
/// A [Deadline] is *expired* once the clock reaches or passes [expiresAt]
/// (inclusive — the deadline instant itself counts as up). Drive time in tests
/// by passing a controllable `clock`.
final class Deadline {
  /// The instant at and after which this deadline is expired.
  final DateTime expiresAt;

  final DateTime Function() _clock;

  /// Builds a deadline that expires at [expiresAt], read against [clock]
  /// (default [systemClock]).
  Deadline.at(this.expiresAt, {DateTime Function()? clock})
    : _clock = clock ?? systemClock;

  /// Builds a deadline expiring [budget] after *now*, read against [clock]
  /// (default [systemClock]).
  factory Deadline.startingNow(Duration budget, {DateTime Function()? clock}) {
    final now = (clock ?? systemClock)();
    return Deadline.at(now.add(budget), clock: clock);
  }

  /// Whether the clock has reached or passed [expiresAt].
  bool get isExpired => !_clock().isBefore(expiresAt);

  /// The time left until expiry, clamped to [Duration.zero] once expired.
  Duration get remaining {
    final left = expiresAt.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// Throws [DeadlineExceeded] if [isExpired], otherwise returns normally.
  void throwIfExpired() {
    if (isExpired) throw DeadlineExceeded(expiresAt);
  }
}

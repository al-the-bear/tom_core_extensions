// Calendar-day boundary arithmetic over an injected clock.
//
// Daily counters, day-rollover resets, and "until tomorrow" waits all
// need the same two operations: truncate an instant to the start of its
// calendar day, and find the start of the following day. Both must
// preserve the instant's zone so a UTC-driven deployment rolls over at
// UTC midnight and a local-time one at local midnight. Centralised here
// so the truncation logic is written once.

/// The start-of-day instant for [t], preserving [t]'s zone.
///
/// A UTC instant truncates to UTC midnight; a local instant truncates to
/// local midnight. The time-of-day, sub-second, and offset components are
/// dropped, leaving `year-month-day 00:00:00` in [t]'s own zone.
DateTime startOfDay(DateTime t) => t.isUtc
    ? DateTime.utc(t.year, t.month, t.day)
    : DateTime(t.year, t.month, t.day);

/// The start of the day *after* [t]'s calendar day, preserving [t]'s zone.
///
/// `day + 1` lets the `DateTime` constructor normalise month and year
/// rollover (e.g. Jan 31 → Feb 1, Dec 31 → Jan 1 of the next year). Use
/// `nextDayStart(now).difference(now)` for the wait until the next day
/// boundary.
DateTime nextDayStart(DateTime t) {
  final day = startOfDay(t);
  return day.isUtc
      ? DateTime.utc(day.year, day.month, day.day + 1)
      : DateTime(day.year, day.month, day.day + 1);
}

// The default wall-clock source for injectable-clock seams.
//
// Across the framework, time-dependent components take an injectable
// `DateTime Function()` so tests can drive time deterministically, and
// every one of them repeats the same `clock ?? DateTime.now` default at
// its constructor. [systemClock] is that default written once: a
// component declares `this.clock = clock ?? systemClock` and the
// production tear-off lives in a single place.

/// The production wall-clock time source: `DateTime.now`.
///
/// Use as the default for an injectable `DateTime Function()` seam:
///
/// ```dart
/// MyComponent({DateTime Function()? clock}) : clock = clock ?? systemClock;
/// ```
///
/// A test passes its own controllable function instead, so the component
/// never reads real time. This is a `const` constructor tear-off, so it
/// is free to reference and identical across call sites.
const DateTime Function() systemClock = DateTime.now;

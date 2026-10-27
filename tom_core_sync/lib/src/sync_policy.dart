/// What the background loop may do, how often, and to which containers.
library;

import 'package:tom_core_storage/tom_core_storage.dart';

/// Which half of a cycle the loop initiates for a container.
///
/// Read these as what the loop **starts**, not as what the container can
/// receive. A push under compare-and-swap re-reads and merges the remote when
/// it loses a race, so [pushOnly] cannot mean "never take their changes"; it
/// means the loop never spends a poll looking for them.
enum TomSyncDirection {
  /// Pull then push — the default and the normal case.
  twoWay,

  /// Track the remote, never publish. Local edits stay local and the unit
  /// stays dirty.
  pullOnly,

  /// Publish, never poll. Divergence still converges on a contended write.
  pushOnly;

  /// Whether the loop reads the remote for this direction.
  bool get pulls => this != pushOnly;

  /// Whether the loop publishes local work for this direction.
  bool get pushes => this != pullOnly;

  /// The direction named [name], or null when none is.
  static TomSyncDirection? tryParse(String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// The policy a [TomSyncScheduler] reads on every tick.
///
/// An interface, because where the policy comes from — a settings group, a
/// command line, a test — is the application's. The scheduler reads it on
/// each tick, so a changed policy takes effect without rebuilding anything.
abstract interface class TomSyncPolicy {
  /// Whether the timer runs at all. A manual sync works either way.
  bool get enabled;

  /// The cadence in force, already clamped to a floor the application sets.
  Duration get pollInterval;

  /// The backoff handed to every backend the loop drives.
  TomBackoffPolicy get backoff;

  /// Whether the container at [locator] is synced by the timer.
  bool syncsLocator(String locator);

  /// Which half of a cycle the loop initiates for [locator].
  TomSyncDirection directionFor(String locator);
}

/// A fixed [TomSyncPolicy]: every container, two-way, at one cadence.
class TomFixedSyncPolicy implements TomSyncPolicy {
  @override
  final bool enabled;

  @override
  final Duration pollInterval;

  @override
  final TomBackoffPolicy backoff;

  const TomFixedSyncPolicy({
    this.enabled = true,
    this.pollInterval = const Duration(seconds: 300),
    this.backoff = TomBackoffPolicy.defaults,
  });

  @override
  bool syncsLocator(String locator) => true;

  @override
  TomSyncDirection directionFor(String locator) => TomSyncDirection.twoWay;
}

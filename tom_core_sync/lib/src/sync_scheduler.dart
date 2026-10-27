/// One clock and one head check for a whole workspace of open units.
///
/// Each container is an independent sync unit, and
/// [TomSyncEngine] honours that: its state, its conflicts, its journal.
/// What it must *not* also mean is an independent request budget. An engine
/// polling on its own timer costs one head read per unit per tick whether
/// or not anything moved, so a workspace of twenty units spends twenty
/// requests a tick to learn "nothing happened" — which is how a background
/// loop exhausts a rate limit while doing no work at all.
///
/// This scheduler is the fix, and it is deliberately thin: it owns the timer
/// and the batched [TomStorage.headsOf] call, and then hands each engine
/// the head it already read. It contains **no merge, no commit and no state
/// machine** — asked what a unit's situation is, it forwards the question.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import 'package:tom_basics/diagnostics.dart';
import 'package:tom_core_storage/tom_core_storage.dart';
import 'sync_engine.dart';
import 'sync_policy.dart';
import 'sync_state.dart';

/// Work that waits for a transport, and that the loop tries again.
///
/// Not a container. A [TomSyncEngine] converges a thing that has a head
/// and is committed under compare-and-swap; this has neither. It is a queue of
/// writes made while a service could not be reached — writes nothing would
/// deliver until somebody made another one.
///
/// The loop is the application's one mechanism for "try again later", so the
/// queue is put on it and no second timer exists.
abstract interface class TomSyncRetry {
  /// What identifies this member.
  String get key;

  /// Whether anything is waiting. Asked on every tick, so it costs nothing.
  bool get hasPending;

  /// Tries to deliver what is waiting. Completes normally while the transport
  /// is still down: the work stays queued, which is the answer it had.
  Future<void> retry();

  /// The instant before which the timer leaves this member alone, or null.
  ///
  /// A rate limit the member is waiting out: retrying inside it is refused
  /// again, and sending through a content-creation block is what extends it.
  /// The timer wakes for it (it is a wait like a backend's reset). The manual
  /// "Sync now" does not consult it and calls [retry]: what an explicit ask
  /// may send through is the member's to decide, as it is for a backend.
  DateTime? get notBefore;

  /// The `sync` group's backoff, handed to the member as it is to every
  /// backend the loop drives.
  void adoptBackoff(TomBackoffPolicy policy);
}

/// Drives many [TomSyncEngine]s off one timer and one head check per tick.
///
/// This is also where the [TomSyncPolicy] is applied. The policy does not
/// reach into the engines one by one — it is held here and read on each tick,
/// so a changed policy takes effect on the next tick without rebuilding
/// anything. Its parts divide cleanly:
///
/// - [TomSyncPolicy.enabled] gates the **timer**, not the engines. A disabled
///   workspace never polls, and a manual sync still works, since it is a user
///   action and not a background one.
/// - [TomSyncPolicy.syncsLocator] gates which units a **tick** touches. Again
///   not the engines: a unit outside it is still syncable by hand, it simply
///   costs no automatic requests.
/// - each unit's [TomSyncPolicy.directionFor] is pushed onto its engine,
///   because the engine is where a phase is skipped.
class TomSyncScheduler {
  TomSyncPolicy _policy;

  final DateTime Function() _clock;

  final Map<String, TomSyncEngine> _engines = {};
  final Map<String, TomSyncRetry> _retries = {};
  final StreamController<TomSyncStatus> _statuses =
      StreamController<TomSyncStatus>.broadcast();
  final Map<String, StreamSubscription<TomSyncStatus>> _forwards = {};

  Timer? _timer;
  bool _running = false;
  Future<void>? _inFlight;

  /// When each backend's quota is expected back.
  ///
  /// Keyed by backend because the wait belongs to the backend that asked for
  /// it. [_tick] already groups its head read by backend; a single
  /// scheduler-wide field turned one backend's quota into a stall for every
  /// other backend's units — a local folder, which cannot rate-limit
  /// anything, waiting fifteen minutes on a GitHub repository's quota.
  final Map<TomStorage, TomSyncDeferral> _deferrals = {};
  Object? _lastError;

  /// Where a refused batch read is recorded, and the sink the
  /// engines a composition root adds are expected to share — a caller building
  /// an engine for this scheduler passes it on.
  ///
  /// The batch is logged here because it is the one place the refusal is met:
  /// the engines are told about it (`recordRateLimit`, `recordUnreachable`) but
  /// do not cycle, so no `sync.cycle` event would ever say it happened.
  final TomDiagnostics diagnostics;

  TomSyncScheduler({
    TomSyncPolicy? policy,
    DateTime Function()? clock,
    this.diagnostics = const TomNullDiagnostics(),
  }) : _policy = policy ?? const TomFixedSyncPolicy(),
       _clock = clock ?? (() => DateTime.now().toUtc());

  // ── Policy ──────────────────────────────────────────────────────────────

  /// The policy in force.
  TomSyncPolicy get policy => _policy;

  /// The shared cadence in force.
  Duration get pollInterval => _policy.pollInterval;

  /// Adopts a new policy.
  ///
  /// Applied to the running loop rather than requiring a restart, because an
  /// application edits these values live and a cadence change that only took
  /// effect on the next app launch would be indistinguishable from one that did
  /// not take effect at all.
  void applyPolicy(TomSyncPolicy policy) {
    _policy = policy;
    for (final engine in _engines.entries) {
      engine.value.direction = policy.directionFor(engine.key);
    }
    // The backoff reaches the backends that already exist; one joining later
    // adopts it in [add]. Between them a backend never runs on a policy the
    // user has since changed.
    for (final storage in _activeBackends()) {
      storage.adoptBackoff(policy.backoff);
    }
    for (final member in _retries.values) {
      member.adoptBackoff(policy.backoff);
    }
    _reschedule();
  }

  // ── Membership ──────────────────────────────────────────────────────────

  Iterable<TomSyncEngine> get engines => _engines.values;

  TomSyncEngine? engineFor(String locator) => _engines[locator];

  /// Every engine's status transitions, on one stream.
  Stream<TomSyncStatus> get statuses => _statuses.stream;

  /// When the **last** throttled backend's quota is expected back, or null
  /// when none is throttled.
  ///
  /// The latest rather than the earliest because this feeds the an indicator
  /// workspace line, and "paused until" must not promise a recovery that has
  /// not happened yet: at the earliest instant, the other backend is still
  /// refusing. The *timer* wants the earliest, and takes it ([_nextDelay]).
  DateTime? get deferredUntil {
    DateTime? latest;
    for (final deferral in _deferrals.values) {
      final until = deferral.until;
      if (latest == null || until.isAfter(latest)) latest = until;
    }
    return latest;
  }

  /// The wait the backend of [locator] is inside, or null when it is not
  /// waiting (or the unit is not on the loop).
  TomSyncDeferral? deferralFor(String locator) {
    final engine = _engines[locator];
    if (engine == null) return null;
    final storage = _backendOf(engine);
    return storage == null ? null : _deferrals[storage];
  }

  /// Whether a manual sync of [locator] would **ask** its backend now.
  ///
  ///  A manual pass asks a waiting backend
  /// only through a **throttle** — a wait this side chose, short, and one an
  /// answer retires. Through a **quota** the instant is the backend's own,
  /// so asking before it is a request spent to be told what the line already
  /// says; through a **block** asking is what renews the block. The button
  /// reads this so that its state matches what it would do.
  bool manualSyncAsks(String locator) {
    final deferral = deferralFor(locator);
    return deferral == null || deferral.kind == TomRateLimitKind.throttle;
  }

  /// Whether a workspace-wide manual sync would ask **any** backend now.
  ///
  /// True with no units on the loop as well: there is then nothing to
  /// refuse, and the retry members still get their turn.
  bool get manualSyncAsksAny =>
      _engines.isEmpty || _engines.keys.any(manualSyncAsks);

  /// Why the last tick could not read heads, or null when it could.
  Object? get lastError => _lastError;

  /// Puts [engine] under this scheduler's clock.
  ///
  /// The engine's own timer is stopped: two clocks over one unit would
  /// each read the head the other just read.
  void add(TomSyncEngine engine) {
    engine.stop();
    engine.direction = _policy.directionFor(engine.locator);
    _backendOf(engine)?.adoptBackoff(_policy.backoff);
    _engines[engine.locator] = engine;
    _forwards[engine.locator] = engine.statuses.listen((status) {
      if (!_statuses.isClosed) _statuses.add(status);
    });
    _reschedule();
  }

  /// Stops driving the unit at [locator]. The engine itself is not
  /// disposed — whoever created it owns it.
  Future<void> remove(String locator) async {
    _engines.remove(locator);
    // A cancel takes effect when it is called. The future it returns is about
    // the stream's own teardown, and it is not awaited here:
    // under a widget test's clock it never completes, so whatever followed the
    // await would silently never run.
    unawaited(_forwards.remove(locator)?.cancel());
    _pruneDeferrals();
    _reschedule();
  }

  /// Puts [member]'s waiting work under this scheduler's clock.
  void addRetry(TomSyncRetry member) {
    member.adoptBackoff(_policy.backoff);
    _retries[member.key] = member;
    _reschedule();
  }

  /// Re-reads the members' [TomSyncRetry.notBefore] for the timer.
  ///
  /// A member's wait can begin outside a tick — a write the user made meets
  /// the limit — and the armed timer was computed before it existed. Without
  /// this the queue would be retried at the next poll rather than at the
  /// instant the wait ends.
  void retriesChanged() => _reschedule();

  /// Stops waking the member registered under [key].
  void removeRetry(String key) {
    if (_retries.remove(key) != null) _reschedule();
  }

  /// The members [addRetry] registered.
  Iterable<TomSyncRetry> get retries => _retries.values;

  // ── Scheduling ──────────────────────────────────────────────────────────

  /// Whether the application wants the loop running.
  bool get isRunning => _running;

  /// Whether the timer is actually armed.
  ///
  /// Distinct from [isRunning] because the two answer different questions:
  /// the application asks for the loop once at startup, and `sync.enabled` decides
  /// whether that request currently arms a timer. Collapsing them would make
  /// disabling sync also *forget* that the loop was wanted, so re-enabling it
  /// would silently do nothing.
  bool get isPolling => _timer != null;

  void start() {
    if (_running) return;
    _running = true;
    _reschedule();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Arms, re-arms or disarms the timer from the three things that decide
  /// whether one is wanted: [start]/[stop], `sync.enabled`, and **membership**.
  ///
  /// Membership belongs in that list rather than in the caller's hands. The
  /// application's job is to say once that it wants the loop; whether a timer is
  /// armed right now is a property of the scheduler, and a workspace with no
  /// open units that keeps a timer wakes up every poll interval to
  /// discover it has nothing to do. Calling this from [add] and [remove] makes
  /// "start and stop it with the workspace" true by construction instead of
  /// true if two call sites remember — the same reasoning the single-write-path rule applies to
  /// the write path.
  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (!_running || !_policy.enabled) return;
    if (_engines.isEmpty && _retries.isEmpty) return;
    _schedule(_nextDelay());
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      // A timer tick has no caller to throw to; every failure is already on
      // the status stream or in [lastError].
      unawaited(tick().whenComplete(_reschedule));
    });
  }

  /// How long the timer will wait before the next tick.
  @visibleForTesting
  Duration get nextDelay => _nextDelay();

  /// Wakes when the **first** backend is due, not the last.
  ///
  /// A backend with open units and no wait is due every interval, so any
  /// such backend puts the timer on the plain cadence. Only when every
  /// backend is waiting does the timer sleep past it — to the earliest reset.
  Duration _nextDelay() {
    final backends = _backendDelay();
    final retry = _retryDelay();
    return retry != null && retry < backends ? retry : backends;
  }

  Duration _backendDelay() {
    DateTime? earliest;
    for (final storage in _activeBackends()) {
      final until = _deferrals[storage]?.until;
      if (until == null) return pollInterval;
      if (earliest == null || until.isBefore(earliest)) earliest = until;
    }
    if (earliest == null) return pollInterval;
    final wait = earliest.difference(_clock());
    return wait > pollInterval ? wait : pollInterval;
  }

  /// How long until the first member waiting out a limit may be retried.
  ///
  /// Shorter than the poll interval is the point: a block measured to clear in
  /// a minute or two is delivered when the wait ends, not at the next poll.
  /// The tick it causes is a whole tick — conditional head reads, answered
  /// `304` and free — because a timer that ran the queue alone would be a
  /// second loop.
  Duration? _retryDelay() {
    final now = _clock();
    Duration? soonest;
    for (final member in _retries.values) {
      final notBefore = member.notBefore;
      if (!member.hasPending || notBefore == null) continue;
      final wait = notBefore.isAfter(now)
          ? notBefore.difference(now)
          : Duration.zero;
      if (soonest == null || wait < soonest) soonest = wait;
    }
    return soonest;
  }

  Set<TomStorage> _activeBackends() => {
    for (final engine in _engines.values) ?_backendOf(engine),
  };

  /// The backend [engine]'s unit is on, or null when no configured backend
  /// handles its locator.
  ///
  /// The one place the scheduler resolves a backend, and total on purpose. An
  /// unresolvable unit has nothing to batch and nothing to configure, and it
  /// must not take the loop down with it: grouping by backend used to resolve
  /// every unit inline, so one such unit aborted the tick — and `add` —
  /// for every other unit in the workspace. Its own cycle still meets the
  /// failure and reports it on its status, which is where it belongs.
  TomStorage? _backendOf(TomSyncEngine engine) {
    try {
      return engine.unit.storage;
    } on TomStorageException {
      return null;
    }
  }

  /// Drops the waits of backends no open unit is on any more.
  ///
  /// Without this a closed unit's backend would go on reporting "paused"
  /// through [deferredUntil] for a wait nothing is subject to.
  void _pruneDeferrals() {
    final active = _activeBackends();
    _deferrals.removeWhere((storage, _) => !active.contains(storage));
  }

  /// Runs one batched tick now. Concurrent calls share the one in flight.
  Future<void> tick() => _inFlight ??= _tick().whenComplete(() {
    _inFlight = null;
  });

  /// The manual "Sync now", across the whole workspace.
  ///
  /// Batched exactly as the timer is — one `headsOf` per backend, each engine
  /// handed its head — because this is the path a user can repeat on demand,
  /// and a burst of per-unit head reads repeated on demand is what a
  /// secondary rate limit exists to punish. It runs through the same [_run] as
  /// the timer so the two loops cannot drift apart again.
  ///
  /// Three differences from the timer, each deliberate:
  ///
  /// * It ignores [TomSyncPolicy.enabled] and
  ///   [TomSyncPolicy.syncsLocator]: both describe what happens
  ///   *automatically*, and a user who presses the button has said what they
  ///   want more clearly than a background policy can.
  /// * It asks a backend that is inside a wait. The user asked; one refused
  ///   request is the honest answer, and an answered one retires the wait.
  /// * On a backend that answered, it cycles **every** unit rather than
  ///   the ones [TomSyncEngine.needsCycle] selects — a manual sync is also
  ///   how a user asks to be told the truth about a unit they suspect is
  ///   stale.
  Future<void> syncAll() async {
    await _run(_engines.keys.toList(), manual: true);
    await _retryPending(manual: true);
  }

  /// The manual "Sync now" for one unit.
  ///
  /// Through the same [_run] as the workspace button and the timer, so that
  /// the per-unit control cannot be the one path that ignores a wait:
  /// calling the engine directly asked a blocked backend for its head.
  Future<void> syncOne(String locator) => _run([locator], manual: true);

  /// Wakes every member that has work waiting, one after the other.
  ///
  /// After the containers, and sequentially, for the reason the cycles are:
  /// a burst is what a secondary rate limit punishes. A member that throws
  /// does not stop the others; what it threw is kept in [lastError].
  ///
  /// On the timer a member inside its [TomSyncRetry.notBefore] is passed
  /// over; [manual] asks it anyway.
  Future<void> _retryPending({bool manual = false}) async {
    final now = _clock();
    for (final member in _retries.values.toList()) {
      if (!_retries.containsKey(member.key) || !member.hasPending) continue;
      final notBefore = member.notBefore;
      if (!manual && notBefore != null && notBefore.isAfter(now)) continue;
      try {
        await member.retry();
      } catch (error) {
        _lastError = error;
      }
    }
  }

  Future<void> _tick() async {
    if (!_policy.enabled) return;
    if (_engines.isEmpty) return _retryPending();

    // Retire the waits whose reset has passed; the rest decide, per backend,
    // in [_run].
    final now = _clock();
    _deferrals.removeWhere((_, deferral) => !deferral.until.isAfter(now));

    // Units outside the enabled targets are filtered here rather than at
    // the cycle, so they cost no head read either — a target the user turned
    // off must stop spending requests, not merely stop merging.
    final due = _engines.keys.where(_policy.syncsLocator).toList();
    if (due.isNotEmpty) await _run(due, manual: false);
    await _retryPending();
  }

  /// One batched pass over [locators]: a head read per backend, then the
  /// cycles, sequentially.
  Future<void> _run(List<String> locators, {required bool manual}) async {
    // One request per backend, not per unit — the whole point. The backend
    // is asked of the unit, which is the one thing that knows it.
    final byBackend = <TomStorage, List<String>>{};
    for (final locator in locators) {
      final engine = _engines[locator];
      if (engine == null) continue;
      // On the timer, a backend still inside its wait is not asked — and
      // neither are its units cycled, since every one of them would spend
      // a request to be refused the same way. Other backends are unaffected.
      final storage = _backendOf(engine);
      if (storage == null) continue;
      // A manual pass asks through a throttle and nothing else
      // ([manualSyncAsks]); the timer asks through no wait at all.
      final deferral = _deferrals[storage];
      if (deferral != null &&
          (!manual || deferral.kind != TomRateLimitKind.throttle)) {
        continue;
      }
      byBackend.putIfAbsent(storage, () => []).add(locator);
    }

    // The head read and the cycles are one pass on each backend taking part,
    // so what the batch established about a branch is not asked again by
    // every unit the batch then converges.
    Future<void> Function() pass = () =>
        _batchAndCycle(locators, byBackend, manual: manual);
    for (final storage in byBackend.keys) {
      final inner = pass;
      pass = () => storage.withinPass(inner);
    }
    await pass();
  }

  Future<void> _batchAndCycle(
    List<String> locators,
    Map<TomStorage, List<String>> byBackend, {
    required bool manual,
  }) async {
    final heads = <String, String?>{};
    final answered = <TomStorage>{};

    for (final group in byBackend.entries) {
      try {
        heads.addAll(await group.key.headsOf(group.value));
        _lastError = null;
        answered.add(group.key);
        // An answer is proof the quota is back, so a wait this backend was
        // under is over — only reachable on the manual path, which asks a
        // waiting backend.
        _deferrals.remove(group.key);
        // Nothing else would retire a standing wait or outage: a quiet
        // unit never cycles on its own, so its indicator would read
        // "Paused until 14:20" or "Offline" indefinitely.
        for (final locator in group.value) {
          _engines[locator]?.recordHeadsAnswered();
        }
      } on TomRateLimitException catch (error) {
        // Do not cycle this backend's units at all: every one of them
        // would spend a request to be refused the same way.
        //
        // But do *tell* them. Batching the head read is what makes the loop
        // affordable, and it is also what takes this refusal out of each
        // engine's own reach — on a per-unit timer every one of them would
        // have met it directly. Without this the whole backend's units
        // report `Synced` while nothing syncs, which is worse than the request
        // budget the batching saved.
        _defer(group.key, error.resetAt, error.kind);
        _lastError = error;
        final until = _deferrals[group.key]?.until;
        diagnostics.log(
          TomDiagnosticEvent(
            operation: 'sync.heads.refused',
            level: TomDiagnosticLevel.warn,
            fields: {
              'backend': group.key.runtimeType.toString(),
              'locators': group.value,
              'kind': error.kind.name,
              if (until != null) 'until': until.toUtc().toIso8601String(),
            },
          ),
        );
        for (final locator in group.value) {
          _engines[locator]?.recordRateLimit(error);
        }
      } catch (error) {
        // Unreachable — or anything else the batch read raised, caught by
        // decision rather than let escape the tick, where it would reach
        // nobody. Tell every engine in the group, for the reason the
        // refusal branch does: `needsCycle` is false for a clean unit
        // whose remote head is unknown, so a quiet unit never cycles,
        // never meets the outage, and would report `Synced` against a remote
        // nobody has reached. An engine with local work still cycles below,
        // fails its own request, and journals its commit — which is
        // the reason not to skip it, on either path.
        _lastError = error;
        diagnostics.log(
          TomDiagnosticEvent(
            operation: 'sync.heads.unreachable',
            level: TomDiagnosticLevel.warn,
            fields: {
              'backend': group.key.runtimeType.toString(),
              'locators': group.value,
              'error': error.runtimeType.toString(),
            },
          ),
        );
        for (final locator in group.value) {
          _engines[locator]?.recordUnreachable(error);
        }
      }
    }

    // Sequentially, on purpose: firing every due unit's cycle at once is
    // precisely the burst that trips a secondary rate limit, and the work is
    // not latency-critical.
    for (final locator in locators) {
      final engine = _engines[locator];
      if (engine == null) continue; // Closed while the heads were in flight.
      final storage = _backendOf(engine);
      // One rule for a waiting backend, whoever set the wait: the batch above,
      // an earlier tick, or an earlier unit's own cycle in this one.
      if (storage != null && _deferrals.containsKey(storage)) continue;
      final head = heads[locator];
      // A manual sync forces a cycle where the backend answered — and where
      // there is no backend at all, because the cycle is how the user is told
      // so. On an unreachable backend it would spend a request per clean
      // unit to learn what the batch already said.
      final forced = manual && (storage == null || answered.contains(storage));
      // A commit journaled by an earlier process is local work the engine
      // cannot see until it has read the journal; a local read, no request.
      try {
        await engine.primePending();
      } catch (error) {
        // An unreadable journal leaves the count unknown, which `needsCycle`
        // reads as nothing queued; the cycle below reports the failure itself
        // if it meets it.
        diagnostics.log(
          TomDiagnosticEvent(
            operation: 'sync.journal.unreadable',
            level: TomDiagnosticLevel.warn,
            fields: {'locator': locator, 'error': error.runtimeType.toString()},
          ),
        );
      }
      if (!forced && !engine.needsCycle(head)) continue;
      // Never throws: the engine's cycle records every failure in its status.
      await engine.syncPolled(head);
      if (storage != null) {
        _defer(
          storage,
          engine.status.rateLimitedUntil,
          engine.status.rateLimitKind,
        );
      }
    }
  }

  void _defer(TomStorage storage, DateTime? until, TomRateLimitKind? kind) {
    if (until == null) return;
    final current = _deferrals[storage];
    if (current == null || until.isAfter(current.until)) {
      // A kind the refusal did not state reads as the quota — the conservative
      // reading an indicator takes too: it neither invents a throttle a manual
      // pass would ask through nor a block.
      _deferrals[storage] = TomSyncDeferral(
        until: until,
        kind: kind ?? TomRateLimitKind.quota,
      );
    }
  }

  Future<void> dispose() async {
    stop();
    for (final forward in _forwards.values) {
      unawaited(forward.cancel());
    }
    _forwards.clear();
    _engines.clear();
    _retries.clear();
    await _statuses.close();
  }
}

/// A backend's standing wait: when it is expected back, and which limit put
/// it there — the kind decides whether a manual pass asks through it.
class TomSyncDeferral {
  final DateTime until;
  final TomRateLimitKind kind;

  const TomSyncDeferral({required this.until, required this.kind});

  @override
  String toString() => 'TomSyncDeferral(${kind.name} until $until)';
}

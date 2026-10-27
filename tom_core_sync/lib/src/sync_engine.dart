/// The background sync loop for one unit.
///
/// The engine owns four things and nothing else: **the state machine**, **the
/// pull, merge, push cycle**, **edit coalescing**, and **the offline journal's
/// drain and fill**. Everything it does *to* a container it does through the
/// unit — the merge, the serialization and the compare-and-swap retry are the
/// unit's — so there is no merge, no serialization and no second
/// compare-and-swap loop in this file.
///
/// What it syncs is a [TomSyncUnit], not a kind of content: unrelated kinds of
/// container converge through the same loop because the loop does not know
/// which it has.
library;

import 'dart:async';

import 'package:tom_basics/diagnostics.dart';
import 'package:tom_core_storage/tom_core_storage.dart';
import 'conflict.dart';
import 'sync_exceptions.dart';
import 'sync_policy.dart';
import 'sync_state.dart';
import 'sync_unit.dart';

/// Keeps one sync unit converged with its remote.
///
/// One engine per unit: each unit is independent, with its own state and
/// cadence, because units are independent containers and a shared cadence
/// would make a busy unit throttle a quiet one.
///
/// **The loop is poll-driven by construction**. A webhook or push
/// notification, if one is ever wired up, calls [syncNow] and nothing else: it
/// shortens latency, it never carries data, and correctness does not depend on
/// it arriving. Everything this class does is reachable from the timer alone.
///
/// [direction] gates which *phases* the cycle initiates, and it is the only
/// setting that reaches in here. It is not a permission check on the container:
/// a `pushOnly` unit still merges the remote when its compare-and-swap
/// loses a race, because that merge is what makes the commit legal at all.
class TomSyncEngine {
  /// The default cadence.
  static const defaultPollInterval = Duration(seconds: 300);

  /// The cadence floor.
  ///
  /// A floor rather than a validated range because the constraint it encodes
  /// is external: GitHub's REST rate limit is what a 5-second poll over a
  /// workspace of units actually runs into. A user who asks for less gets
  /// the floor, and [pollInterval] reports the value in force so the setting
  /// never quietly lies about its effect.
  static const minPollInterval = Duration(seconds: 60);

  /// The container this engine converges.
  final TomSyncUnit unit;

  /// Where a commit the transport refused is recorded.
  ///
  /// Required, and deliberately without a default. The engine cannot pick one:
  /// a durable journal needs somewhere device-local to live, and *where* that
  /// is differs per platform (a folder on desktop, browser storage on web,
  /// nothing at all for a session that has chosen not to persist a queue) —
  /// which makes it a composition-root decision, exactly like the storage
  /// backend set. A default here could only have been the in-memory one, and an
  /// engine that silently substitutes a volatile queue for a durable one fails
  /// the single property the journal exists for, in the one configuration
  /// nobody wrote down.
  final TomCommitJournal journal;

  /// The effective poll cadence, already clamped to [minPollInterval].
  final Duration pollInterval;

  /// Which half of the cycle this engine initiates .
  ///
  /// Mutable because it is policy, not identity: changing a unit's
  /// direction in the settings panel must not require tearing down the engine
  /// and losing its journal, its conflicts and its base unit.
  TomSyncDirection direction;

  /// Where each cycle's outcome is recorded — `sync.cycle`, one
  /// event per cycle, with what it pulled, pushed and met.
  final TomDiagnostics diagnostics;

  final DateTime Function() _clock;

  final StreamController<TomSyncStatus> _statuses =
      StreamController<TomSyncStatus>.broadcast();

  final List<TomSyncConflict> _conflicts = [];

  TomSyncState _state = TomSyncState.clean;
  bool _offline = false;
  DateTime? _rateLimitedUntil;
  TomRateLimitKind? _rateLimitKind;
  String? _keyRequired;
  String? _unqueued;
  DateTime? _lastSyncedAt;
  Object? _lastError;

  /// How many journaled commits this locator owes — **null until the journal
  /// has been read**. An engine born over a journal that already holds a
  /// commit from an earlier process has local work it cannot see until then;
  /// reading zero there made a clean unit with a journaled commit never
  /// cycle on the timer, so the commit was never delivered by the loop that
  /// exists to deliver it. The scheduler calls
  /// [primePending] before it consults [needsCycle], which reads the local
  /// journal and spends no request.
  int? _pendingCount;

  Future<TomSyncStatus>? _inFlight;
  Timer? _timer;
  StreamSubscription<void>? _edits;

  TomSyncEngine({
    required this.unit,
    required this.journal,
    Duration pollInterval = defaultPollInterval,
    this.direction = TomSyncDirection.twoWay,
    this.diagnostics = const TomNullDiagnostics(),
    DateTime Function()? clock,
  }) : pollInterval = pollInterval < minPollInterval
           ? minPollInterval
           : pollInterval,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    if (unit.hasLocalChanges) _state = TomSyncState.dirty;
    _edits = unit.edits.listen((_) => _markEdited());
  }

  /// The container this engine converges — the journal, status and scheduler
  /// key.
  String get locator => unit.locator;

  // ── State ───────────────────────────────────────────────────────────────

  TomSyncState get state => _state;

  /// Flagged conflicts awaiting the review surface.
  List<TomSyncConflict> get conflicts => List.unmodifiable(_conflicts);

  /// Why the container did not open, or null when a key is not what is missing.
  String? get keyRequiredReason => _keyRequired;

  bool get needsKey => _keyRequired != null;

  TomSyncStatus get status => TomSyncStatus(
    locator: unit.locator,
    state: _state,
    pendingCount: _pendingCount ?? 0,
    conflicts: List.unmodifiable(_conflicts),
    offline: _offline,
    lastSyncedAt: _lastSyncedAt,
    lastError: _lastError,
    rateLimitedUntil: _rateLimitedUntil,
    rateLimitKind: _rateLimitKind,
    keyRequiredReason: _keyRequired,
    unqueuedReason: _unqueued,
    commitProgress: _commitProgress,
  );

  /// Where this unit's push has got to, or null when none is in flight.
  ///
  /// Cleared in a `finally` rather than on the success path, because a push
  /// that threw is a push that is no longer in flight: leaving the last
  /// reported figure behind would make a failed save read as one still
  /// running, and the status indicator would show a bar over a unit that
  /// has stopped.
  TomCommitProgress? _commitProgress;

  /// Publishes one progress report onto the status stream.
  ///
  /// A stream event per object rather than a poll, because an application has no
  /// clock of its own and a bar that advanced on a timer would be inventing
  /// motion the transport did not make.
  void _publishProgress(TomCommitProgress progress) {
    _commitProgress = progress;
    _statuses.add(status);
  }

  /// Whether a cycle would do anything, given a [remoteHead] somebody else
  /// already read.
  ///
  /// This is the whole point of a batched head check: one request answers "has
  /// anything moved" for every open unit, and the units that answer no
  /// — the overwhelming majority on any given tick — cost nothing further.
  /// Without it, N open units cost N requests per tick even when the
  /// workspace is idle, which is how a background loop exhausts a quota.
  ///
  /// [direction] is consulted here and not only in the cycle, so a `pullOnly`
  /// unit with unpushed edits does not wake a cycle that would immediately
  /// decline to push them.
  ///
  /// A unit waiting for its key answers **no**, unconditionally. Every
  /// automatic cycle would fetch the same ciphertext and fail to open it the
  /// same way, so polling a locked container spends requests to re-learn one
  /// fact. [syncNow] deliberately does not consult this, so "Sync now" still
  /// retries — and [keySupplied] releases the automatic loop the moment a key
  /// arrives.
  bool needsCycle(String? remoteHead) {
    if (_keyRequired != null) return false;
    if (direction.pushes &&
        (unit.hasLocalChanges || (_pendingCount ?? 0) > 0)) {
      return true;
    }
    if (direction.pulls && remoteHead != null && remoteHead != unit.head) {
      return true;
    }
    return false;
  }

  /// Status after every transition — the one channel an indicator binds to.
  Stream<TomSyncStatus> get statuses => _statuses.stream;

  /// Records that the working copy now holds changes the remote does not.
  ///
  /// **Private, and with exactly one caller**: the [unit]'s edit stream, bound
  /// in the constructor. There is one route to "there is local work", and it is
  /// the change stream the unit relays from its content. A public route beside
  /// it would be a second write path: a caller that forgot to call it would
  /// leave a unit dirty in fact and `clean` on screen. What is *not*
  /// stream-borne —
  /// a unit that has never been committed — is answered by
  /// [TomSyncUnit.hasLocalChanges] instead, where it is a property of the
  /// unit rather than something a caller has to remember.
  ///
  /// Note what this does **not** do: it does not capture the edit. Edits are
  /// already in the working copy, and the loop pushes the working copy — so
  /// ten rapid edits are one push of the final state, not ten pushes.
  ///
  /// It records nothing: whether there is local work is the unit's to say
  /// ([TomSyncUnit.hasLocalChanges]), read live, and an edit that lands
  /// while a push is in flight keeps the unit dirty because a push only clears
  /// what it carried. What this does is move the displayed state.
  void _markEdited() {
    if (_state == TomSyncState.clean) {
      _state = TomSyncState.dirty;
    }
    // A `conflicted` unit stays conflicted: unreviewed conflicts outrank
    // "has unpushed edits" for display, and the next clean cycle clears it.
    _publish();
  }

  /// Flags conflicts a save made **outside** the loop produced.
  ///
  /// An application's own save can bypass the loop, and a contended save
  /// merges and returns its conflicts just as a cycle's push does. Without this
  /// they would reach the caller and stop there, so the same race would raise
  /// the merge view when the timer noticed it and not when the user pressed
  /// Save — one conflict path, two behaviours. There is one queue of flagged
  /// conflicts per unit and this is how work that bypassed the loop joins it.
  void recordConflicts(Iterable<TomSyncConflict> conflicts) {
    if (conflicts.isEmpty) return;
    _conflicts.addAll(conflicts);
    // Mid-cycle, `_finalize` derives the state from the same list; overwriting
    // `syncing` here would only hide the activity indicator for a moment.
    if (_state != TomSyncState.syncing) {
      _state = TomSyncState.conflicted;
    }
    _publish();
  }

  /// Discards the flagged conflicts once the review surface has resolved
  /// them, letting the next clean cycle return the unit to `clean`.
  void clearConflicts() {
    if (_conflicts.isEmpty) return;
    _conflicts.clear();
    _settleAfterClear();
  }

  /// Discards every flagged conflict anchored on [anchor].
  ///
  /// The review surface confirms row by row and clears each resolved row
  /// immediately, so closing it half-way must leave exactly the *unreviewed*
  /// conflicts flagged — not all of them, and not none.
  void clearConflict(String anchor) {
    final before = _conflicts.length;
    _conflicts.removeWhere((conflict) => conflict.anchor == anchor);
    if (_conflicts.length == before) return;
    _settleAfterClear();
  }

  /// Discards exactly one flagged conflict, by identity.
  ///
  /// Distinct from [clearConflict] because an anchor is not always unique. A
  /// merge that reports at most one conflict per record can be cleared by
  /// anchor; one that reports several per anchor — items inside a record —
  /// cannot, and retiring by anchor there would silently discard the ones the
  /// user has not looked at yet.
  void clearConflictRecord(TomSyncConflict conflict) {
    final before = _conflicts.length;
    _conflicts.removeWhere((candidate) => identical(candidate, conflict));
    if (_conflicts.length == before) return;
    _settleAfterClear();
  }

  void _settleAfterClear() {
    if (_conflicts.isEmpty && _state == TomSyncState.conflicted) {
      _state = unit.hasLocalChanges ? TomSyncState.dirty : TomSyncState.clean;
    }
    _publish();
  }

  // ── The batched head read ───────────────────────────────────────────────
  //
  // The loop batches one head read across a workspace, which is
  // what makes the loop affordable — and what takes that read's outcome out of
  // every engine's own reach. On a per-unit timer each engine would meet a
  // refusal or an outage itself; batched, a quiet unit never cycles and so
  // never meets either, and reports `Synced` while nothing syncs. The three
  // methods below are the way back in: one per thing the batch can report.
  //
  // Public with exactly one caller, the [TomSyncScheduler], and justified
  // on the same terms as [recordConflicts]: the fact is real, it happened to
  // *this* unit, and the only other route to it is the very cycle the
  // scheduler exists not to spend.

  /// The batch was refused by a quota.
  ///
  /// Takes the refusal itself rather than its fields, so the one decision
  /// about a refusal that states no instant ([_waitFor]) is made here and not
  /// by each caller.
  ///
  /// Clears [status.offline]: the remote answered, in words.
  void recordRateLimit(TomRateLimitException refusal) {
    final resetAt = _waitFor(refusal);
    final kind = refusal.kind;
    // The kind is part of what changed: the same reset instant arriving as a
    // block rather than a throttle is a different thing to show, so treating
    // it as "no news" would leave the old label under the new limit.
    if (_rateLimitedUntil == resetAt && _rateLimitKind == kind && !_offline) {
      return;
    }
    _rateLimitedUntil = resetAt;
    _rateLimitKind = kind;
    _offline = false;
    _lastError = refusal;
    _publish();
  }

  /// When a refusal lets us try again.
  ///
  /// A backend that refuses without stating an instant has still refused, and
  /// the engine's only representation of "refused" is a wait. Returning null
  /// here would be indistinguishable from "not refused" and the unit would
  /// read `Synced` while nothing syncs. The loop re-polls at its own interval
  /// when no wait is stated, so that is the honest instant to show.
  DateTime _waitFor(TomRateLimitException refusal) =>
      refusal.resetAt ?? _clock().add(pollInterval);

  /// The batch could not reach the remote at all.
  ///
  /// Not the twin of [recordRateLimit] it looks like: a refusal carries its
  /// own retraction instant, an outage carries none. It is retracted only by
  /// [recordHeadsAnswered] — for a quiet unit, the next tick's batch.
  ///
  /// A key-blocked engine is left alone. The key prompt is the one state a user
  /// can act on, an outage does not make a wrong key right, and supplying the
  /// key cycles immediately ([keySupplied]), which meets the outage directly if
  /// it is still there.
  void recordUnreachable(Object error) {
    if (_keyRequired != null) return;
    if (_offline && _rateLimitedUntil == null) {
      // Still dark. Keep the newest evidence, but do not republish an
      // unchanged verdict on every tick of an outage.
      _lastError = error;
      return;
    }
    _offline = true;
    // At most one transport verdict at a time (see [_verdict]): a wait left
    // beside a fresh outage would outlive the answer it described.
    _rateLimitedUntil = null;
    _rateLimitKind = null;
    _lastError = error;
    _publish();
  }

  /// The batch was answered: the remote is reachable and not refusing us.
  ///
  /// Retires whichever of the two batch verdicts is standing. Nothing else
  /// would: a quiet unit never cycles on its own, so a wait would read
  /// "Paused until 14:20" long after 14:20, and an outage would read "Offline"
  /// indefinitely after the network came back — the staleness each verdict was
  /// introduced to prevent, inverted.
  ///
  /// Leaves [needsKey] alone, for the reason [recordUnreachable] does: a
  /// reachable remote says nothing about whether the key is right.
  void recordHeadsAnswered() {
    if (!_offline && _rateLimitedUntil == null) return;
    _offline = false;
    _rateLimitedUntil = null;
    _rateLimitKind = null;
    // A verdict is assigned totally (see [_verdict]), so the error standing
    // beside it can only be its evidence, and goes with it.
    _lastError = null;
    _publish();
  }

  /// Clears the key block and cycles immediately.
  ///
  /// The exit from [needsKey], called once the application's key prompt has
  /// registered the file's key with the `TomKdbxKeyProvider`. It syncs rather
  /// than merely unblocking because the user just answered a question the loop
  /// asked, and making them wait a poll interval for the answer to take effect
  /// would read as the prompt having done nothing.
  Future<TomSyncStatus> keySupplied() {
    _keyRequired = null;
    _publish();
    return syncNow();
  }

  // ── Scheduling ──────────────────────────────────────────────────────────

  bool get isRunning => _timer != null;

  /// Starts the poll timer. Idempotent.
  void start() {
    _timer ??= Timer.periodic(pollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs a cycle now — the manual "Sync now" action, and what a push
  /// notification would trigger.
  ///
  /// **Takes nothing from its caller**. A trigger only starts a
  /// cycle; the cycle reads the remote head itself and pulls the container
  /// itself, so whatever a webhook or a button carried cannot reach the
  /// unit. That is why this has no parameters at all rather than an
  /// optional hint: an optional hint is a data path a trigger could fill.
  ///
  /// Concurrent calls share one cycle rather than queueing a second: two
  /// overlapping cycles would both read the same head and race each other's
  /// commit for no gain, and the second one's work is subsumed by the first
  /// plus the re-dirty flag.
  Future<TomSyncStatus> syncNow() => _run(null);

  /// Runs a cycle with the head the scheduler's batched poll just read
  /// ([TomSyncScheduler]), so the
  /// cycle does not read it a second time.
  ///
  /// The poll's own read, not a trigger's payload: [polledHead] came from the
  /// remote one request ago, and it is only ever compared with the unit's head
  /// for **equality** — never parsed, never ordered. A value that has
  /// gone stale since costs an extra cycle, never a wrong merge, because the
  /// content is read from the remote and the commit is compare-and-swapped.
  Future<TomSyncStatus> syncPolled(String? polledHead) => _run(polledHead);

  Future<TomSyncStatus> _run(String? polledHead) => _inFlight ??= _cycle(
    polledHead: polledHead,
  ).whenComplete(() => _inFlight = null);

  void _tick() {
    // A timer tick has no caller to throw to; the status stream is this
    // engine's error surface, and `_cycle` has already put the failure there.
    unawaited(syncNow());
  }

  // ── The cycle ──────────────────────────────────────────────────

  Future<TomSyncStatus> _cycle({String? polledHead}) async {
    _state = TomSyncState.syncing;
    _publish();
    final record = _CycleRecord(conflictsBefore: _conflicts.length);

    try {
      // A drained journal commits, which moves our head past whatever the
      // caller read before the drain — so the handed-over value is spent.
      final drained = direction.pushes && await _drainJournal();
      record.drained = drained;
      if (direction.pulls) {
        final headBefore = unit.head;
        _conflicts.addAll(await _pull(drained ? null : polledHead));
        record.pulled = unit.head != headBefore;
      }
      if (direction.pushes && unit.hasLocalChanges) {
        await _push();
        record.pushed = true;
      }
      _verdict();
      _lastSyncedAt = _clock();
    } on TomKeyRequiredException catch (error) {
      // Caught **before** the generic storage case, and that ordering is the
      // whole one unit per container requirement: the bytes arrived, the container did not
      // open, and a merge needs the plaintext — so the cycle stops here,
      // ahead of any merge, and asks for the file's key. Degrading it to
      // `offline` would tell the user to check their network for a container
      // that downloaded perfectly.
      _verdict(keyRequired: error.reason, error: error);
    } on TomCasExhaustedException catch (error) {
      // The container moved on all three attempts. Everything typed is in the
      // merged working copy; the next scheduled cycle picks it up. Convergence
      // never depended on this cycle succeeding.
      //
      // The transport is *fine* — we reached the remote three times to learn
      // this — so the verdict is clear even though the cycle failed.
      _conflicts.addAll(error.conflicts);
      _verdict(error: error);
    } on TomCommitFailedException catch (error) {
      await _journal(error);
    } on TomRateLimitException catch (error) {
      // Reachable, healthy, and refusing us until a stated time. Not offline —
      // and deliberately not journaled either, because nothing was built: the
      // quota refusal happened on a request, and the working copy still holds
      // everything. Polling again before the reset is what keeps it refusing,
      // so the wait is surfaced for the scheduler to honour.
      _verdict(
        rateLimitedUntil: _waitFor(error),
        rateLimitKind: error.kind,
        error: error,
      );
    } on TomStorageException catch (error) {
      // A read failed — we never got as far as a changeset to journal.
      _verdict(offline: true, error: error);
    } catch (error) {
      // Anything else — a medium's own failure on the journal's read, a
      // codec's, a defect. Caught here **by decision** rather than left to
      // escape: an error that leaves the cycle reaches nobody (the timer has no
      // caller), while one recorded here reaches the status indicator and the
      // log. The working copy is untouched, so nothing is lost by stopping.
      _verdict(error: error);
    }

    try {
      await _refreshPendingCount();
    } catch (error) {
      // The count is advisory; an unreadable journal must not undo the
      // verdict the cycle just reached.
      _lastError ??= error;
    }
    _finalize();
    _logCycle(record);
    return status;
  }

  /// The one `sync.cycle` event, read off the verdict the cycle just assigned.
  ///
  /// Read off the verdict rather than logged from each `catch`, because
  /// [_verdict] is already the one total statement of what the transport did:
  /// a second, per-branch account is how the log and the status indicator come
  /// to disagree about the same cycle.
  ///
  /// A cycle that moved nothing is logged at debug: the loop only cycles a
  /// unit with a reason to, but "asked and nothing had changed" is not
  /// something a reader following a report needs at the default level.
  void _logCycle(_CycleRecord record) {
    final error = _lastError;
    final String outcome;
    if (_keyRequired != null) {
      outcome = 'key-required';
    } else if (_unqueued != null) {
      outcome = 'unqueued';
    } else if (_rateLimitedUntil != null) {
      outcome = 'rate-limited';
    } else if (error is TomCommitFailedException) {
      outcome = 'journaled';
    } else if (_offline) {
      outcome = 'unreachable';
    } else if (error is TomCasExhaustedException) {
      outcome = 'contended';
    } else if (error != null) {
      outcome = 'failed';
    } else {
      outcome = 'synced';
    }
    final newConflicts = _conflicts.length - record.conflictsBefore;
    final moved = record.pulled || record.pushed || record.drained;
    final level = outcome != 'synced' || newConflicts > 0
        ? TomDiagnosticLevel.warn
        : moved
        ? TomDiagnosticLevel.info
        : TomDiagnosticLevel.debug;
    final until = _rateLimitedUntil;
    diagnostics.log(
      TomDiagnosticEvent(
        operation: 'sync.cycle',
        level: level,
        fields: {
          'locator': unit.locator,
          'outcome': outcome,
          'pulled': record.pulled,
          'pushed': record.pushed,
          'journalDrained': record.drained,
          'conflicts': newConflicts,
          'pending': _pendingCount ?? 0,
          if (error != null) 'error': error.runtimeType.toString(),
          if (_rateLimitKind != null) 'kind': _rateLimitKind!.name,
          if (until != null) 'until': until.toUtc().toIso8601String(),
        },
      ),
    );
  }

  /// Re-attempts commits that were built while the transport was down.
  ///
  /// Straight through the ordinary CAS path, in order, exactly as the journal
  /// requires. When one is rejected the remote has moved on since we queued
  /// it, and the right answer is **not** a bespoke reconciliation: the entry's
  /// content is already coalesced into the working copy, so the pull and push
  /// that follow carry it. We stop, leave the queue in place, and let the
  /// push subsume it.
  /// Returns whether any queued commit actually landed.
  Future<bool> _drainJournal() async {
    final pending = await journal.pending(locator: unit.locator);
    if (pending.isEmpty) return false;
    final storage = unit.storage;
    var committed = false;
    for (final entry in pending) {
      try {
        unit.head = await storage.commit(
          unit.locator,
          entry.changeset,
          expectedHead: entry.baseHead,
          message: entry.message,
          onProgress: _publishProgress,
        );
        committed = true;
      } on TomCasConflictException {
        return committed;
      } finally {
        _commitProgress = null;
        _statuses.add(status);
      }
      // Only now: an entry dropped on attempt is an edit lost to a network
      // flap.
      await journal.complete(entry.sequence);
    }
    return committed;
  }

  /// Brings the working copy up to the remote, merging any divergence.
  ///
  /// Returns the flagged conflicts — the two-sided divergences of the merge.
  /// Every other class resolves silently inside the merge.
  Future<List<TomSyncConflict>> _pull(String? polledHead) async {
    final remoteHead = polledHead ?? await unit.storage.headOf(unit.locator);

    // Fast path: nobody else changed the container, so there is nothing to
    // merge and `ours` is already based on what it holds.
    //
    // Equality, and only equality: a head is an opaque cursor — a
    // GitHub object sha today, a sync-token or a relay counter later — so
    // "different" is the one thing it can say. Nothing here may parse it or
    // ask which of two heads is newer.
    if (remoteHead == null || remoteHead == unit.head) return const [];

    return unit.pull(remoteHead);
  }

  /// Publishes the current working copy.
  ///
  /// The unit owns the CAS retry, the re-merge between attempts and any
  /// `.history/` snapshotting; this method's only additions are recording the
  /// conflicts and retiring the journal.
  ///
  /// Note the conflicts recorded here can only be non-empty when there *were*
  /// local changes — a conflict needs both sides to have moved off the
  /// ancestor — which is why the no-local-changes cycle can skip the push
  /// without stranding a loser in memory.
  Future<void> _push() async {
    _conflicts.addAll(await unit.push());
    // Everything queued for this container is in the working copy we just
    // pushed — edits coalesce, and nothing ever leaves `ours`. So the queue is
    // subsumed, not discarded.
    await journal.completeAll(unit.locator);
  }

  /// Records a commit that never reached the remote, so the work survives a
  /// restart and an application can count it.
  ///
  /// **When the journal cannot hold it** — a full browser store, a refused
  /// write — the commit is in neither place it is supposed to be, and that is
  /// said rather than thrown away: the verdict carries [TomSyncStatus
  /// .unqueuedReason]. Nothing is lost while the app stays open, because the
  /// work is still in the working copy and the unit still reports it, so
  /// the next cycle builds the commit again and tries both the remote and the
  /// journal again.
  Future<void> _journal(TomCommitFailedException error) async {
    try {
      await journal.append(
        locator: unit.locator,
        changeset: error.changeset,
        baseHead: error.baseHead,
        version: error.version,
        message: error.commitMessage,
      );
      _verdict(offline: true, error: error);
    } catch (journalError) {
      // The error's own first line: a medium that knows what went wrong —
      // the browser's "storage for this site is full" — says it better than
      // a class name would.
      final why = '$journalError'.split('\n').first.trim();
      _verdict(
        offline: true,
        error: journalError,
        unqueued:
            'This device could not store the changes for later ($why). '
            'They are in the open working copy and will be sent when the remote '
            'can be reached; closing the app before then loses them.',
      );
    }
  }

  /// Assigns **the whole** transport verdict of a cycle, and is the only thing
  /// that may.
  ///
  /// `offline`, `rateLimitedUntil` and `keyRequired` are three answers to one
  /// question — what did the transport just do — and at most one of them is
  /// true at a time. Assigning them individually is how a stale one outlives a
  /// fresh one: a cycle that fails unreachable, and then an interval later is
  /// politely refused until 14:20, would carry `offline` **and**
  /// `rateLimitedUntil`, and the status indicator (which tests `offline`
  /// first, because for a *workspace* an outage outranks a wait) would report
  /// "Offline" for a remote that had just answered. Totality removes the class
  /// of bug rather than the instance: every branch states the whole verdict, so
  /// there is no branch that can forget to retract the previous one.
  ///
  /// `lastError` travels with the verdict for the same reason — it is the
  /// evidence *for* it, and evidence that outlives its verdict is worse than no
  /// evidence at all.
  void _verdict({
    bool offline = false,
    DateTime? rateLimitedUntil,
    TomRateLimitKind? rateLimitKind,
    String? keyRequired,
    String? unqueued,
    Object? error,
  }) {
    _offline = offline;
    _rateLimitedUntil = rateLimitedUntil;
    // Travels with the time and is cleared with it, so the pair cannot
    // survive each other — a kind outliving its wait would label the next
    // limit with the last one's name.
    _rateLimitKind = rateLimitedUntil == null ? null : rateLimitKind;
    _keyRequired = keyRequired;
    _unqueued = unqueued;
    _lastError = error;
  }

  void _finalize() {
    _state = _conflicts.isNotEmpty
        ? TomSyncState.conflicted
        : unit.hasLocalChanges
        ? TomSyncState.dirty
        : TomSyncState.clean;
    _publish();
  }

  Future<void> _refreshPendingCount() async =>
      _pendingCount = (await journal.pending(locator: unit.locator)).length;

  /// Reads the journal once, so [needsCycle] can count a commit an earlier
  /// process journaled for this locator. A local read; no request.
  Future<void> primePending() async {
    if (_pendingCount == null) await _refreshPendingCount();
  }

  // ── Plumbing ────────────────────────────────────────────────────────────

  void _publish() {
    if (!_statuses.isClosed) _statuses.add(status);
  }

  /// Stops the loop and releases the unit.
  ///
  /// The unit is disposed here rather than by the caller because the engine is
  /// the only thing holding it: [TomSyncScheduler.remove] takes it off the
  /// clock without touching it, and a unit left alive keeps a subscription on
  /// the unit's change stream — so a unit closed and reopened
  /// would accumulate one listener per open, each feeding a dead engine.
  Future<void> dispose() async {
    stop();
    unawaited(_edits?.cancel());
    _edits = null;
    await unit.dispose();
    await _statuses.close();
  }
}

/// What one cycle did, gathered as it runs for [TomSyncEngine._logCycle].
class _CycleRecord {
  _CycleRecord({required this.conflictsBefore});

  final int conflictsBefore;
  bool drained = false;
  bool pulled = false;
  bool pushed = false;
}

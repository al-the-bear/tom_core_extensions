// Credit-based backpressure tracker for streaming protocols.
//
// A pure async credit ledger: a producer waits for a positive credit
// balance before emitting each item, and a consumer tops the ledger up
// as it drains. Used by isolate-streaming adapters to keep a fast
// in-isolate producer from overrunning a slower cross-boundary consumer,
// but it has no isolate-specific coupling — it is a plain
// counting-semaphore-with-FIFO-waiters.

import 'dart:async';

/// Per-stream credit ledger held by a stream producer.
///
/// Backpressured producers construct one of these with an initial credit
/// allowance. Unbounded streams skip the tracker entirely — items flow
/// without credit accounting.
///
/// Usage:
///
///   ```dart
///   final tracker = BackpressureTracker(initialCredits: 16);
///   while (more) {
///     await tracker.awaitCredit();
///     pushChunk();
///     tracker.consume(1);
///   }
///   ```
///
/// `awaitCredit()` returns immediately when credits > 0; otherwise it
/// waits until [grant] is called. Multiple callers may be parked; they
/// are released in FIFO order one credit at a time.
///
/// **After [close]** the ledger stops accounting. [grant] and [consume]
/// become no-ops and [credits] freezes at its last value; only
/// [awaitCredit] reports the closure, by failing with a [StateError].
/// The asymmetry is the point: `awaitCredit` is the producer's
/// control-flow point and the single place the unwind is meant to begin,
/// whereas `grant` and `consume` are bookkeeping either side of a chunk
/// that has already been pushed. A producer is routinely mid-iteration
/// when a close arrives — it has passed `awaitCredit`, pushed its chunk,
/// and not yet called `consume` — and making that trailing `consume`
/// throw would turn a clean close into an error raised from the middle
/// of the loop body, which callers would have to catch just to reach the
/// unwind they already have.
///
/// Argument validation is **not** part of that: [grant] and [consume]
/// check their argument before consulting the closed flag, because a
/// nonsensical `n` is a caller bug in any state and silence would only
/// hide it.
final class BackpressureTracker {
  int _credits;
  final List<Completer<void>> _waiters = <Completer<void>>[];
  bool _closed = false;

  BackpressureTracker({required int initialCredits})
    : _credits = initialCredits {
    if (initialCredits < 0) {
      throw ArgumentError.value(
        initialCredits,
        'initialCredits',
        'must be non-negative',
      );
    }
  }

  /// Remaining credits. Visible for tests.
  int get credits => _credits;

  /// Number of waiters parked on [awaitCredit]. Visible for tests.
  int get waiterCount => _waiters.length;

  /// Whether [close] has been called. Subsequent [awaitCredit] calls
  /// throw [StateError].
  bool get isClosed => _closed;

  /// Returns once at least one credit is available. Does not decrement —
  /// call [consume] after pushing the chunk.
  Future<void> awaitCredit() {
    if (_closed) {
      return Future<void>.error(StateError('BackpressureTracker is closed.'));
    }
    if (_credits > 0) return Future<void>.value();
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Consumes [n] credits (default 1). Permits going to zero; rejects
  /// going negative.
  ///
  /// A no-op once [close] has been called — a producer that pushed its
  /// chunk just as the stream closed still calls this, and the ledger it
  /// is settling no longer exists. The over-consume [StateError] below is
  /// skipped with it: it is a statement about a live balance, and a
  /// closed tracker has none.
  void consume([int n = 1]) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'must be non-negative');
    }
    if (_closed) return;
    if (n > _credits) {
      throw StateError(
        'BackpressureTracker.consume($n) but only $_credits credits available.',
      );
    }
    _credits -= n;
  }

  /// Grants [n] more credits. Wakes **at most [n]** parked waiters in FIFO
  /// order; remaining credits stay on the ledger.
  ///
  /// Waking a waiter does not itself consume a credit — the woken producer
  /// pushes its chunk and then calls [consume]. So the release count is bounded
  /// by an explicit per-grant budget (`n`), not by the credit balance: granting
  /// `n` credits releases `n` producers, each of which will claim one of the
  /// `n` credits. Releasing more than `n` would let `n + k` producers push
  /// against only `n` credits, and the surplus [consume] calls would throw.
  ///
  /// A no-op once [close] has been called — but the argument is checked
  /// first, so a bad `n` is reported whether or not the tracker is still
  /// open.
  void grant(int n) {
    if (n <= 0) {
      throw ArgumentError.value(n, 'n', 'must be positive');
    }
    if (_closed) return;
    _credits += n;
    var releasable = n;
    while (releasable > 0 && _waiters.isNotEmpty) {
      final w = _waiters.removeAt(0);
      // An already-completed waiter (e.g. cancelled) claims no credit, so it
      // does not draw down the release budget.
      if (!w.isCompleted) {
        w.complete();
        releasable--;
      }
    }
  }

  /// Closes the tracker. Pending waiters fail with [StateError].
  void close() {
    if (_closed) return;
    _closed = true;
    final waiters = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) {
        w.completeError(StateError('BackpressureTracker is closed.'));
      }
    }
  }
}

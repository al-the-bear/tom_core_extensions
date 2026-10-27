# Isolate Streaming Module

A domain-free, `dart:io`-free toolkit for running cancellable, streaming work on
a worker isolate. The module owns five independent primitives — a cancellation
family, a per-stream close signal, a credit-based backpressure ledger, a
per-request guard (worker-death + deadline), and a typed exception registry that
survives the isolate boundary. Nothing here spawns an isolate or assumes a
transport; each primitive is a building block a host/worker pair assembles.

> **Looking for a signature?** This page explains how the pieces fit a
> streaming protocol together.
> [`doc/api/api_summary_isolate_streaming.md`](api/api_summary_isolate_streaming.md)
> is the symbol-level mirror: all twelve exported types with a section each,
> and a table of which side of the boundary each one lives on.
> `test/api_summary_test.dart` derives the required set from the barrel.

## Table of Contents

- [Overview](#overview)
- [Cancellation](#cancellation)
- [Stream Close Signal](#stream-close-signal)
- [Backpressure](#backpressure)
- [Request Guard](#request-guard)
- [Exception Registry](#exception-registry)
- [Concurrency and Lifecycle](#concurrency-and-lifecycle)
- [Core Components](#core-components)
- [Dependencies](#dependencies)

---

## Overview

| Type | Kind | Purpose |
| ---- | ---- | ------- |
| `IsolateCancellationToken` | final class | Opaque, value-equal id naming one cancellable request — the only member of this family that crosses the boundary |
| `IsolateCancellationTokenAllocator` | final class | Host-side counter handing out monotonically increasing tokens |
| `IsolateCancellationRegistry` | final class | Worker-side registry: cancels in-flight tokens, remembers a pre-open cancel, drops a post-close one |
| `IsolateCancellationHandle` | final class | Worker-side view of one token: `isCancelled`, a `cancelled` future, `throwIfCancelled` |
| `IsolateCancellationException` | final class | Thrown by `throwIfCancelled` when the token is cancelled |
| `IsolateStreamCloseSignal` | final class | Per-stream close flag + future a producer reacts to without busy-waiting |
| `BackpressureTracker` | final class | FIFO credit ledger gating a producer to the consumer's drain rate |
| `IsolateRequestGuard` | final class | Host-side per-request completion guard: fails in-flight requests on worker death or deadline |
| `IsolateRequestFailureReason` | enum | `workerDeath` or `timeout` |
| `IsolateRequestFailure` | final class | The failure delivered to a guarded request |
| `IsolateExceptionRegistry` | final class | Maps type tags to factories that rebuild typed errors across the boundary |
| `IsolateExceptionFactory` | typedef | `Object Function(String message, Map<String, Object?> details)` |

**Every class here is `final`, and that is uniform on purpose.** None of these
types is varied by subclassing: each is adjusted by what you pass it — a
`defaultTimeout`, a registered `IsolateExceptionFactory`, a credit limit — so
a subclass would have nothing to override that is not already a parameter.
Closing them says so, and leaves opening one later as a deliberate act rather
than an accident of whichever modifier the file happened to be written with.
The private helpers inside the module carry no modifier, because one there
would restrict nothing: a modifier governs subtyping from outside the
declaring library, and a private class is not visible outside it.

## Cancellation

Cancellation is split across the boundary, and the split is asymmetric: **only
the token crosses**. The host allocates a token and puts its id in its own
request envelope; the executor inside the worker isolate owns the registry,
registers the token when that envelope lands, and reads the handle at its
checkpoints. Cancelling is a *message*, not a method call — the host sends a
cancel envelope, and the executor turns it into `registry.cancel`.

The registry and the handle stay in the worker isolate because they cannot do
anything else: both hold a `Completer`, so sending one throws
`ArgumentError: ... object is unsendable`. The token is a single-integer value
type and crosses trivially.

```dart
// --- host isolate: allocate, and send the id in your own envelope ---
final allocator = IsolateCancellationTokenAllocator();

final token = allocator.next();
workerPort.send({'op': 'recall', 'cancellation': token.id});

// To abort, later — another message, not a call into the worker's registry:
workerPort.send({'op': 'cancel', 'cancellation': token.id});

// --- worker isolate: the registry lives here and never leaves ---
final registry = IsolateCancellationRegistry();

// When the request envelope arrives: register, then check at checkpoints.
final handle = registry.register(IsolateCancellationToken(tokenId));
handle.throwIfCancelled();          // throws IsolateCancellationException
await handle.cancelled;             // or await the cancellation future
handle.dispose();                   // required — see below

// When the cancel envelope arrives: flip the flag for that token.
registry.cancel(IsolateCancellationToken(tokenId));
```

`register` returns an `IsolateCancellationHandle`; its `cancelled` future
completes when the executor applies the host's cancel, and `throwIfCancelled`
raises `IsolateCancellationException` for code that prefers a guard call to
awaiting.

**Late-cancel race.** A cancel can arrive before the matching `register` — the
host sends it right after the request envelope, but the request envelope is
still mid-dispatch. The registry remembers such a cancel in a pending set, so
the subsequent `register` for that token returns an already-cancelled handle.

An unknown-token cancel is ambiguous, though, and the registry does *not*
remember them all: an id it has already seen belongs to a request that has
since been disposed, so that cancel is dropped rather than pending forever
(ids are never recycled, so nothing would ever consume it). The two cases are
told apart by a high-water mark over registered ids. `inFlightCount` and
`pendingCancelCount` expose the two sides of the ledger.

That mark works only while ids reach `register` **strictly increasing**, which
is true of a single host allocator over an ordered transport and of nothing
else. Two allocators feeding one registry, or a transport that reorders open
envelopes, make a genuine pre-open cancel indistinguishable from a post-close
one — and it is then dropped, so the request runs to completion having been
cancelled with no error anywhere. `register` asserts the ordering rather than
leaving that to a comment: the failure is silent, and an assert is what makes
it loud in the debug builds and test runs where an adapter is written.

**Two `isCancelled`s, two scopes.** The registry's `isCancelled(token)` reports
on what it currently holds — an in-flight entry or a remembered pre-open cancel
— so it answers `false` once the request is disposed, even for one that really
was cancelled. It has to: a durable record would accumulate cancelled-and-closed
ids for the executor's whole life, for the same reason the post-close cancel is
dropped. The handle's `isCancelled` does survive disposal, because the handle
holds the entry directly. Prefer the handle wherever one is in scope; reach for
the registry only when all you have is an id.

## Stream Close Signal

A streaming worker holds one `IsolateStreamCloseSignal` per open stream. A
host close request calls `requestClose`, which both raises the `closeRequested`
flag and fires the `closeSignal` future — so a backpressured producer can poll
the flag at its yield checkpoints while an unbounded producer awaits the future
alongside its source. `requestClose` is idempotent.

```dart
final signal = IsolateStreamCloseSignal();
// Unbounded producer: stop when source completes OR close is requested.
await Future.any([sourceDone, signal.closeSignal.future]);
// Backpressured producer: check between items.
if (signal.closeRequested) return;
```

## Backpressure

`BackpressureTracker` is a FIFO credit ledger. The consumer `grant`s credits
as it drains; the producer `awaitCredit`/`consume`s before emitting. Waiters are
released in arrival order, so a slow consumer paces a fast producer without an
unbounded buffer. Like the close signal, the ledger is held by the producer
inside the worker isolate; a cross-boundary consumer's drain reaches it as a
message that calls `grant`.

```dart
final bp = BackpressureTracker(initialCredits: 0);
bp.grant(2);                 // consumer signals room for 2 items
await bp.awaitCredit();      // producer blocks until a credit is free
bp.consume();                // spend one credit, then emit
bp.close();                  // fails parked waiters so producers unwind
```

`awaitCredit` does **not** decrement — it returns once `credits > 0`; the
producer calls `consume` after pushing the item. `grant(n)` must be positive and
wakes up to `n` FIFO waiters; `consume` rejects going negative. `credits`,
`waiterCount`, and `isClosed` expose the ledger state.

**After `close`, the ledger stops accounting but keeps checking.** `grant` and
`consume` become no-ops and `credits` freezes; only `awaitCredit` reports the
closure, failing with `StateError` — parked calls and later ones alike. That is
where a producer is meant to unwind, and it is the only place it has to handle:
a close routinely lands mid-iteration, after `awaitCredit` returned and the
chunk went out but before the trailing `consume`, so making that `consume` throw
would raise from the loop body instead. Argument checks are exempt from the
silence: `grant(0)` and `consume(-1)` throw `ArgumentError` whether the tracker
is open or closed, because a nonsensical count is a caller bug in either state.

## Request Guard

`IsolateRequestGuard` wraps each request future so that a request can never
hang past the worker's lifetime or a deadline. Each `guard` call fails with an
`IsolateRequestFailure` when the worker is marked dead or the per-request
timeout elapses, whichever comes first.

```dart
final guard = IsolateRequestGuard(defaultTimeout: Duration(seconds: 30));
final result = await guard.guard(
  workerReply.future,
  operation: 'embed',
);
// Elsewhere, on worker-exit detection:
guard.markWorkerDead('isolate exited with code 70');
// → every in-flight guarded request completes with
//   IsolateRequestFailure(reason: workerDeath, ...)
```

`isWorkerDead` and `inFlightCount` expose guard state; the failure's `reason`
distinguishes `workerDeath` from `timeout`, and its `message` carries the detail.

A timeout abandons the request; it does not stop the worker by itself. Pass
the request's cancellation token and a way to send it, and a timeout cancels
what it abandons:

```dart
final token = allocator.next();
final result = await guard.guard(
  workerReply.future,
  operation: 'embed',
  timeout: const Duration(seconds: 5),
  cancellation: token,
  cancel: (t) => workerPort.send(CancelRequest(t.id)),
);
```

`cancel` is called once, after the caller has been failed, and only for a
timeout: a request that completes is not cancelled, and a dead worker cannot
receive the envelope. The guard owns no port and knows no message catalogue —
`CancelRequest` above is the host's own envelope — so the sending is the
host's.

## Exception Registry

Errors thrown on a worker isolate arrive at the host as plain data. The
`IsolateExceptionRegistry` maps a string type-tag to an
`IsolateExceptionFactory` that rebuilds the typed error, so callers see the
real exception type rather than a generic envelope.

```dart
final registry = IsolateExceptionRegistry()
  ..register('NotFound', (msg, details) => NotFoundError(msg, id: details['id']));

final restored = registry.reconstruct('NotFound', 'missing', {'id': 'x-7'});
// restored is a NotFoundError, or null if 'NotFound' was never registered.
```

`reconstruct` returns `null` for an unregistered tag (the caller falls back to a
generic error); `isRegistered` and `registeredTypes` expose the taxonomy.

## Concurrency and Lifecycle

- **No isolate is spawned here.** Every primitive is a host- or worker-side
  helper; the caller owns the `Isolate.spawn` / `SendPort` wiring, so the suite
  exercises them directly rather than through isolate plumbing. The one place a
  real boundary appears is the sendability group, which pushes each type through
  a live `SendPort` to check what may cross. `example/isolate_streaming/` goes
  further: its cancellation demo spawns a real isolate, because which side owns
  what is the thing it demonstrates.
- **A request is not finished until its handle is disposed.**
  `IsolateCancellationHandle.dispose()` is what removes the entry from the
  registry, so an executor that skips it keeps that entry for its whole life —
  one per request served. Nothing fails and nothing is logged; `inFlightCount`
  is the number that would have said so, and it is the only one that would.
  Two further consequences follow for an undisposed id: the registry's
  `isCancelled` keeps answering for a request that ended, and a cancel arriving
  after the response is applied to a live entry rather than dropped, so the
  post-close rule below silently stops applying to it. Put the call in a
  `finally`, as `example/isolate_streaming/` does — every path out of a request
  has to reach it, including the cancelled ones, which are the paths that make
  a `finally` the only reliable place.
- **Idempotent close/cancel.** `IsolateStreamCloseSignal.requestClose`,
  `BackpressureTracker.close`, registry cancellation and `dispose` itself are
  all safe to call more than once.
- **Late signals are remembered — the pre-open ones.** The cancellation registry
  keeps a cancel that races ahead of its `register`, and drops one that arrives
  after the request closed; see [Cancellation](#cancellation) for the
  high-water mark that tells them apart.
- **Allocation and registration sit on opposite sides.** `allocator.next()` runs
  on the host, `registry.register` inside the worker isolate, and the token id
  is what travels between them — it is what keeps one request identifiable on
  both sides. Only that id crosses; the registry, the handle and
  `IsolateStreamCloseSignal` all hold a `Completer` and are unsendable.

## Core Components

- **Cancellation** — `IsolateCancellationToken`,
  `IsolateCancellationTokenAllocator`, `IsolateCancellationRegistry`,
  `IsolateCancellationHandle`, `IsolateCancellationException`.
- **`IsolateStreamCloseSignal`** — per-stream close flag + future.
- **`BackpressureTracker`** — FIFO credit ledger.
- **`IsolateRequestGuard`** — worker-death + deadline guard, with
  `IsolateRequestFailure` / `IsolateRequestFailureReason`.
- **`IsolateExceptionRegistry`** — type-tag → factory reconstruction, with the
  `IsolateExceptionFactory` typedef.

## Dependencies

| Dependency | Kind | Imported by | For |
| ---------- | ---- | ----------- | --- |
| `dart:async` | dart | `backpressure_tracker.dart`, `isolate_cancellation.dart`, `isolate_request_guard.dart`, `isolate_stream_close_signal.dart` | `dart:async` only. The module is `dart:io`-free and depends on no other `tom_core_agentic` module, so it is safe to reuse from any tier (including `dart:io`-forbidding consumers) |

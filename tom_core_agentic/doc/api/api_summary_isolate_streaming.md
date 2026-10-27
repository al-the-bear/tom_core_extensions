# Tom Core Agentic API Reference: Isolate Streaming Module

The symbol-level mirror of `lib/src/isolate_streaming/`: twelve exported types
across five libraries, with no top-level functions, constants or statics.

[`doc/isolate_streaming.md`](../isolate_streaming.md) explains how the pieces
fit a streaming protocol together. This document is arranged for lookup: one
heading per type, grouped by the concern it belongs to.

## Table of Contents

- [Overview](#overview)
- [Cancellation](#cancellation)
  - [IsolateCancellationToken](#isolatecancellationtoken)
  - [IsolateCancellationTokenAllocator](#isolatecancellationtokenallocator)
  - [IsolateCancellationRegistry](#isolatecancellationregistry)
  - [IsolateCancellationHandle](#isolatecancellationhandle)
  - [IsolateCancellationException](#isolatecancellationexception)
- [Request guarding](#request-guarding)
  - [IsolateRequestGuard](#isolaterequestguard)
  - [IsolateRequestFailure](#isolaterequestfailure)
  - [IsolateRequestFailureReason](#isolaterequestfailurereason)
- [Exception reconstruction](#exception-reconstruction)
  - [IsolateExceptionRegistry](#isolateexceptionregistry)
  - [IsolateExceptionFactory](#isolateexceptionfactory)
- [Flow control](#flow-control)
  - [BackpressureTracker](#backpressuretracker)
  - [IsolateStreamCloseSignal](#isolatestreamclosesignal)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

Sources: `lib/src/isolate_streaming/backpressure_tracker.dart`, `lib/src/isolate_streaming/isolate_cancellation.dart`, `lib/src/isolate_streaming/isolate_exception_registry.dart`, `lib/src/isolate_streaming/isolate_request_guard.dart`, `lib/src/isolate_streaming/isolate_stream_close_signal.dart`, `lib/src/isolate_streaming/isolate_streaming.dart`.

The module `lib/src/isolate_streaming/` is barrelled by `isolate_streaming.dart`.

Domain-free infrastructure for any cross-isolate streaming protocol. Nothing
here knows a message catalogue: the request and response *envelopes* that ferry
these types across a boundary belong to the adapter that owns the protocol, and
that separation is what lets one set of primitives serve every boundary.

**Which side each type lives on** is the fact to get right first, because two
of them cannot cross:

| Type | Host | Worker isolate | Sendable |
| ---- | :--: | :------------: | :------: |
| `IsolateCancellationToken` | allocates | keys off it | **yes** — a single `int` |
| `IsolateCancellationTokenAllocator` | ✓ | | no |
| `IsolateCancellationRegistry` | | ✓ | no |
| `IsolateCancellationHandle` | | ✓ | no |
| `IsolateRequestGuard` | ✓ | | no |
| `IsolateExceptionRegistry` | ✓ | | no |
| `BackpressureTracker` | producer side | | no |
| `IsolateStreamCloseSignal` | producer side | | no |

Only the token crosses. The registry and the handle hold live `Completer`s and
exist solely inside the executor's isolate; the guard and the exception
registry are host-side, because both are about what the host does when the
worker stops answering.

## Cancellation

A *protocol* family, not a behavioural one. The cooperative
`TomCancellationToken` from `tom_basics` is awaited and polled by the code
doing the work; these name a cancellable request crossing a boundary, and the
state lives in a registry rather than in the token. An adapter holds both,
which is why this family carries the `Isolate` prefix.

### IsolateCancellationToken

`final class`. The opaque identifier: one `int` field, `const`-constructible,
with value equality. Boxed rather than a raw `int` so a signature reads
`cancellation: token` instead of `cancellation: 7`. Allocated by the host,
carried in the adapter's request envelope, unique per host instance and never
recycled within a host's lifetime.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `id` | `final int id` | Monotonic integer assigned by the host. |

### IsolateCancellationTokenAllocator

`final class`. The host-side counter. `next()` hands out the next token;
`peekNext` reads the counter without consuming it, which is what a test asserts
against.

### IsolateCancellationRegistry

`final class`. The in-isolate state. `register(token)` returns a
handle, `cancel(token)` flips the flag, `isCancelled(token)` reads it, and
`inFlightCount` / `pendingCancelCount` expose the two maps for inspection.

The second of those is the part worth knowing: a cancel that arrives for a
token not yet registered is **held pending** rather than dropped, so the
protocol does not depend on the cancel envelope losing the race with the
request it cancels.

Telling a pre-open cancel from a post-close one needs ids to reach `register`
strictly increasing — one host allocator, ordered transport. `register`
**asserts** that, because a violation is otherwise silent: the pre-open cancel
is dropped and the request completes as though it had never been cancelled.

### IsolateCancellationHandle

`final class`. One request's view of the registry, returned by `register` and
not constructible otherwise. `isCancelled` polls, `cancelled` is a future that
completes on cancellation, and `throwIfCancelled()` is the checkpoint form.

**`dispose()` is required, on every path.** It is what removes the entry from
the registry, so an executor that skips it holds one entry per request served
for its whole life — silently, with `inFlightCount` the only reading that would
show it. Put it in a `finally`: the cancelled paths are the ones that otherwise
miss it.

#### Properties and Methods — further members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `token` | `final IsolateCancellationToken token` |  |

### IsolateCancellationException

`final class`. What a checkpoint raises when the flag is set, carrying the
token so a caller can tell which request ended.

## Request guarding

### IsolateRequestGuard

`final class`. Bounds every request crossing the boundary so it fails with a
typed error instead of hanging forever when the worker dies or takes too long.

```dart
Future<T> guard<T>(
  Future<T> request, {
  Duration? timeout,
  String? operation,
  IsolateCancellationToken? cancellation,
  void Function(IsolateCancellationToken token)? cancel,
})
```

Constructed with an optional `defaultTimeout` that each call may override
through `timeout`. `operation` names the request in the failure message and
defaults to `'isolate request'`. `markWorkerDead([detail])` fails every pending
request at once — the guard is *told* the worker died rather than inferring it
— and `isWorkerDead` / `inFlightCount` report the state.

`cancellation` and `cancel` come together or not at all (`ArgumentError`
otherwise). When the deadline elapses first, the caller's future fails with
`timeout` and then `cancel(cancellation)` is called once, so the host can send
its own protocol's cancel envelope and the worker can stop the work nobody is
waiting for. A completed request and a worker death never call it. The guard
owns no port, so sending is the host's.

### IsolateRequestFailure

`final class`. The typed failure: a `reason` and a `message`, `const`-
constructible, with a `toString` that names the reason.

### IsolateRequestFailureReason

`enum`: `workerDeath`, `timeout`. A closed set of two, which is the whole point
— a caller switches on it exhaustively rather than parsing a message.

## Exception reconstruction

### IsolateExceptionRegistry

`final class`. The host-side half of typed errors across the boundary. A
`SendPort` cannot carry a live exception, so a worker flattens what it caught
to a type tag, a message and a sendable details map; this turns that back into
the real type, so a consumer catches what the worker threw rather than a
generic wrapper.

`register(typeTag, factory)` installs a reconstructor, `isRegistered(typeTag)`
asks whether one exists, and `registeredTypes` lists them.
`reconstruct(typeTag, message, [details])` returns the rebuilt exception — or
**`null` for an unregistered tag**, which is the signal for the adapter to fall
back on its own generic boundary failure. The taxonomy is closed on purpose, so
`null` means either a core-Dart error or a genuinely unexpected escape.

It is `final` because the registry is specialised by what you register rather
than by subtyping; the extension point is the factory, which is already a
function type.

### IsolateExceptionFactory

```dart
typedef IsolateExceptionFactory =
    Object Function(String message, Map<String, Object?> details);
```

Rebuilds one exception type from its wire form. A closure rather than a
subclass, which is why the registry needs no hierarchy.

## Flow control

### BackpressureTracker

`final class`. A credit ledger held by a stream producer, so a fast producer
cannot outrun a slow consumer across the boundary.

`awaitCredit()` waits until credit is available (or the tracker closes),
`consume([n])` spends it, `grant(n)` adds it and wakes whoever is waiting, and
`close()` releases every waiter at once. `credits`, `waiterCount` and
`isClosed` report the state — `waiterCount` in particular is what a test uses
to assert that a producer actually parked rather than merely not having sent.

### IsolateStreamCloseSignal

`final class`. The per-stream clean-stop block: `closeRequested` and a
`closeSignal` future, flipped and completed together by `requestClose()`.
Separate from cancellation because a clean stop is not a failure — the consumer
has had enough, which ends the stream without raising anything.

## Global Functions and Constants

None — this module exports types only.

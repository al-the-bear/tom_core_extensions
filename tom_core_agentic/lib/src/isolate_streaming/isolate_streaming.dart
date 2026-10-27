// Generic, domain-free isolate-streaming infrastructure.
//
// These primitives back any cross-isolate streaming protocol (the
// brain-memory isolate boundary is the first consumer) but carry no
// memory- or transport-specific knowledge: the concrete request/response
// envelopes that ferry these types across a boundary belong to the
// adapter that owns the message catalogue.
//
//   * [IsolateCancellationToken] family — opaque sendable token, host
//     allocator, in-isolate registry, per-request handle, typed
//     exception.
//   * [BackpressureTracker] — credit-based producer/consumer flow
//     control.
//   * [IsolateStreamCloseSignal] — per-stream clean-stop block.
//   * [IsolateRequestGuard] — worker-death + per-request deadline race
//     that fails a pending request with a typed [IsolateRequestFailure]
//     instead of hanging when the worker isolate dies.
//   * [IsolateExceptionRegistry] — host-side map that reconstructs the
//     typed exception a worker threw from its flat wire form, so
//     consumers catch the real type instead of a generic wrapper.

export 'backpressure_tracker.dart';
export 'isolate_cancellation.dart';
export 'isolate_exception_registry.dart';
export 'isolate_request_guard.dart';
export 'isolate_stream_close_signal.dart';

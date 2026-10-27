// Close-signal block for a single in-isolate stream producer.
//
// A stream producer running inside an executor isolate holds one of
// these per open stream. A stream-close request from the host calls
// [requestClose], which both raises a flag (read at a backpressured
// producer's checkpoints) and fires a future (awaited by an unbounded
// producer instead of polling a timer). This lets either producer shape
// react to a clean stop without busy-waiting.

import 'dart:async';

/// Per-stream close-signal block held by a stream producer.
///
/// Held in the executor's per-stream map. A stream-close request calls
/// [requestClose], which raises [closeRequested] (read by a
/// backpressured producer at its checkpoints) and fires [closeSignal]
/// (awaited by an unbounded producer alongside its source completion and
/// cancellation future).
final class IsolateStreamCloseSignal {
  /// Raised by [requestClose]. A backpressured producer polls this flag at
  /// its yield checkpoints to stop emitting after the current item.
  bool closeRequested = false;

  /// Completes the first time [requestClose] is called. Never completes
  /// if the stream is not asked to close.
  final Completer<void> closeSignal = Completer<void>();

  /// Idempotently flags the stream for close and fires [closeSignal].
  void requestClose() {
    closeRequested = true;
    if (!closeSignal.isCompleted) closeSignal.complete();
  }
}

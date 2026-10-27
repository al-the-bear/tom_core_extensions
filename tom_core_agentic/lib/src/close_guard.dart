// Lifecycle close-guard.
//
// Objects that hold a resource (an HTTP client, a stream controller, a
// transport) repeat the same three-line dance: a `_closed` flag, a
// guard that throws on use-after-close, and an idempotent `close()`.
// This mixin owns the flag and the two operations so each class keeps
// only the resource-release logic that is genuinely its own.

/// Tracks a closed flag and rejects use-after-close.
///
/// Typical use:
///
/// ```dart
/// class MyClient with CloseGuard {
///   Future<Response> send(Request r) async {
///     ensureOpen('MyClient.send');
///     // ...
///   }
///
///   void close() {
///     if (!markClosed()) return; // already closed — idempotent
///     _socket.close();
///   }
/// }
/// ```
mixin CloseGuard {
  bool _closed = false;

  /// `true` once [markClosed] has transitioned this object to closed.
  bool get isClosed => _closed;

  /// Throws [StateError] if this object is closed. [operation] names
  /// the attempted call for the message, e.g. `'MyClient.send'` yields
  /// `'MyClient.send called after close()'`.
  void ensureOpen(String operation) {
    if (_closed) {
      throw StateError('$operation called after close()');
    }
  }

  /// Marks this object closed. Returns `true` if this call performed
  /// the transition, `false` if it was already closed — letting
  /// `close()` short-circuit and stay idempotent.
  bool markClosed() {
    if (_closed) return false;
    _closed = true;
    return true;
  }
}

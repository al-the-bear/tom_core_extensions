// Typed exception reconstruction across a cross-isolate request/response
// boundary.
//
// The problem this solves: a request/response isolate adapter catches a
// domain exception inside the worker, flattens it to a sendable wire form
// (a type tag + a human message + a sendable details map) because Dart's
// `SendPort` cannot carry an arbitrary live exception object — it may
// capture non-sendable state (closures, open resources, a `StackTrace`).
// The host then re-raises. If the host re-raises a single generic wrapper
// for every failure, consumers lose the ability to `catch` the specific
// type the worker threw and have to parse prose to recover the cause.
//
// [IsolateExceptionRegistry] is the generic, transport-agnostic answer.
// It is a host-side map from a worker exception's type tag to a factory
// that rebuilds the typed instance from the flat wire form. The adapter:
//
//   1. registers one factory per type in its *closed* exception
//      taxonomy (the worker's set of throwable domain exceptions);
//   2. on receiving an error envelope, calls [reconstruct] with the wire
//      `(typeTag, message, details)` and re-raises the result;
//   3. falls back to its own generic boundary failure when [reconstruct]
//      returns `null` (an unregistered type — the taxonomy is closed, so
//      this is either a core-Dart error like `StateError` or a genuinely
//      unexpected escape).
//
// It is deliberately ignorant of any concrete exception type and of
// `dart:isolate`: the adapter owns the message catalogue and decides what
// crosses the wire; the registry owns only the name→factory lookup and
// the unknown-type fallback contract. That keeps it in `tom_core_agentic`
// (tom_basics-only) and reusable by any isolate adapter, not just
// brain-memory.

/// Rebuilds a typed exception host-side from the flat wire form a worker
/// packed: the original `message` and a sendable `details` map of the
/// exception's structured fields.
///
/// Returns `Object` (not `Exception`) because Dart's `throw` accepts any
/// object and some domain taxonomies re-raise `Error` subtypes; the
/// registry does not constrain the thrown shape.
typedef IsolateExceptionFactory =
    Object Function(String message, Map<String, Object?> details);

/// Host-side registry that turns the flat wire form of a worker-thrown
/// exception (a type tag + message + sendable details map) back into a
/// typed instance, so consumers `catch` the same type the worker threw
/// instead of an untyped boundary wrapper.
///
/// One registry per isolate host. Domain-free: the concrete adapter
/// registers its closed taxonomy's factories; the registry owns only the
/// lookup and the unknown-type fallback (`reconstruct` returns `null`).
///
/// `final` because the registry is specialised by *what you register*,
/// not by subtyping — [IsolateExceptionFactory] is the extension point,
/// and it is already a function type, so an adapter with unusual
/// reconstruction needs supplies a closure rather than a subclass.
final class IsolateExceptionRegistry {
  final Map<String, IsolateExceptionFactory> _factories =
      <String, IsolateExceptionFactory>{};

  /// Registers [factory] as the reconstructor for the wire [exceptionType]
  /// tag (the worker's `runtimeType.toString()` for that class).
  ///
  /// Idempotent-by-overwrite: registering the same tag twice keeps the
  /// last factory. A host builds its full taxonomy once at construction.
  void register(String exceptionType, IsolateExceptionFactory factory) {
    _factories[exceptionType] = factory;
  }

  /// Whether [exceptionType] has a registered factory.
  bool isRegistered(String exceptionType) =>
      _factories.containsKey(exceptionType);

  /// The set of registered wire type tags. Visible for tests and for an
  /// adapter that wants to assert its taxonomy is fully wired.
  Iterable<String> get registeredTypes => _factories.keys;

  /// Reconstructs the typed exception for [exceptionType] from its wire
  /// [message] and [details], or returns `null` when no factory is
  /// registered — the caller falls back to its generic boundary failure.
  Object? reconstruct(
    String exceptionType,
    String message, [
    Map<String, Object?> details = const <String, Object?>{},
  ]) {
    final factory = _factories[exceptionType];
    if (factory == null) return null;
    return factory(message, details);
  }
}

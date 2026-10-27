// PlaceholderStack — the lexical scope chain placeholders resolve against.
//
// Part of the shared placeholder system, which lives in `tom_core_agentic` so
// every config layer — substrate / access / memory / run — and the engine
// share one resolver.
//
// The rule it implements is lexical scoping over nested call frames: each
// nested procedure or sub-call frame pushes a child scope; a child may bind
// its own variables — **even same-named** ones, shadowing the parent; on pop
// the child is discarded and the parent's bindings are restored, so a
// lower-level write never leaks upward. A nested call returns its result
// through the caller's return value, never by binding a name the parent later
// reads: the two channels stay distinct so a child cannot smuggle data out.
//
// The chain is modelled here as a Dart-side stack of frames rather than as
// the expression backing's own scopes, because a backing need not expose
// push/pop of its interpreter environment (d4rt, the engine's backing, does
// not). The simple `${name}` form reads a binding directly from this stack,
// and the `${{ … }}` form receives the *flattened* stack as the locals it
// evaluates against. Keeping the namespace here (a) gives push / same-name
// shadow / pop-restores-parent / no-upward-leak exactly, and (b) keeps both
// forms reading one set of bindings — the two spellings must never disagree
// about what a name means.
//
// One namespace, but not one *visible* namespace: a binding name is any
// string here, whereas a d4rt local must be an identifier, so a backing
// filters what it can express. See [isSimpleIdentifier].

/// Returns whether [name] is a bare Dart identifier.
///
/// This is **not** the grammar of the simple `${name}` form. That form has
/// no grammar: the scanner routes on prefix alone, so every body that is
/// not `env:` / `file:` / `state:` becomes a lookup key, and
/// [PlaceholderStack.bind] accepts
/// any string as a name. `${role.anchor}` — a built-in of the brain
/// substrate, and the first thing its system scaffold emits — is a bound,
/// resolvable, deliberately dotted name.
///
/// What it *is*: the shape a binding must have to be injected as a **d4rt
/// expression local**, because such a local becomes a parameter name in the
/// synthesised d4rt function. That constraint belongs to the backing rather
/// than to this package (which keeps no d4rt dependency), and the backing
/// applies it — `D4rtExpressionContext.evaluate` in `tom_brain_procedure`
/// filters [PlaceholderStack.flatten] through this predicate before
/// synthesising the parameter list.
///
/// The consequence is an asymmetry worth knowing: a non-identifier binding
/// is visible to `${name}` and invisible to `${{ … }}`. It is silently
/// dropped from the expression's locals, not reported as an error.
bool isSimpleIdentifier(String name) => _identifier.hasMatch(name);

final RegExp _identifier = RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$');

/// A stack of binding frames implementing lexical, shadowing scope.
///
/// Starts with a single root frame. [push] opens a child frame; [bind]
/// always writes to the current (top) frame; [lookup] / [has] walk
/// top→root so a child binding shadows a same-named parent one; [pop]
/// discards the top frame and restores the parent's view.
final class PlaceholderStack {
  /// Creates a stack with a single, empty root frame.
  PlaceholderStack() : _frames = <Map<String, Object?>>[<String, Object?>{}];

  final List<Map<String, Object?>> _frames;

  /// Number of frames currently on the stack (the root counts as 1).
  int get depth => _frames.length;

  /// Pushes a new child frame, optionally seeded with [initial] bindings.
  ///
  /// The seed is copied, so later mutation of [initial] does not leak into
  /// the frame.
  void push([Map<String, Object?>? initial]) {
    _frames.add(<String, Object?>{...?initial});
  }

  /// Pops and discards the top frame, restoring the parent's bindings.
  ///
  /// Throws a [StateError] if only the root frame remains — the root is
  /// never popped.
  void pop() {
    if (_frames.length == 1) {
      throw StateError('PlaceholderStack: cannot pop the root frame');
    }
    _frames.removeLast();
  }

  /// Binds [name] to [value] in the current (top) frame, shadowing any
  /// same-named binding in a parent frame for as long as this frame lives.
  ///
  /// [name] is not validated: any string is a legal binding name, and the
  /// simple `${name}` form will resolve it. Only a `${{ … }}` backing
  /// constrains the shape — see [isSimpleIdentifier].
  void bind(String name, Object? value) {
    _frames.last[name] = value;
  }

  /// Binds every entry of [values] in the current (top) frame.
  void bindAll(Map<String, Object?> values) {
    _frames.last.addAll(values);
  }

  /// Whether any frame currently binds [name].
  bool has(String name) => _frames.any((f) => f.containsKey(name));

  /// The value bound to [name] in the nearest enclosing frame, or `null`
  /// when no frame binds it.
  ///
  /// Because a binding may legitimately hold `null`, callers that must
  /// distinguish "absent" from "bound to null" should consult [has] first.
  Object? lookup(String name) {
    for (var i = _frames.length - 1; i >= 0; i--) {
      final frame = _frames[i];
      if (frame.containsKey(name)) {
        return frame[name];
      }
    }
    return null;
  }

  /// The whole chain flattened into one map, with child frames winning on
  /// name collisions — the binding view a `${{ … }}` expression sees.
  Map<String, Object?> flatten() {
    final merged = <String, Object?>{};
    for (final frame in _frames) {
      merged.addAll(frame);
    }
    return merged;
  }
}

/// The two deadlines that bound a test which spawns a server child, and the
/// rule that relates them.
///
/// **The bug this file exists to prevent.** Every standalone-transport test set
/// `startupTimeout: 30s`, and `dart test`'s default per-test timeout is *also*
/// 30s. Two equal deadlines, one of which starts earlier: the harness timer
/// covers `setUp`, the fixture server's own bind, `probe` (which spawns
/// `node --version`) and `connect` (which spawns it again, then the child) —
/// so the harness bound was reached **first, always**, and the transport's own
/// bound could essentially never fire.
///
/// That is not merely an ordering curiosity. When the harness deadline fires it
/// **abandons the test body mid-`connect`**, leaving a live child. `tearDown`
/// then calls `close`, which sends the child SIGTERM, and the in-flight
/// `_awaitReadyPort` — whose timer is still active — reports the resulting exit
/// as *"the standalone AI server exited with code -15 before it was ready"*.
/// One slow start therefore produced a timeout, a second failure blaming the
/// child for a signal we sent, and a third in the next file whose guard
/// refused to claim a pass it had not earned. All three of a test's
/// symptoms, from one cause.
///
/// **The rule.** A spawning test's harness bound MUST be strictly greater than
/// the transport's startup bound, by a margin that covers everything else the
/// body does. Then a slow start fails as a *transport* error, inside a live
/// test, with `tearDown` running normally and the child reaped — and the
/// failure names the real reason instead of a phantom crash.
///
/// This is deliberately **not** "raise the timeout until it passes". The
/// startup bound is unchanged at 30s, so the load at which a start is judged
/// too slow is exactly where it was; what changes is that exceeding it is now
/// reported once, truthfully, by the layer that knows why.
library;

/// How long a spawned fixture may take to print its ready line.
///
/// Unchanged from what the tests always used. A Dart VM spawn of the fixture
/// measures ~0.4s unloaded, so 30s is already two orders of magnitude of head
/// room; a machine that cannot make it has a problem worth reporting rather
/// than waiting out.
const spawnStartupTimeout = Duration(seconds: 30);

/// The harness bound for a test that spawns a child.
///
/// Three times the startup bound. The margin is not decoration: a single
/// standalone test spawns `node --version` twice (`probe` and `connect` share
/// the check deliberately, so they cannot disagree about the same runtime) and
/// the server once, and the fixture server binds a socket of its own — none of
/// which is inside [spawnStartupTimeout].
const spawnTestTimeout = Duration(seconds: 90);

/// The invariant, as a value a test can assert rather than a comment a reader
/// has to trust.
bool get spawnDeadlinesAreOrdered => spawnStartupTimeout < spawnTestTimeout;

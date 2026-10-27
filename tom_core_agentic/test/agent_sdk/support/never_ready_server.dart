/// A fixture that starts and then never announces itself.
///
/// The one shape the startup wait cannot be exercised with otherwise: a child
/// that is alive and responsive to signals but has printed no ready line, which
/// is what a genuinely slow start looks like from the parent's side. It exits
/// when stdin closes, like every other fixture here, so a well-behaved close
/// still reaps it.
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  await stdin.drain<void>();
  exit(0);
}

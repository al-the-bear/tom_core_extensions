/// Refuses to run an example whose checks have been compiled out.
///
/// Every example in this folder verifies itself with `assert`, and `dart run`
/// strips asserts unless it is given `--enable-asserts`. Without the flag an
/// example executes every line, prints a plausible transcript and exits 0 —
/// verifying nothing, in a way that cannot be told from success.
///
/// `test/examples_test.dart` already runs each example under the command its
/// header documents, which is what keeps the examples themselves honest. It
/// does nothing for a reader who runs one from memory without the flag: their
/// run still passes silently. Refusing here is what closes that half.
/// `tom_core_kernel`'s samples refuse the same way, for the same reason.
library;

import 'dart:io';

/// Exits with status 2 and a sentence naming the fix when asserts are off.
///
/// Call it first in `main`, before anything the example demonstrates.
void requireAsserts() {
  if (!_assertsEnabled) {
    stderr.writeln(
      'Asserts are disabled, so this example would verify nothing.\n'
      'Every check in it is an `assert`, and `dart run` strips them.\n'
      'Re-run with the flag:\n'
      '\n'
      '    dart run --enable-asserts <example>\n',
    );
    exit(2);
  }
}

/// Whether asserts are being evaluated in this run.
///
/// The assignment inside the `assert` is the standard detection idiom: it is
/// the assert's condition, so it runs only when asserts are on.
bool get _assertsEnabled {
  var enabled = false;
  assert(enabled = true);
  return enabled;
}

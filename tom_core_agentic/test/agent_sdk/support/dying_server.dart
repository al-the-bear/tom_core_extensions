/// A fixture that exits before it is ready, of its own accord.
///
/// Distinguishes "the child died" from "we killed it": both arrive at the
/// parent as a process exit during the startup wait, and only one of them is
/// the child's doing.
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  exit(3);
}

/// The other of two reflected classes sharing a simple name, for the ambiguity
/// refusal; nothing on the wire refers to either.
library;

import 'package:tom_core_server/tom_core_server.dart';

/// A twin.
@tomReflector
class FixtureTwin {
  /// A member.
  String b = '';

  /// A twin.
  FixtureTwin();
}

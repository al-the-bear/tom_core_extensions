/// No artefact of this package cites a document in the AI-state mount.
///
/// `_ai/` is `tom_agent_state`, a separate repository symlinked into the
/// workspace, so a reader holding this package without that layer cannot
/// follow such a reference. Citing another package in the code tree is fine —
/// that ships with a checkout. The rule, its scope and its one exemption (the
/// runtime `_ai/trail/` directory, which code may operate on and name) are
/// stated once, in `tom_ai/core/tool/check_doc_ai_citations.py`; this suite
/// runs that checker over this package so a citation fails here, where it was
/// written.
library;

import 'package:test/test.dart';

import '../../../core/tool/package_gate.dart';

void main() {
  test('no artefact cites a document in the AI-state mount', () {
    final result = runPackageGate('check_doc_ai_citations');
    expect(
      result.faults,
      0,
      reason: 'state the reason inline instead of citing it:\n${result.output}',
    );
  });
}

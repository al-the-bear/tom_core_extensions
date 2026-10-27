/// AI sessions for a suite, released when the test ends.
///
/// In an isolate of their own, as every root runs them — unless [inProcess],
/// for a suite whose stand-in transport holds state the test reads, which a
/// copy in another isolate would not share.
library;

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';

AgentSdkSessionManager testSessions({bool inProcess = false}) {
  final sessions = AgentSdkSessionManager(
    hosting: inProcess
        ? AgentSdkSessionHosting.inProcess
        : AgentSdkSessionHosting.isolate,
  );
  addTearDown(sessions.dispose);
  return sessions;
}

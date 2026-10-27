/// Keyed three-way merge and background sync for Tom applications.
///
/// A record codec contract and the keyed merge it drives; conflict records; a
/// history store with retention, and its file-medium implementation; and the
/// sync engine and scheduler that keep containers converged with their remotes
/// over a compare-and-swap storage port. Platform-neutral.
library;

export 'src/conflict.dart';
export 'src/history_store.dart';
export 'src/keyed_merge.dart';
export 'src/medium_history_store.dart';
export 'src/record_codec.dart';
export 'src/sync_engine.dart';
export 'src/sync_exceptions.dart';
export 'src/sync_policy.dart';
export 'src/sync_scheduler.dart';
export 'src/sync_state.dart';
export 'src/sync_unit.dart';

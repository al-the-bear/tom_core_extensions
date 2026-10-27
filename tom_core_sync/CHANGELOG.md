# Changelog

## 0.1.0

### Added

- **The keyed three-way merge.** `tomMergeKeyed` over a `TomRecordCodec`
  (key, stamp, canonical bytes): a key only one side changed takes that side,
  the same change on both sides is no conflict, an edit against a deletion
  keeps the edit — silently or reported (`TomDeleteEditPolicy`) — and two
  different edits go to the newer stamp, a tie settled by `TomMergeTie`, with
  the loser on the `TomMergeConflict`. Copies of different major formats are
  refused with `TomMergeRefusedException` before anything is compared.
  `tomMergeConflictOf` builds a conflict over a triple a caller holds.
- **Conflict records.** `TomSyncConflict`, the anchor every queued conflict
  shares, and `TomConflictRecord`, which keeps the unsettled key, the loser's
  locator and the loser across a save and a reopen.
- **History.** The `TomHistoryStore` port, `tomHistoryDepth` (20) and
  `tomHistoryStamp`; `TomMediumHistoryStore` keeps versions as files in a
  `TomBundleMedium`, prunes per record and never removes a protected version
  or a path it is told to leave alone.
- **The sync loop.** `TomSyncUnit`, `TomSyncEngine` (state machine, pull,
  merge and compare-and-swap push through the unit, edit coalescing, the
  offline journal, total transport verdicts, one `sync.cycle` diagnostics
  event per cycle), `TomSyncState` and `TomSyncStatus`; `TomSyncScheduler`
  with one batched head read per backend per tick, per-backend waits
  (`TomSyncDeferral`), retry members (`TomSyncRetry`) and a `TomSyncPolicy`
  (`TomFixedSyncPolicy`, `TomSyncDirection`); `TomCasExhaustedException` and
  `TomCommitFailedException`.

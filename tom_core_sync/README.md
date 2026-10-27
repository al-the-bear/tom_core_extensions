# tom_core_sync

Published on pub.dev as [`tom_core_sync` 0.1.0](https://pub.dev/packages/tom_core_sync).

> **Attribution.** The Tom Framework is developed by Peter Nicolai Alexis Kyaw.
> These packages are BSD-3-Clause licensed and published on pub.dev.

Keyed three-way merge and background sync for Tom applications — a record
codec contract and the merge it drives, conflict records, a history store with
retention, and a sync engine and scheduler that keep containers converged with
their remotes over `tom_core_storage`'s compare-and-swap storage port.
Platform-neutral: no `dart:io`, no container format, no network stack of its
own.

## Overview

An application that keeps the same records on several devices needs three
things, and they are the same whatever the records are:

- **A merge that knows who changed what.** `tomMergeKeyed` merges two copies of
  a keyed collection against their common ancestor, per key: a key only one
  side changed takes that side; the same change on both sides is no conflict;
  an edit against a deletion keeps the edit; two different edits go to the
  newer stamp and are reported with the loser on them. The application says
  how to read one record through a `TomRecordCodec` — its key, its stamp, its
  canonical bytes — and chooses two policies: how a tie is settled
  (`TomMergeTie`) and whether an edit against a deletion is reported
  (`TomDeleteEditPolicy`). Copies of different major formats are refused
  before anything is compared (`TomMergeRefusedException`).
- **Somewhere to keep what lost.** A conflict's loser is retained as a prior
  version in a `TomHistoryStore`, and a `TomConflictRecord` remembers which
  record is unsettled and where its loser is, across a save and a reopen.
  History is bounded at `tomHistoryDepth` versions per record, and pruning
  never removes a version a record still names. `TomMediumHistoryStore` keeps
  history as files in a `tom_core_storage` medium; a record container keeps it
  in its own way (`tom_kdbx_store` implements the port over KDBX entry
  history).
- **A loop that converges without being asked.** `TomSyncEngine` keeps one
  `TomSyncUnit` converged with its remote: pull, merge, compare-and-swap push,
  edits coalesced into one push of the working copy, commits the transport
  refused journaled in a `TomCommitJournal` and delivered later, a status
  (`TomSyncStatus`) after every transition. `TomSyncScheduler` drives many
  engines off one timer and **one head read per backend per tick**, honours
  each backend's rate-limit wait separately, and applies a `TomSyncPolicy` —
  whether the timer runs, which units it touches, which half of a cycle each
  runs.

A unit owns its serialization and its merge; the engine owns the state
machine, the journal and the schedule. That split is what lets unrelated kinds
of container — a document, a folder's annotations — share one loop, one
conflict queue and one status surface.

## Installation

Add it from pub.dev:

```yaml
dependencies:
  tom_core_sync: ^0.1.0
```

Dart SDK `^3.10.0`. No Flutter dependency.

## Features

| Type | What it does |
| ---- | ------------ |
| `TomRecordCodec` | How the merge reads a record: key, stamp, canonical bytes. |
| `tomMergeKeyed`, `TomKeyedMergeResult` | The keyed three-way merge; the merged records in first-seen order, the conflicts and their losers. |
| `TomMergeTie`, `TomDeleteEditPolicy` | How a tie between two edits is settled; whether an edit against a deletion is reported. |
| `TomMergeConflict`, `tomMergeConflictOf` | Two divergent versions of one record with the version kept; a conflict over a triple a caller holds. |
| `TomMergeRefusedException` | Copies that are not copies of the same thing, refused before any comparison. |
| `TomSyncConflict`, `TomConflictRecord` | The anchor every queued conflict shares; the persistent record of an unresolved conflict. |
| `TomHistoryStore`, `tomHistoryDepth`, `tomHistoryStamp` | The history port, its default retention and the file-name stamp. |
| `TomMediumHistoryStore` | History as `<dir>/<id>/<stamp><ext>` files in a `TomBundleMedium`. |
| `TomSyncUnit` | One container the loop converges: locator, head, edits, pull, push. |
| `TomSyncEngine` | The state machine, the cycle, coalescing and the offline journal for one unit. |
| `TomSyncState`, `TomSyncStatus` | Clean, dirty, syncing, conflicted; with offline, rate-limit, key and journal facts beside them. |
| `TomSyncScheduler`, `TomSyncRetry`, `TomSyncDeferral` | One clock and one batched head read for many engines; queued work tried again on the same clock; a backend's standing wait. |
| `TomSyncPolicy`, `TomFixedSyncPolicy`, `TomSyncDirection` | What the loop may do, how often and to which units. |
| `TomCasExhaustedException`, `TomCommitFailedException` | A push that lost every race; a commit the transport never received. |

## Quick start

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:tom_core_sync/tom_core_sync.dart';

class Task {
  final String id;
  final String title;
  final DateTime changed;
  const Task(this.id, this.title, this.changed);
}

class TaskCodec implements TomRecordCodec<Task> {
  const TaskCodec();
  @override
  String idOf(Task record) => record.id;
  @override
  DateTime modifiedOf(Task record) => record.changed;
  @override
  Uint8List canonicalBytes(Task record) =>
      utf8.encode('${record.id}\n${record.title}');
}

void main() {
  final base = {'t1': Task('t1', 'Draft', DateTime.utc(2026, 1, 1))};
  final result = tomMergeKeyed(
    base: base,
    ours: {'t1': Task('t1', 'Draft v2', DateTime.utc(2026, 1, 2))},
    theirs: {'t1': Task('t1', 'Draft v3', DateTime.utc(2026, 1, 3))},
    codec: const TaskCodec(),
  );
  print(result.merged['t1']!.title); // Draft v3 — the newer edit
  print(result.losers['t1']!.title); // Draft v2 — retain it in history
}
```

## Limits

- **No container format.** What a unit stores, how it serializes and how it
  merges are the application's; the package merges keyed collections and
  drives units.
- **The loop is poll-driven.** A push notification may call `syncNow` to
  shorten latency; correctness never depends on one arriving.
- **No relay.** A content-blind relay between devices is not part of the
  package.

## Dependencies

| Dependency | Kind | For |
| ---------- | ---- | --- |
| `tom_basics` | runtime | the diagnostics port each cycle is recorded through |
| `tom_core_storage` | runtime | the storage port, keyed file media, the commit journal and the rate-limit vocabulary |
| `meta` | runtime | `@visibleForTesting` |
| `test`, `lints` | dev | the suite |

## Status

Version **0.1.0**. `dart test` runs the unit suite — the merge's classes,
ties and refusals, conflict records, the file-medium history store and its
pruning, the engine over a test unit (coalescing, conflicts, the offline
journal, rate limits, a locked container, opaque heads, its diagnostics) and
the scheduler (one head read per backend, per-backend waits, retry members,
the policy) — and a walk of the import closure plus a dart2js compile, which
keep the package platform-neutral.

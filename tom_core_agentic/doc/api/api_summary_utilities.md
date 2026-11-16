# Tom Core Agentic API Reference: Utilities

The symbol-level mirror of the small, domain-free helpers the main library
`package:tom_core_agentic/tom_core_agentic.dart` exports beside its units:
twenty-eight files directly under `lib/src/`, declaring twenty-five types,
twenty-eight top-level functions and five top-level constants.

None of these helpers knows about an agent, a model or a memory store. Each
one captures an operation several components needed and wrote by hand — a
guard, a clock seam, a cache, a parser — so it is defined once. This document
is arranged for lookup: one heading per type, then one heading per top-level
function and constant.

## Table of Contents

- [Overview](#overview)
- [Classes](#classes)
  - [ShutdownAction](#shutdownaction)
  - [ProcessTerminator](#processterminator)
  - [AsyncShutdownCoordinator](#asyncshutdowncoordinator)
  - [CategoryLog](#categorylog)
  - [CloseGuard](#closeguard)
  - [DeadlineExceeded](#deadlineexceeded)
  - [Deadline](#deadline)
  - [DeliberationVerdict](#deliberationverdict)
  - [HttpDate](#httpdate)
  - [LatencySummary](#latencysummary)
  - [MapFieldErrorFactory](#mapfielderrorfactory)
  - [MapFieldReader](#mapfieldreader)
  - [ScopedPath](#scopedpath)
  - [PathScope](#pathscope)
  - [PathScopeIo](#pathscopeio)
  - [PlanStepOrdering](#planstepordering)
  - [ProcedureRerankWeights](#procedurererankweights)
  - [TokenBucketPolicy](#tokenbucketpolicy)
  - [TokenBucketSnapshot](#tokenbucketsnapshot)
  - [TokenBucket](#tokenbucket)
  - [ParsedToolCall](#parsedtoolcall)
  - [TtlCache](#ttlcache)
  - [YamlConfigErrorFactory](#yamlconfigerrorfactory)
  - [YamlConfigReader](#yamlconfigreader)
  - [YamlMapErrorFactory](#yamlmaperrorfactory)
- [Global Functions and Constants](#global-functions-and-constants)

## Overview

The files `lib/tom_core_agentic.dart` exports straight from `lib/src/`, one
line each.

Sources:

| File | Declares |
| ---- | -------- |
| `lib/src/argument_guards.dart` | `requireNonEmpty` — rejects an empty required string with an `ArgumentError`. |
| `lib/src/async_shutdown.dart` | `AsyncShutdownCoordinator`, `ShutdownAction`, `ProcessTerminator`, `shutdownExitOk`, `shutdownExitError` — trigger, awaited teardown, then process exit. |
| `lib/src/category_log.dart` | `CategoryLog` — a category-tagged facade over the global `tomLog`. |
| `lib/src/close_guard.dart` | `CloseGuard` — a closed flag with a use-after-close guard and an idempotent close transition. |
| `lib/src/collection_equality.dart` | `mapEquals`, `setEquals`, `listEquals`, `deepValueEquals`, `deepValueHash` — structural equality and its hash companion. |
| `lib/src/day_boundary.dart` | `startOfDay`, `nextDayStart` — calendar-day truncation that keeps the instant's zone. |
| `lib/src/deadline.dart` | `Deadline`, `DeadlineExceeded` — a wall-clock expiry over an injectable clock. |
| `lib/src/dedup_by_id.dart` | `buildUniqueById` — an unmodifiable id-keyed map that refuses duplicate ids. |
| `lib/src/deliberation_cue.dart` | `DeliberationVerdict`, `deliberationCues`, `classifyDeliberationCue` — deterministic detection of "think it through" cue phrases. |
| `lib/src/exception_format.dart` | `formatException` — the canonical `toString` of a typed exception. |
| `lib/src/http_date.dart` | `HttpDate` — RFC 7231 HTTP-date parsing without `dart:io`. |
| `lib/src/json_helpers.dart` | `decodeJsonObject` — decodes a JSON column into a map, with a context-tagged error for a non-object. |
| `lib/src/latency_summary.dart` | `LatencySummary`, `percentileDuration`, `nearestRankPercentile` — nearest-rank percentiles and a count/min/max/p50/p95 summary. |
| `lib/src/map_field_reader.dart` | `MapFieldReader`, `MapFieldErrorFactory` — typed, path-located reads over a plain map from an untrusted boundary. |
| `lib/src/path_scope.dart` | `PathScope`, `ScopedPath` — lexical containment of a path within a union of roots. |
| `lib/src/path_scope_io.dart` | `PathScopeIo` — the symlink-resolving, filesystem-aware containment check. |
| `lib/src/plan_ordering.dart` | `PlanStepOrdering`, `orderPlanSteps` — topological ordering of plan steps with cycle reporting. |
| `lib/src/procedure_rerank.dart` | `ProcedureRerankWeights`, `scoreProcedureCandidate`, `recencyDecay` — the four-factor re-rank score for procedure selection. |
| `lib/src/prompt_sha256.dart` | `promptSha256` — the `sha256:<hex>` content fingerprint. |
| `lib/src/sql_helpers.dart` | `sqlPlaceholders`, `fnv1a32`, `sqlSafeIdentifier`, `blobFromColumnOrNull`, `blobFromColumn` — SQLite query-building idioms. |
| `lib/src/system_clock.dart` | `systemClock` — the production default for an injectable clock. |
| `lib/src/text_preview.dart` | `textPreview` — a length-bounded preview with an ellipsis. |
| `lib/src/token_bucket.dart` | `TokenBucket`, `TokenBucketPolicy`, `TokenBucketSnapshot` — a keyed continuous-refill token bucket. |
| `lib/src/token_estimate.dart` | `approxCharsPerToken`, `estimateTokens` — the char/4 token-count estimate. |
| `lib/src/tool_call_text_parser.dart` | `ParsedToolCall`, `parseToolCallsFromText`, `looksLikeToolCallAttempt` — tool calls a model wrote into its completion text. |
| `lib/src/ttl_cache.dart` | `TtlCache` — an absolute-TTL cache with lazy sweep and an optional LRU ceiling. |
| `lib/src/yaml_config_reader.dart` | `YamlConfigReader`, `YamlConfigErrorFactory` — typed config reads and `${env:NAME}` expansion. |
| `lib/src/yaml_to_map.dart` | `loadYamlAsMap`, `YamlMapErrorFactory` — YAML parsed into plain maps and lists, with an alias-expansion bound. |

## Classes

### ShutdownAction

```dart
typedef ShutdownAction = Future<void> Function();
```

The async teardown an `AsyncShutdownCoordinator` runs on the first trigger. It
returns when teardown is complete; when it throws, the process still terminates,
with `shutdownExitError`.

### ProcessTerminator

```dart
typedef ProcessTerminator = void Function(int code);
```

Terminates the process with `code`. Production passes `dart:io`'s `exit`
wrapped to this shape; a test injects a recorder so the process survives.

### AsyncShutdownCoordinator

`final class AsyncShutdownCoordinator<S>`. Watches trigger streams of type `S`
(OS signals, supervisor messages, test stimuli) and runs an async teardown to
completion before terminating the process. The first trigger wins: it sets
`isTriggered`, cancels the trigger subscriptions, awaits the `ShutdownAction`
(logging start and finish through `tomLog` under the label), resolves
`completed` with the exit code and calls the `ProcessTerminator` last. A trigger
arriving while the teardown runs is logged and ignored. It has no public
constructor; `install` builds it.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `isTriggered` | `bool get isTriggered` | Whether a trigger has begun the shutdown sequence; once `true`, further triggers are ignored. |
| `completed` | `Future<int> get completed` | Resolves with the exit code after the teardown ran: `shutdownExitOk` when clean, `shutdownExitError` when the action threw. Never resolves without a trigger. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `dispose` | `Future<void> dispose()` | Stops listening without triggering a shutdown. Idempotent and safe in a `finally`. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `install` | `static AsyncShutdownCoordinator<S> install<S>({required String label, required ShutdownAction onShutdown, required List<Stream<S>> signals, required ProcessTerminator terminate})` | Builds a coordinator and subscribes to every stream in `signals` at once. `label` tags the log lines. |

### CategoryLog

`abstract base class`. A category-tagged facade over the global `tomLog`. A
subclass implements `categoryName` and offers its categories as `const` static
instances. Each level method prefixes the message with `'[<categoryName>] '`
and forwards it to the matching `tomLog` method; a lazy `() => Object` message
stays lazy, the tag being added only when it is evaluated.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `CategoryLog` | `const CategoryLog()` | `const`, so subclasses can offer `const` category instances. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `categoryName` | `String get categoryName` | The category used as the prefix, without brackets. Abstract. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `trace` | `void trace(Object message)` | Most verbose level. |
| `debug` | `void debug(Object message)` | Detailed debugging information. |
| `traffic` | `void traffic(Object message)` | Network and data-flow logging. |
| `info` | `void info(Object message)` | General runtime information. |
| `warn` | `void warn(Object message)` | A potentially problematic situation that did not stop the operation. |
| `status` | `void status(Object message)` | An important lifecycle event, visible even under the `silent` filter. |
| `error` | `void error(Object message)` | A recoverable error condition. |
| `severe` | `void severe(Object message)` | A serious error that may need attention. |
| `fatal` | `void fatal(Object message)` | An unrecoverable error, for paths that precede an exit. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `tagMessage` | `static Object tagMessage(String category, Object message)` | Prefixes `message` with `'[<category>] '`; for a zero-argument function it returns a function that adds the tag when called. |

### CloseGuard

`mixin`. Owns a closed flag for an object that holds a resource: `ensureOpen`
rejects use after close, and `markClosed` performs the transition once so the
class's own `close()` can stay idempotent.

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `isClosed` | `bool get isClosed` | `true` once `markClosed` has closed the object. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `ensureOpen` | `void ensureOpen(String operation)` | Throws `StateError('<operation> called after close()')` when closed. |
| `markClosed` | `bool markClosed()` | Closes the object; returns `true` when this call made the transition, `false` when it was already closed. |

### DeadlineExceeded

`final class`, implements `Exception`. Raised by `Deadline.throwIfExpired` when
the wall-clock budget has elapsed. Domain-free: a caller wanting its own failure
type catches it and rethrows.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `DeadlineExceeded` | `const DeadlineExceeded(DateTime expiresAt)` | Builds the failure for the passed expiry instant. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `expiresAt` | `final DateTime expiresAt` | The expiry instant that was reached or passed. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `'DeadlineExceeded: wall-clock deadline <expiresAt> passed'`. |

### Deadline

`final class`. A wall-clock expiry instant read against an injectable clock
(default `systemClock`). It is expired once the clock reaches or passes
`expiresAt`; the instant itself counts as expired.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `Deadline.at` | `Deadline.at(DateTime expiresAt, {DateTime Function()? clock})` | A deadline expiring at `expiresAt`. |
| `Deadline.startingNow` | `factory Deadline.startingNow(Duration budget, {DateTime Function()? clock})` | A deadline expiring `budget` after the clock's current time. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `expiresAt` | `final DateTime expiresAt` | The instant at and after which the deadline is expired. |
| `isExpired` | `bool get isExpired` | Whether the clock has reached or passed `expiresAt`. |
| `remaining` | `Duration get remaining` | Time left until expiry, clamped to `Duration.zero` once expired. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `throwIfExpired` | `void throwIfExpired()` | Throws `DeadlineExceeded` when `isExpired`, otherwise returns. |

### DeliberationVerdict

`enum`. Which execution branch a prompt's surface text points to, as
`classifyDeliberationCue` decides it.

#### Values

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `normal` | `normal` | No deliberation cue present: the fast answer path. |
| `thinking` | `thinking` | A deliberation cue is present: the slower think-it-through path. |

### HttpDate

`final class`. Parser for the three date formats RFC 7231 § 7.1.1.1 permits in
an HTTP-date header, using only core Dart so it compiles for the web. It accepts
RFC 1123 (`Wed, 21 Oct 2026 07:28:00 GMT`), RFC 850
(`Wednesday, 21-Oct-26 07:28:00 GMT`, two-digit years read as 20xx) and asctime
(`Wed Oct 21 07:28:00 2026`).

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `parse` | `static DateTime parse(String input)` | Returns a UTC `DateTime`. Throws `FormatException` on unparseable input, an unknown month, or a day, hour, minute or second out of range (second 60 is allowed for a leap second). |

### LatencySummary

`final class`. An immutable summary of latency samples: count, min, max, p50
and p95. Carries no pass threshold of its own; the caller supplies one to
`meetsTarget`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `LatencySummary` | `const LatencySummary({required int sampleCount, required Duration min, required Duration max, required Duration p50, required Duration p95})` | Builds a summary from its fields. |
| `LatencySummary.fromSamples` | `factory LatencySummary.fromSamples(List<Duration> samples)` | Sorts a copy of `samples` (the caller's list is untouched) and computes the percentiles with `percentileDuration`. Throws `ArgumentError` for an empty list. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `sampleCount` | `final int sampleCount` | Number of samples summarised. |
| `min` | `final Duration min` | The smallest sample. |
| `max` | `final Duration max` | The largest sample. |
| `p50` | `final Duration p50` | The median sample. |
| `p95` | `final Duration p95` | The 95th-percentile sample. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `meetsTarget` | `bool meetsTarget(Duration target)` | Whether `p95 <= target`. |

### MapFieldErrorFactory

```dart
typedef MapFieldErrorFactory = Object Function(String message);
```

Builds the exception a `MapFieldReader` throws: it receives the finished message
and wraps it in the caller's own error type (for example
`FormatException.new`).

### MapFieldReader

`final class`. Type-safe accessors over a plain `Map<Object?, Object?>` whose
values come from an untrusted boundary (decoded JSON, script input, hand-edited
config). Every accessor takes a `path`, the dotted location of the value, which
appears verbatim in the error message. Failures read `Missing required field:
<path>` or `<path> must be a <type> (got <runtimeType>).` and are thrown through
`errorFactory`.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `MapFieldReader` | `const MapFieldReader(MapFieldErrorFactory errorFactory)` | A reader throwing through `errorFactory`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `errorFactory` | `final MapFieldErrorFactory errorFactory` | Wraps a message in the caller's error type. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `optionalString` | `String? optionalString(Map<Object?, Object?> map, String key, String path)` | The string at `key`, or `null` when absent; throws when present but not a string. |
| `requireString` | `String requireString(Map<Object?, Object?> map, String key, String path)` | The string at `key`; throws when missing, `null` or not a string. |
| `optionalNum` | `num? optionalNum(Map<Object?, Object?> map, String key, String path)` | The number at `key`, or `null` when absent; throws when not a number. |
| `optionalBool` | `bool? optionalBool(Map<Object?, Object?> map, String key, String path)` | The bool at `key`, or `null` when absent; throws when not a bool. |
| `optionalMap` | `Map<Object?, Object?>? optionalMap(Map<Object?, Object?> map, String key, String path)` | The map at `key`, or `null` when absent; throws when not a map. |
| `optionalList` | `List<Object?>? optionalList(Map<Object?, Object?> map, String key, String path)` | The list at `key`, or `null` when absent; throws when not a list. |
| `stringValue` | `String? stringValue(Object? value, String path, {bool allowNull = false})` | Checks a value already in hand is a string; `null` passes only with `allowNull`. |
| `mapValue` | `Map<Object?, Object?>? mapValue(Object? value, String path, {bool allowNull = false})` | Checks a value already in hand is a map; `null` passes only with `allowNull`. |

### ScopedPath

```dart
typedef ScopedPath = ({String root, String path});
```

A root that admits a resolved path, paired with that path: `root` is the
normalised absolute root, `path` the resolved, containment-checked absolute
path under it.

### PathScope

`final class`. A union of filesystem roots a path must stay within. Every root
is normalised to `normalize(absolute(root))`; a path is in scope when, after
normalisation, it lands inside at least one root. The check is purely lexical:
it never touches the filesystem, so a symlink inside a root pointing outside
every root is admitted. `PathScopeIo` adds the symlink-resolving variant.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `PathScope` | `PathScope(Iterable<String> roots)` | Normalises the roots; throws `ArgumentError` when there are none. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `roots` | `final List<String> roots` | The normalised absolute roots, unmodifiable, in configured priority order. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resolve` | `List<ScopedPath> resolve(String relative)` | Joins `relative` onto every root and returns one `ScopedPath` per root it stays within, in root order. Empty when it escapes every root. |
| `admits` | `bool admits(String relative)` | Whether `relative` stays within at least one root. |

### PathScopeIo

`extension PathScopeIo on PathScope`, in `path_scope_io.dart`, which imports
`dart:io` so the lexical `PathScope` stays web-safe. Resolves symlinks before the
containment check, so a link escaping its root is rejected. Roots are
canonicalised too; a path that does not exist yet resolves through its nearest
existing ancestor plus the remaining segments.

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `resolveCanonical` | `List<ScopedPath> resolveCanonical(String relative)` | Like `resolve`, but compares the real (symlink-resolved) path against each canonical root; the returned `path` is the real path. |
| `admitsCanonical` | `bool admitsCanonical(String relative)` | Whether `relative` stays within at least one root once symlinks are resolved. |

### PlanStepOrdering

`final class`. The outcome of `orderPlanSteps`. For an acyclic graph `cyclic`
is empty and `order` holds every step; otherwise `order` holds the steps that
could be placed and `cyclic` the rest.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `PlanStepOrdering` | `const PlanStepOrdering({required List<String> order, required List<String> cyclic})` | Builds the outcome. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `order` | `final List<String> order` | Step ids in dependency-first order; for every edge `x depends-on y`, `y` precedes `x`. |
| `cyclic` | `final List<String> cyclic` | Step ids in a cycle or depending on one, in the adjacency's insertion order. |
| `hasCycle` | `bool get hasCycle` | Whether `cyclic` is non-empty. |

### ProcedureRerankWeights

`final class`. The relative weight of the four re-rank factors
`scoreProcedureCandidate` combines. Combined as a weighted average, so only the
ratios matter; a zero weight removes a factor.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `ProcedureRerankWeights` | `const ProcedureRerankWeights({required double embedding, required double requiresOverlap, required double successRate, required double recency})` | An explicit weighting; weights are expected to be non-negative. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `embedding` | `final double embedding` | Weight on intent-embedding similarity. |
| `requiresOverlap` | `final double requiresOverlap` | Weight on how much of the candidate's `requires` set the caller can supply. |
| `successRate` | `final double successRate` | Weight on the rolling success rate. |
| `recency` | `final double recency` | Weight on recency of the last successful run. |

#### Static Members

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `balanced` | `static const ProcedureRerankWeights balanced` | The default blend: embedding 0.40, success rate 0.25, requires overlap 0.20, recency 0.15. |

### TokenBucketPolicy

`final class`. The immutable configuration of a `TokenBucket`: a bucket holds at
most `capacity` tokens and refills `refillTokens` every `refillPeriod`. One take
costs one token.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `TokenBucketPolicy` | `TokenBucketPolicy({required int capacity, required double refillTokens, required Duration refillPeriod})` | Throws `ArgumentError` unless `capacity >= 1`, `refillTokens > 0` and `refillPeriod` is strictly positive. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `capacity` | `final int capacity` | Maximum tokens per bucket, the burst allowance; a fresh bucket starts full. |
| `refillTokens` | `final double refillTokens` | Tokens added every `refillPeriod`. |
| `refillPeriod` | `final Duration refillPeriod` | The window over which `refillTokens` are added. |
| `tokensPerMicrosecond` | `double get tokensPerMicrosecond` | The continuous refill rate, `refillTokens / refillPeriod.inMicroseconds`. |

### TokenBucketSnapshot

`final class`. An immutable snapshot of one key's bucket, the persistable form.
Because refill is computed lazily from elapsed time, a restored snapshot credits
the downtime on its next take.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `TokenBucketSnapshot` | `const TokenBucketSnapshot({required double tokens, required DateTime lastRefill})` | A snapshot of `tokens` held at `lastRefill`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `tokens` | `final double tokens` | The fractional token count at `lastRefill`. |
| `lastRefill` | `final DateTime lastRefill` | The instant `tokens` was computed at. |
| `hashCode` | `int get hashCode` | Hash of `tokens` and the `lastRefill` microseconds. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `==` | `bool operator ==(Object other)` | Equal tokens and `lastRefill` at the same moment. |
| `toString` | `String toString()` | `'TokenBucketSnapshot(tokens: …, lastRefill: …)'`. |

### TokenBucket

`final class`. A keyed continuous-refill token bucket: one bucket per non-empty
key, created full on first sight and kept for the instance's lifetime. There is
no timer; refill is computed from the elapsed clock time on each take, and a
clock that stalls or goes backwards neither drains nor credits a bucket.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `TokenBucket` | `TokenBucket({required TokenBucketPolicy policy, DateTime Function()? clock})` | A bucket set over `policy`; `clock` defaults to `systemClock`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `policy` | `final TokenBucketPolicy policy` | The policy applied to every key. |
| `clock` | `final DateTime Function() clock` | The time source. |
| `keyCount` | `int get keyCount` | Number of keys with live bucket state. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `tryTake` | `Duration? tryTake(String key)` | Refills the key's bucket, then consumes one token and returns `null`, or returns the wait until one token has refilled without charging anything. Throws `ArgumentError` for an empty key. |
| `clear` | `void clear()` | Drops all bucket state. |
| `snapshot` | `Map<String, TokenBucketSnapshot> snapshot()` | A snapshot of every live bucket, by key. |
| `snapshotOf` | `TokenBucketSnapshot? snapshotOf(String key)` | One key's snapshot, or `null` when it has no state. |
| `restore` | `void restore(Map<String, TokenBucketSnapshot> snapshot)` | Seeds bucket state; each key overwrites its bucket, tokens clamped to `[0, capacity]`. Keys must be non-empty. |

### ParsedToolCall

`final class`. One tool call recovered from model text, normalised across
dialects.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `ParsedToolCall` | `const ParsedToolCall(String name, Map<String, Object?> arguments)` | Builds the call. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `name` | `final String name` | The tool identifier as the model wrote it, e.g. `web.search`. |
| `arguments` | `final Map<String, Object?> arguments` | The decoded argument object; empty when there were none. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `toString` | `String toString()` | `'ParsedToolCall(<name>, <arguments>)'`. |

### TtlCache

`final class TtlCache<K, V>`. An absolute-TTL cache: each entry expires a fixed
`ttl` after it was written, however often it is read. Expired entries are swept
lazily on each access. With `maxEntries` set, a write that would exceed it
evicts the least-recently-used entries. Stores values only; async compute and
in-flight de-duplication belong to the caller.

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `TtlCache` | `TtlCache({required Duration ttl, int? maxEntries, DateTime Function()? clock})` | Throws `ArgumentError` unless `ttl` is strictly positive and `maxEntries`, when given, is at least 1. `clock` defaults to `systemClock`. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `ttl` | `final Duration ttl` | Entry lifetime, measured from write time. |
| `maxEntries` | `final int? maxEntries` | The live-entry ceiling, or `null` for none. |
| `clock` | `final DateTime Function() clock` | The time source. |
| `length` | `int get length` | The number of live entries, after a sweep. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `get` | `V? get(K key)` | The live value for `key` (marking it most recently used), or `null` when absent or expired. |
| `set` | `void set(K key, V value)` | Writes `value` stamped with the current time, refreshing an existing key's TTL, then evicts down to `maxEntries`. |
| `clear` | `void clear()` | Drops all entries. |

### YamlConfigErrorFactory

```dart
typedef YamlConfigErrorFactory = Object Function(String message);
```

Builds the exception a `YamlConfigReader` throws when a typed read or an
`${env:NAME}` expansion fails; each loader wraps the message in its own
exception class.

### YamlConfigReader

`final class`. Type-safe accessors over a plain config map (the output of
`loadYamlAsMap`, never a `YamlMap`), plus an environment-variable expander.
Every accessor except `optionalMap` takes a dotted `path` used verbatim in the
error message; `optionalMap` reports by `key`
(``Field `<key>` must be a map (got …).``).

#### Constructors

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `YamlConfigReader` | `const YamlConfigReader({required Map<String, String> env, required YamlConfigErrorFactory errorFactory})` | A reader for one parse. |

#### Properties

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `env` | `final Map<String, String> env` | The environment `expandEnv` resolves `${env:NAME}` against. |
| `errorFactory` | `final YamlConfigErrorFactory errorFactory` | Wraps a message in the loader's exception type. |

#### Methods

| Member | Declaration | Description |
| ------ | ----------- | ----------- |
| `requireString` | `String requireString(Map<Object?, Object?> node, String key, String path)` | The string at `key`; throws when missing or not a string. |
| `optionalString` | `String? optionalString(Map<Object?, Object?> node, String key, String path)` | The string at `key`, or `null` when absent. |
| `requireInt` | `int requireInt(Map<Object?, Object?> node, String key, String path)` | The int at `key`; throws when missing or not an int. |
| `optionalInt` | `int? optionalInt(Map<Object?, Object?> node, String key, String path)` | The int at `key`, or `null` when absent. |
| `requireDouble` | `double requireDouble(Map<Object?, Object?> node, String key, String path)` | The number at `key` as a double; throws when missing or not a number. |
| `optionalDouble` | `double? optionalDouble(Map<Object?, Object?> node, String key, String path)` | The number at `key` as a double, or `null` when absent. |
| `optionalBool` | `bool? optionalBool(Map<Object?, Object?> node, String key, String path)` | The bool at `key`, or `null` when absent. |
| `requireMap` | `Map<Object?, Object?> requireMap(Map<Object?, Object?> node, String key, String path)` | The map at `key`; throws when missing or not a map. |
| `optionalMap` | `Map<Object?, Object?>? optionalMap(Map<Object?, Object?> node, String key)` | The map at `key`, or `null` when absent. |
| `requireList` | `List<Object?> requireList(Map<Object?, Object?> node, String key, String path)` | The list at `key`; throws when missing or not a list. |
| `optionalList` | `List<Object?>? optionalList(Map<Object?, Object?> node, String key, String path)` | The list at `key`, or `null` when absent. |
| `parseUri` | `Uri parseUri(String raw, String path)` | Parses `raw` as a `Uri`; throws when it is not valid. |
| `expandEnv` | `String expandEnv(String input, String path)` | Expands `${env:NAME}` tokens through the shared `PlaceholderResolver` (environment only, synchronous). An undefined variable, a bare `${NAME}`, a non-converging expansion or a `${{ … }}` expression throws through `errorFactory`. Input without placeholders is returned unchanged. |

### YamlMapErrorFactory

```dart
typedef YamlMapErrorFactory = Object Function(String message);
```

Builds the exception `loadYamlAsMap` throws when parsing or type-checking fails.
The default there is `FormatException.new`.

## Global Functions and Constants

### requireNonEmpty

```dart
String requireNonEmpty(String value, String name)
```

Returns `value` when it is non-empty; otherwise throws
`ArgumentError.value(value, name, 'must be non-empty')`. Checks length only, not
whitespace.

### shutdownExitOk

```dart
const int shutdownExitOk = 0;
```

Exit code of a clean shutdown.

### shutdownExitError

```dart
const int shutdownExitError = 70;
```

Exit code when the teardown threw (`EX_SOFTWARE`). The process still exits.

### mapEquals

```dart
bool mapEquals<K, V>(Map<K, V> a, Map<K, V> b)
```

`true` when both maps have the same length, the same keys and `a[k] == b[k]` for
every key. Short-circuits on `identical`; values compare with `==`.

### setEquals

```dart
bool setEquals<E>(Set<E> a, Set<E> b)
```

`true` when both sets have the same length and every element of `a` is in `b`.

### listEquals

```dart
bool listEquals<E>(List<E> a, List<E> b)
```

`true` when both lists have the same length and equal elements by position
(`==`).

### deepValueEquals

```dart
bool deepValueEquals(Object? a, Object? b)
```

Deep equality for a scalar or an arbitrarily nested `List`: lists compare
element by element recursively, two `null`s are equal, everything else uses
`==`.

### deepValueHash

```dart
int deepValueHash(Object? v)
```

Hash companion to `deepValueEquals`: `null` hashes to 0, a list hashes its
elements recursively in order, anything else uses its own `hashCode`.

### startOfDay

```dart
DateTime startOfDay(DateTime t)
```

Midnight at the start of `t`'s calendar day, in `t`'s own zone (UTC or local).

### nextDayStart

```dart
DateTime nextDayStart(DateTime t)
```

The start of the day after `t`'s day, in `t`'s zone; month and year rollover
are normalised by `DateTime`.

### buildUniqueById

```dart
Map<String, T> buildUniqueById<T>(
  Iterable<T> items,
  String Function(T item) idOf, {
  String itemLabel = 'item',
  String Function(String id)? onDuplicate,
})
```

Builds an unmodifiable `id → item` map. Throws `ArgumentError` on the first
duplicate id, with the message from `onDuplicate` or
`'duplicate <itemLabel> id "<id>"'`.

### deliberationCues

```dart
const List<String> deliberationCues = <String>[
  'think about',
  'think through',
  'reason about',
  'work through',
  'reflect on',
  'mull over',
  'ponder',
  'research',
  'deliberate',
  'contemplate',
];
```

The canonical cue phrases, lower-case.

### classifyDeliberationCue

```dart
DeliberationVerdict classifyDeliberationCue(String text)
```

`DeliberationVerdict.thinking` when `text` contains any of `deliberationCues`,
matched case-insensitively on word boundaries (so `research` does not match
"researcher"); otherwise `DeliberationVerdict.normal`. Pure and total.

### formatException

```dart
String formatException(Object exception, String message, {String? context})
```

`'<runtimeType>: <message>'`, or `'<runtimeType>(<context>): <message>'` when
`context` is given (an empty context renders as `()`). Pass `this` as
`exception` so the concrete subtype name is used.

### decodeJsonObject

```dart
Map<String, Object?> decodeJsonObject(String? json, {required String context})
```

Decodes `json` into a fresh `Map<String, Object?>`. A `null` input returns an
empty constant map; a payload that is not a JSON object throws
`StateError('<context> is not a JSON object: <type>')`.

### percentileDuration

```dart
Duration percentileDuration(List<Duration> sorted, double q)
```

The nearest-rank percentile of an ascending list: rank `ceil(q · n)` (at least
1), the sample at `rank − 1`, clamped. Throws `ArgumentError` for an empty list
or `q` outside `[0, 1]`.

### nearestRankPercentile

```dart
int nearestRankPercentile(List<int> sortedAsc, double q)
```

The same nearest-rank percentile over integer samples, with the same errors.

### orderPlanSteps

```dart
PlanStepOrdering orderPlanSteps(Map<String, Iterable<String>> dependencies)
```

Topologically orders the steps of `dependencies` (step id → ids it depends on)
with Kahn's algorithm. Dependencies on ids that are not keys are ignored,
duplicate edges count once, a self-dependency is a cycle. Ready steps are
emitted in the map's insertion order. Steps in or behind a cycle are returned in
`PlanStepOrdering.cyclic`, not thrown.

### scoreProcedureCandidate

```dart
double scoreProcedureCandidate({
  required double embeddingSimilarity,
  required double requiresOverlap,
  required double successRate,
  required double recencyScore,
  ProcedureRerankWeights weights = ProcedureRerankWeights.balanced,
})
```

Clamps each factor to `[0, 1]` and returns their weight-normalised average, a
score in `[0, 1]`. A total weight of zero or less yields `0.0`.

### recencyDecay

```dart
double recencyDecay({required int? ageMillis, required int halfLifeMillis})
```

Exponential half-life decay of the age of the last successful run: `1.0` for an
age of zero or less, `0.5` at one half-life, towards `0` after. A `null` age
(never run) or a non-positive half-life yields `0.0`.

### promptSha256

```dart
String promptSha256(String body)
```

`'sha256:<lowercase-hex>'` of `body`, using `tom_basics`' `tomSha256OfText`
(UTF-8 bytes).

### sqlPlaceholders

```dart
String sqlPlaceholders(int count, {String separator = ','})
```

`count` bind placeholders joined by `separator`, e.g. `'?,?,?'`. `0` yields the
empty string; a negative count throws `ArgumentError`.

### fnv1a32

```dart
int fnv1a32(String s)
```

FNV-1a 32-bit hash over the low byte of each UTF-16 code unit. Not
cryptographic; used to disambiguate a derived identifier.

### sqlSafeIdentifier

```dart
String sqlSafeIdentifier(String input, {int maxLength = 32})
```

Lower-cases `input`, replaces every character outside `[a-z0-9_]` with `_` and
caps the result at `maxLength`. Lossy; pair it with `fnv1a32` when uniqueness
matters. A negative `maxLength` throws `ArgumentError`.

### blobFromColumnOrNull

```dart
Uint8List? blobFromColumnOrNull(Object? raw)
```

`raw` as a `Uint8List` when it is one or a `List<int>`; otherwise `null`.

### blobFromColumn

```dart
Uint8List blobFromColumn(Object? raw, {required String context})
```

Like `blobFromColumnOrNull`, but throws
`StateError('<context>: expected BLOB, got <type>')` for a non-blob.

### systemClock

```dart
const DateTime Function() systemClock = DateTime.now;
```

The production wall-clock source, the default of every injectable
`DateTime Function()` seam.

### textPreview

```dart
String textPreview(String text, {int limit = 512, String ellipsis = '…'})
```

`text` unchanged when it has at most `limit` characters; otherwise its first
`limit` characters followed by `ellipsis`. A negative `limit` throws
`ArgumentError`.

### approxCharsPerToken

```dart
const int approxCharsPerToken = 4;
```

Characters per token assumed by `estimateTokens`.

### estimateTokens

```dart
int estimateTokens(String text)
```

`ceil(text.length / approxCharsPerToken)`; an empty string is zero tokens.

### parseToolCallsFromText

```dart
List<ParsedToolCall> parseToolCallsFromText(
  String text, {
  Set<String>? knownToolNames,
})
```

Recovers every tool call in `text`. The functional family (`call:NAME{ARGS}`,
with a lenient JS-object-literal argument body, optionally inside
`<|tool_call>` sentinels) is tried first; only when it finds nothing does the
JSON family run: `<tool_call>…</tool_call>` blocks, everything after a
`[TOOL_CALLS]` marker, or bare and fenced JSON objects and arrays found anywhere
in the text. A JSON object is a call when it has a `tool` or `name` string,
with arguments from `arguments` or `parameters` (a map or a JSON string);
`{"function": {...}}` nesting is unwrapped. With `knownToolNames`, calls to
other names are dropped. Never throws; malformed input yields an empty list.

### looksLikeToolCallAttempt

```dart
bool looksLikeToolCallAttempt(String text)
```

Whether the trimmed `text` starts with `{`, `[` or a code fence, contains
`<tool_call>`, `<|tool_call>` or `[TOOL_CALLS]`, or contains a `call:NAME{`
opening.

### loadYamlAsMap

```dart
Map<String, Object?> loadYamlAsMap(
  String source, {
  YamlMapErrorFactory errorFactory = FormatException.new,
  String rootPath = 'root',
  int maxNodes = 1000000,
})
```

Parses one YAML document into plain `Map<String, Object?>` / `List<Object?>` /
scalar values. A non-string map key, a document root that is not a map, or a
materialised tree of more than `maxNodes` nodes (an alias-expansion bomb) throws
through `errorFactory`, with a message located at `rootPath`.

#### Top-level final variables

| Constant | Type | Description |
| -------- | ---- | ----------- |
| — | — | These files export no top-level `final` variables. |

/// Resuming the far end's conversation across requests.
///
/// Claude Code keeps its own conversation memory, keyed by a conversation id
/// it names on every run (`AgentSdkConversation`). Whether a request
/// continues an earlier conversation or starts a fresh one is decided per
/// request by an [AgentSdkResumeStrategy] the provider consults; a provider with
/// none starts every request fresh.
///
///   * [AgentSdkStoredResume] — the conversation id is kept in a JSON store
///     keyed by the caller's session ([LlmOptions.sessionId]); successive
///     requests of one session continue one conversation.
///   * [AgentSdkQuestResume] — the conversation id is *read* from a VS Code
///     window's quest history (`{root}/{questId}/history/{key}.session.json`),
///     so a request continues the conversation the editor holds. Read-only.
///
/// A resumed request that the far end refuses as an unknown conversation —
/// before any text arrived — is retried once, fresh, after the strategy has
/// evicted the id ([agentSdkLooksLikeResumeError]).
///
/// The store and the quest reader degrade to "no conversation" on any I/O or
/// parse error rather than throwing — reads and writes alike — so a damaged
/// file can only ever cost one fresh request, never a failed one. That matters
/// most on the write side: the provider records the id once the run has
/// completed, and a throwing store would turn a run already made and billed
/// into a failure.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_llm/tom_llm.dart' show LlmOptions;

/// Decides, per call, whether the provider resumes a stored conversation
/// or starts fresh, and records the session id a successful call produced.
///
/// All three methods key off the call's [LlmOptions] so a single provider can be
/// configured with any one strategy.
///
/// **No method may throw because the session state is damaged** — not just the
/// read. [resumeIdFor] returns `null` (no resume) for state it cannot read, and
/// [record] / [evict] return normally for state they cannot write. The provider
/// awaits all three inline, `record` on the success path immediately before the
/// terminal event, so a strategy that throws does not merely fail to persist a
/// session id: it destroys the result of the call that produced it. A degraded
/// store must cost at most one fresh call.
abstract interface class AgentSdkResumeStrategy {
  /// The conversation id to resume for this call, or `null` to start a
  /// fresh session (an unknown key, a missing quest file).
  Future<String?> resumeIdFor(LlmOptions options);

  /// Records the conversation id a *successful* call produced, so a later
  /// call of the same session can resume it. A no-op for read-only strategies
  /// ([AgentSdkQuestResume]).
  Future<void> record(LlmOptions options, String conversationId);

  /// Forgets the stored session id for this call after a session-shaped failure,
  /// so the immediate retry starts fresh. A no-op for read-only strategies.
  Future<void> evict(LlmOptions options);
}

/// A small JSON-backed `session id → conversation id` map, persisted at
/// [file].
///
/// Loaded lazily on first access and cached in memory; every mutation flushes
/// the whole map back to disk (the map is tiny — one entry per live session).
///
/// **No operation throws for a damaged store**, in either direction. A missing
/// file reads as empty, a corrupt or unreadable one degrades to empty, and a
/// flush that cannot land is dropped. The cache is authoritative for the
/// lifetime of the instance either way, so a damaged store costs fresh sessions
/// after a restart and nothing at all before one — never a failed call.
final class AgentSdkResumeStore {
  /// The on-disk JSON file backing this store.
  final File file;

  Map<String, String>? _cache;

  AgentSdkResumeStore(this.file);

  Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    Map<String, String> loaded;
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        loaded = decoded is Map
            ? decoded.map((key, value) => MapEntry('$key', '$value'))
            : <String, String>{};
      } else {
        loaded = <String, String>{};
      }
    } on FormatException {
      // Corrupt JSON: start clean rather than fail the call.
      loaded = <String, String>{};
    } on FileSystemException {
      loaded = <String, String>{};
    }
    return _cache = loaded;
  }

  /// Writes the whole cache back to [file], degrading exactly as [_load] does.
  ///
  /// A write that cannot land is dropped rather than raised. The provider
  /// awaits the two callers of this method on paths where an exception would
  /// destroy work that has already been done: [put] runs on the *success* path
  /// immediately before the terminal event, so a throw here would discard a
  /// model call that has already been made and billed, and [remove] runs from
  /// the evict-and-retry-fresh decision, outside the provider's try/catch, so a
  /// throw there would turn a classified failure into an unhandled stream
  /// error. Neither is a fault the caller can act on, and both are strictly
  /// worse than the cost of losing the write.
  ///
  /// Losing it costs less than it appears: both mutators update the in-memory
  /// cache *before* flushing, so this process keeps resuming (or keeps having
  /// evicted) the session as if the write had landed. Only a restart reads the
  /// stale file, which is the one fresh call the store's contract allows for.
  Future<void> _flush() async {
    final cache = _cache ?? <String, String>{};
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(cache));
    } on FileSystemException {
      // Unwritable path, read-only volume, revoked permission: the session id
      // is a cache, not a ledger, and is not worth a call for.
    }
  }

  /// The conversation id stored for [sessionKey], or `null`.
  Future<String?> lookup(String sessionKey) async =>
      (await _load())[sessionKey];

  /// Stores [conversationId] under [sessionKey], flushing to disk.
  Future<void> put(String sessionKey, String conversationId) async {
    (await _load())[sessionKey] = conversationId;
    await _flush();
  }

  /// Removes any id stored for [sessionKey], flushing to disk.
  Future<void> remove(String sessionKey) async {
    final cache = await _load();
    if (cache.remove(sessionKey) != null) {
      await _flush();
    }
  }
}

/// Persists the conversation id keyed by the
/// caller's session id ([LlmOptions.sessionId]).
///
/// A call with a null `sessionId` (a background / boot call that reached an
/// agent-SDK route) is treated as session-less — it always starts fresh and is
/// never recorded, so background work never pollutes a user session's Claude
/// memory.
final class AgentSdkStoredResume implements AgentSdkResumeStrategy {
  /// The store the session ids are persisted in.
  final AgentSdkResumeStore store;

  const AgentSdkStoredResume(this.store);

  @override
  Future<String?> resumeIdFor(LlmOptions options) async {
    final key = options.sessionId;
    if (key == null) return null;
    return store.lookup(key);
  }

  @override
  Future<void> record(LlmOptions options, String conversationId) async {
    final key = options.sessionId;
    if (key == null) return;
    await store.put(key, conversationId);
  }

  @override
  Future<void> evict(LlmOptions options) async {
    final key = options.sessionId;
    if (key == null) return;
    await store.remove(key);
  }
}

/// Resumes the conversation recorded in the VS Code
/// window's quest history file, read-only.
///
/// Reads `{questHistoryRoot}/{questId}/history/{sessionKey}.session.json` and
/// pulls its `sessionId` field. The `sessionKey` selects which of the quest's
/// sessions to reuse — typically `default` (the quest's default session) or
/// `chat` (the chat session). A missing / empty file degrades to a fresh
/// session, as a provider with no strategy does. The caller never writes back into the
/// quest's history: [record] is a no-op, and [evict] writes nothing either.
///
/// **A rejected id is remembered, not re-tried.** The file belongs to the VS
/// Code window and may hold an id Claude Code no longer knows. The file is
/// re-read on every call — so an id the editor writes mid-run is picked up —
/// and without a memory the same stale id would cost one failed attempt on
/// *every* call until the editor next rewrote it. So [evict] records the id
/// this strategy last answered as rejected, and [resumeIdFor] answers `null`
/// for a rejected id: a stale id costs one wasted attempt per strategy
/// instance, and a new id in the file is resumed as soon as it appears.
final class AgentSdkQuestResume implements AgentSdkResumeStrategy {
  /// Root folder holding the per-quest history subfolders.
  final String questHistoryRoot;

  /// The quest id whose history is read.
  final String questId;

  /// Which session file to read (e.g. `default`, `chat`).
  final String sessionKey;

  AgentSdkQuestResume({
    required this.questHistoryRoot,
    required this.questId,
    required this.sessionKey,
  });

  /// The id [resumeIdFor] last answered — the one a failed resume rejected.
  String? _lastAnswered;

  /// Ids a resume has rejected, for the life of this strategy.
  final Set<String> _rejected = <String>{};

  File get _sessionFile =>
      File('$questHistoryRoot/$questId/history/$sessionKey.session.json');

  @override
  Future<String?> resumeIdFor(LlmOptions options) async {
    final file = _sessionFile;
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final sessionId = decoded['sessionId'];
      if (sessionId is! String || sessionId.isEmpty) return null;
      if (_rejected.contains(sessionId)) return null;
      return _lastAnswered = sessionId;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  // Read-only: the caller never mutates the quest's history.
  @override
  Future<void> record(LlmOptions options, String conversationId) async {}

  /// Remembers the id last answered as rejected. The file is left alone.
  @override
  Future<void> evict(LlmOptions options) async {
    final rejected = _lastAnswered;
    if (rejected != null) _rejected.add(rejected);
  }
}

/// True when [message] looks like a Claude-Code rejection of a stale / unknown
/// session id, so the provider evicts the stored id and retries
/// once with a fresh session.
///
/// Deliberately conservative: it requires the word `session` *and* a failure
/// cue, so a generic error that merely mentions sessions does not trigger a
/// (wasteful) fresh retry.
bool agentSdkLooksLikeResumeError(String message) {
  final lower = message.toLowerCase();
  if (!lower.contains('session')) return false;
  const cues = <String>[
    'not found',
    'invalid',
    'no such',
    'unknown',
    'expired',
    'does not exist',
  ];
  for (final cue in cues) {
    if (lower.contains(cue)) return true;
  }
  return false;
}

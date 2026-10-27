import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:test/test.dart';

// The sidecar stores promise one thing: a damaged file costs the user a
// reset, never a crash. Their `try` covers *parse* damage, because a
// `YamlException` is a `FormatException`. It did not cover *shape* damage —
// a file that parses cleanly but whose entry is missing the one field the
// model reads with an unguarded cast. That threw a `TypeError`, which is
// neither of the two types caught, so the promise failed on the damage shape
// a hand-edit actually produces.
//
// The existing malformed-file tests could not see this: every one of them
// writes `': not a mapping :'`, a *syntax* error, which is the one shape the
// catch already handled.
//
// Two properties are asserted here, per store, from one table — a per-store
// hand-written test is how the trail store came to have no shape test at all.
//
//   * a shape-damaged entry does not propagate out of `load()`;
//   * it costs *that entry only*. The all-or-nothing catch would have
//     returned an empty list, so one bad row silently discarded the file.

/// One list store, described by what its file looks like rather than by which
/// class reads it, so the same two assertions run against all seven.
class _ListStore {
  const _ListStore({
    required this.name,
    required this.listKey,
    required this.identity,
    required this.entry,
    required this.identitiesOf,
    required this.mistyped,
    required this.mistypedField,
    required this.mistypedDefault,
    required this.mistypedValueOf,
  });

  /// The store class under test, for the group name.
  final String name;

  /// The root key its list hangs under.
  final String listKey;

  /// The field the store treats as the entry's identity.
  final String identity;

  /// A well-formed entry carrying [id], as YAML list-item lines.
  final String Function(String id) entry;

  /// Loads the file and projects each entry to its identity.
  final List<String> Function(File file) identitiesOf;

  /// An entry carrying [id] and one optional field holding the wrong type.
  final String Function(String id) mistyped;

  /// The name of that field, for the test description.
  final String mistypedField;

  /// What [mistypedField] must read back as once the entry has loaded.
  final Object? mistypedDefault;

  /// Loads the file and projects the sole entry to [mistypedField].
  final Object? Function(File file) mistypedValueOf;
}

/// An entry that is valid YAML and a mapping, but carries no identity field —
/// the shape a hand-edit produces when a line is deleted.
const _damaged = '  - description: an entry with no identity\n';

final _stores = <_ListStore>[
  _ListStore(
    name: 'PromptQueueStore',
    listKey: 'items',
    identity: 'id',
    entry: (id) => '  - id: $id\n    originalText: hello\n',
    identitiesOf: (f) => PromptQueueStore(f).load().map((e) => e.id).toList(),
    mistyped: (id) => '  - id: $id\n    originalText: 7\n',
    mistypedField: 'originalText',
    mistypedDefault: '',
    mistypedValueOf: (f) => PromptQueueStore(f).load().single.originalText,
  ),
  _ListStore(
    name: 'AgentProfileStore',
    listKey: 'profiles',
    identity: 'id',
    entry: (id) => '  - id: $id\n    name: Builder\n',
    identitiesOf: (f) => AgentProfileStore(f).load().map((e) => e.id).toList(),
    mistyped: (id) => '  - id: $id\n    name: 7\n',
    mistypedField: 'name',
    mistypedDefault: '',
    mistypedValueOf: (f) => AgentProfileStore(f).load().single.name,
  ),
  _ListStore(
    name: 'ChatVariableStore',
    listKey: 'variables',
    identity: 'name',
    entry: (id) => '  - name: $id\n    value: v\n',
    identitiesOf: (f) =>
        ChatVariableStore(f).load().map((e) => e.name).toList(),
    mistyped: (id) => '  - name: $id\n    value: 7\n',
    mistypedField: 'value',
    mistypedDefault: '',
    mistypedValueOf: (f) => ChatVariableStore(f).load().single.value,
  ),
  _ListStore(
    name: 'PromptTemplateStore',
    listKey: 'templates',
    identity: 'id',
    entry: (id) => '  - id: $id\n    name: Greeting\n',
    identitiesOf: (f) =>
        PromptTemplateStore(f).load().map((e) => e.id).toList(),
    mistyped: (id) => '  - id: $id\n    body: 7\n',
    mistypedField: 'body',
    mistypedDefault: '',
    mistypedValueOf: (f) => PromptTemplateStore(f).load().single.body,
  ),
  _ListStore(
    name: 'QueueTemplateStore',
    listKey: 'templates',
    identity: 'id',
    entry: (id) => '  - id: $id\n    name: Nightly\n',
    identitiesOf: (f) => QueueTemplateStore(f).load().map((e) => e.id).toList(),
    mistyped: (id) => '  - id: $id\n    name: 7\n',
    mistypedField: 'name',
    mistypedDefault: '',
    mistypedValueOf: (f) => QueueTemplateStore(f).load().single.name,
  ),
  _ListStore(
    name: 'TimedRequestStore',
    listKey: 'requests',
    identity: 'id',
    entry: (id) => '  - id: $id\n    enabled: true\n',
    identitiesOf: (f) => TimedRequestStore(f).load().map((e) => e.id).toList(),
    mistyped: (id) => '  - id: $id\n    enabled: yes please\n',
    mistypedField: 'enabled',
    mistypedDefault: true,
    mistypedValueOf: (f) => TimedRequestStore(f).load().single.enabled,
  ),
  _ListStore(
    name: 'PromptTrailStore',
    listKey: 'pairs',
    identity: 'id',
    entry: (id) =>
        '  - id: $id\n    request:\n'
        '      id: ${id}_req\n      text: hi\n',
    identitiesOf: (f) => PromptTrailStore(f).load().map((e) => e.id).toList(),
    mistyped: (id) =>
        '  - id: $id\n    createdAt: 7\n    request:\n'
        '      id: ${id}_req\n      text: hi\n',
    mistypedField: 'createdAt',
    mistypedDefault: '',
    mistypedValueOf: (f) => PromptTrailStore(f).load().single.createdAt,
  ),
];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sidecar_shape_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File write(String name, String content) =>
      File('${dir.path}/$name')..writeAsStringSync(content);

  for (final store in _stores) {
    group(store.name, () {
      test('skips an entry with no ${store.identity} and keeps its '
          'neighbours', () {
        final file = write(
          'damaged.yaml',
          'version: 1\n${store.listKey}:\n'
              '${store.entry('first')}$_damaged${store.entry('second')}',
        );

        // Not merely "does not throw": the surrounding entries survive. An
        // all-or-nothing catch would satisfy the first half of that and
        // still lose the user's other rows.
        expect(store.identitiesOf(file), ['first', 'second']);
      });

      test('returns an empty list when every entry lacks an identity', () {
        final file = write(
          'all_damaged.yaml',
          'version: 1\n${store.listKey}:\n$_damaged',
        );

        expect(store.identitiesOf(file), isEmpty);
      });

      test('keeps an entry whose ${store.mistypedField} holds the wrong '
          'type, at that field\'s default', () {
        final file = write(
          'mistyped.yaml',
          'version: 1\n${store.listKey}:\n${store.mistyped('only')}',
        );

        // Dropping is right for damage at the identity and wrong here: the
        // field already has a default, so honouring it costs the user nothing
        // they notice, while losing the entry costs every other field on it.
        expect(store.identitiesOf(file), ['only']);
        expect(store.mistypedValueOf(file), store.mistypedDefault);
      });
    });
  }

  // Damage below the entry root. These cost the *element*, not the entry,
  // wherever the entry is still meaningful without it — and cost the entry
  // where it is not.

  group('nested shape damage', () {
    test('a non-mapping pre-prompt is dropped, the prompt survives', () {
      final file = write(
        'queue.yaml',
        'version: 1\nitems:\n  - id: q1\n    originalText: hello\n'
            '    prePrompts:\n      - just a string\n      - text: real\n',
      );

      final loaded = PromptQueueStore(file).load();
      expect(loaded.map((e) => e.id), ['q1']);
      expect(loaded.single.prePrompts?.map((p) => p.text), ['real']);
    });

    test('a non-mapping follow-up is dropped, the prompt survives', () {
      final file = write(
        'queue.yaml',
        'version: 1\nitems:\n  - id: q1\n    originalText: hello\n'
            '    followUps:\n      - 7\n      - id: f1\n',
      );

      final loaded = PromptQueueStore(file).load();
      expect(loaded.single.followUps?.map((f) => f.id), ['f1']);
    });

    test('a non-mapping scheduled time is dropped, the request survives', () {
      final file = write(
        'timed.yaml',
        'version: 1\nrequests:\n  - id: t1\n'
            '    scheduledTimes:\n      - nope\n      - time: "09:00"\n',
      );

      final loaded = TimedRequestStore(file).load();
      expect(loaded.single.scheduledTimes?.map((s) => s.time), ['09:00']);
    });

    test('a non-string enabled tool is dropped, the profile survives', () {
      final file = write(
        'profiles.yaml',
        'version: 1\nprofiles:\n  - id: p1\n'
            '    enabledTools:\n      - Read\n      - 42\n',
      );

      expect(AgentProfileStore(file).load().single.enabledTools, ['Read']);
    });

    test('a trail pair with no request is dropped, its neighbours survive', () {
      // The one nested field an entry cannot do without: `TrailPair.request`
      // is non-nullable, so a pair missing it is not a pair. Dropping the
      // entry is right here where dropping the element was right above.
      final file = write(
        'trail.yaml',
        'version: 1\npairs:\n'
            '  - id: a\n    request:\n      id: a_req\n      text: hi\n'
            '  - id: b\n    createdAt: today\n'
            '  - id: c\n    request:\n      id: c_req\n      text: ho\n',
      );

      expect(PromptTrailStore(file).load().map((p) => p.id), ['a', 'c']);
    });

    test('a mis-typed pre-prompt text leaves the element at its default', () {
      final file = write(
        'queue.yaml',
        'version: 1\nitems:\n  - id: q1\n    originalText: hello\n'
            '    prePrompts:\n      - text: 7\n      - text: real\n',
      );

      final loaded = PromptQueueStore(file).load();
      expect(loaded.single.prePrompts?.map((p) => p.text), ['', 'real']);
    });

    test('a mis-typed scheduled time leaves the element at its default', () {
      final file = write(
        'timed.yaml',
        'version: 1\nrequests:\n  - id: t1\n'
            '    scheduledTimes:\n      - time: 7\n      - time: "09:00"\n',
      );

      final loaded = TimedRequestStore(file).load();
      expect(loaded.single.scheduledTimes?.map((s) => s.time), [
        '00:00',
        '09:00',
      ]);
    });

    test('a non-list enabledTools leaves the profile loaded with none', () {
      // The list-valued counterpart: `enabledTools: 7` is not a list at all,
      // where the test above covers a non-string *inside* one.
      final file = write(
        'profiles.yaml',
        'version: 1\nprofiles:\n  - id: p1\n    name: Builder\n'
            '    enabledTools: 7\n',
      );

      final loaded = AgentProfileStore(file).load();
      expect(loaded.single.name, 'Builder');
      expect(loaded.single.enabledTools, isNull);
    });

    test('a mis-typed toolApprovalMode leaves the profile loaded unset', () {
      final file = write(
        'profiles.yaml',
        'version: 1\nprofiles:\n  - id: p1\n    toolApprovalMode: 7\n',
      );

      expect(AgentProfileStore(file).load().single.toolApprovalMode, isNull);
    });

    test('mis-typed trail provenance leaves the pair loaded without it', () {
      final file = write(
        'trail.yaml',
        'version: 1\npairs:\n  - id: a\n    request:\n'
            '      id: a_req\n      text: hi\n'
            '    tokensIn: many\n    costUsd: free\n',
      );

      final loaded = PromptTrailStore(file).load();
      expect(loaded.single.id, 'a');
      expect(loaded.single.tokensIn, isNull);
      expect(loaded.single.costUsd, isNull);
    });

    test('a mis-typed status falls back to the enum default', () {
      final file = write(
        'queue.yaml',
        'version: 1\nitems:\n  - id: q1\n    status: 7\n',
      );

      expect(
        PromptQueueStore(file).load().single.status,
        QueuedPromptStatus.pending,
      );
    });

    test('a mis-typed answer leaves the pair loaded with no answer', () {
      // `answer` is nullable, so unreadable and absent mean the same thing.
      final file = write(
        'trail.yaml',
        'version: 1\npairs:\n  - id: a\n    request:\n'
            '      id: a_req\n      text: hi\n    answer: 7\n',
      );

      final loaded = PromptTrailStore(file).load();
      expect(loaded.single.id, 'a');
      expect(loaded.single.answer, isNull);
    });
  });

  // The two models no list store reads. Neither sits behind
  // `decodeAgentYamlEntries`, so nothing catches a `TypeError` on their
  // behalf — for these the leaf readers are not the better answer, they are
  // the only one.

  group('AgentSettingsStore', () {
    test('mis-typed settings fall back field by field, not wholesale', () {
      // The settings file holds one value, so an all-or-nothing read would
      // reset every option the user set because one of them is unreadable.
      final file = write(
        'agent_settings.yaml',
        'version: 1\nsettings:\n  bridgeHost: 7\n  portScanStart: soon\n'
            '  defaultProfileId: builder\n  maxTokens: 4096\n',
      );

      final settings = AgentSettingsStore(file).load();
      expect(settings.bridgeHost, defaultBridgeHost);
      expect(settings.portScanStart, bridgeScanMinPort);
      expect(settings.defaultProfileId, 'builder');
      expect(settings.maxTokens, 4096);
    });
  });

  group('ReminderTemplate', () {
    test('a mis-typed field reads as its default rather than throwing', () {
      final template = ReminderTemplate.fromYaml(<String, dynamic>{
        'id': 'r1',
        'name': 7,
        'prompt': 'still there?',
        'isDefault': 'yes',
      });

      expect(template.id, 'r1');
      expect(template.name, '');
      expect(template.prompt, 'still there?');
      expect(template.isDefault, isFalse);
    });
  });
}

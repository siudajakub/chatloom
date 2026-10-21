// SPDX-License-Identifier: AGPL-3.0-or-later
// Settings → Sync: unconfirmed changes and conflicts are named by what they
// are about (no identifiers), say why they wait and resolve with one tap.
// Offline: in-memory private store, fixture rooms, no journal or network.
@Timeout(Duration(seconds: 60))
library;

import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:chatloom/personal/sync_changes.dart';
import 'package:chatloom/personal/ui/sync_changes_section.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<Map<String, dynamic>?> get(String key) async => records[key];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async =>
      records[key] = value;
  @override
  Future<void> delete(String key) async => records.remove(key);
  @override
  Future<void> close() async {}
}

/// Real replica; journal readiness and publication are simulated.
class _Personal extends PersonalClient {
  _Personal(super.client, _Store store)
    : super.forTesting(openStore: () async => store);
  bool fakeReady = true;
  bool fakeWorkerOnline = true;
  @override
  Future<void> load() async {}
  @override
  bool get ready => fakeReady;
  @override
  bool get workerOnline => fakeWorkerOnline;
}

Map<String, dynamic> _record({
  int revision = 1,
  Map<String, dynamic>? server,
  Map<String, dynamic>? local,
  Map<String, dynamic>? conflict,
  Map<String, dynamic> commands = const {},
  List<String> attempted = const [],
  Map<String, dynamic>? attemptedAt,
}) => {
  'revision': revision,
  'generation': 1,
  'commands': commands,
  'attempted': attempted,
  'appliedResults': <String>[],
  'serverValue': ?server,
  'localValue': ?local,
  'conflict': ?conflict,
  'attemptedAt': ?attemptedAt,
};

Map<String, dynamic> _put(String id, String entity, Map<String, dynamic> v) =>
    PersonalOperation(
      opId: id,
      kind: 'metadata.put',
      entityId: entity,
      baseRevision: 1,
      createdAt: DateTime.now().toUtc(),
      payload: {'value': v},
    ).toJson().cast<String, dynamic>();

void main() {
  late ConversationClient client;
  late ConversationRoom room;
  late _Store store;
  String key(String entity) => 'account:${client.userID}:replica:$entity';

  setUp(() {
    client = ConversationClient();
    room = ConversationRoom(client, '!chat:beeper.local', network: 'telegram');
    store = _Store();
  });

  Future<_Personal> open({DateTime? heartbeat}) async {
    final personal = _Personal(client, store)
      ..workerReadiness = WorkerReadiness(
        receivedAt: heartbeat ?? DateTime.now(),
      );
    await personal.loadLocal();
    addTearDown(() => personal.fakeReady = false);
    return personal;
  }

  test(
    'pending changes are named, grouped and explain why they wait',
    () async {
      final long = DateTime.now()
          .subtract(const Duration(minutes: 30))
          .millisecondsSinceEpoch;
      store.records[key(transcriptionPolicyEntity)] = _record(
        local: {'auto': false},
        commands: {
          'policy-op': _put('policy-op', transcriptionPolicyEntity, {
            'auto': false,
          }),
        },
        attempted: ['policy-op'],
        attemptedAt: {'policy-op': long},
      );
      store.records[key('draft:${room.id}')] = _record(
        local: {'text': 'hello'},
        commands: {
          'draft-op': _put('draft-op', 'draft:${room.id}', {'text': 'hello'}),
        },
      );
      store.records[key('network-policy:telegram')] = _record(
        local: {'groupPlacement': 'groups'},
        commands: {
          'net-op': _put('net-op', 'network-policy:telegram', {
            'groupPlacement': 'groups',
          }),
        },
        attempted: ['net-op'],
        attemptedAt: {'net-op': DateTime.now().millisecondsSinceEpoch},
      );
      store.records[key('label:old')] = _record(
        local: {'name': 'x'},
        commands: {
          'label-op': _put('label-op', 'label:old', {'name': 'x'}),
        },
      );
      final personal = await open();
      final changes = SyncChanges.of(personal);
      final byTitle = {for (final c in changes.pending) c.title: c};
      expect(byTitle.keys, {
        'Transcription settings',
        'Draft · Fictional conversation',
        'Network defaults · Telegram',
      });
      expect(
        byTitle['Transcription settings']!.state,
        PendingChangeState.unconfirmed,
      );
      expect(byTitle['Transcription settings']!.resendable, isTrue);
      expect(
        byTitle['Draft · Fictional conversation']!.state,
        PendingChangeState.sending,
      );
      expect(
        byTitle['Network defaults · Telegram']!.state,
        PendingChangeState.waiting,
      );
      for (final change in changes.pending) {
        expect(change.title, isNot(contains('!')));
        expect(change.reason, isNot(contains('!')));
      }
      expect(
        SyncChanges.settingsSummary(personal),
        'Some changes are not confirmed · open to send them again',
      );
      personal.fakeWorkerOnline = false;
      personal.workerReadiness = WorkerReadiness(
        receivedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      final offline = {
        for (final c in SyncChanges.of(personal).pending) c.title: c.state,
      };
      expect(
        offline['Network defaults · Telegram'],
        PendingChangeState.workerOffline,
      );
      expect(
        offline['Transcription settings'],
        PendingChangeState.workerOffline,
      );
      expect(
        SyncChanges.settingsSummary(personal),
        '3 changes waiting for the background service',
      );
      personal.fakeReady = false;
      expect(
        SyncChanges.settingsSummary(personal),
        'Private sync not connected · 3 changes kept on this device',
      );
    },
  );

  test('conflicts describe both versions without identifiers', () async {
    store.records[key(transcriptionPolicyEntity)] = _record(
      revision: 4,
      server: {'auto': true, 'maxSeconds': 300},
      local: {'auto': true, 'maxSeconds': 60},
      conflict: {
        'state': 'conflict',
        'revision': 4,
        'existingValue': {'auto': true, 'maxSeconds': 300},
        'proposedValue': {'auto': true, 'maxSeconds': 60},
      },
    );
    final personal = await open();
    final conflict = SyncChanges.of(personal).conflicts.single;
    expect(conflict.title, 'Transcription settings');
    expect(conflict.local, 'Maximum length: 1 min');
    expect(conflict.other, 'Maximum length: 5 min');
    expect(
      SyncChanges.settingsSummary(personal),
      '1 setting changed on two devices · choose a version',
    );
    expect(
      describeSyncValue(
        'draft:x',
        {'text': 'line one\nline two'},
        against: {'text': 'other'},
      ),
      '“line one line two”',
    );
    expect(
      describeSyncValue(transcriptionPolicyEntity, {
        'kinds': {'video': false, 'reel': true},
      }, against: const {}),
      'Media: off for videos · automatic for Instagram reels',
    );
  });

  group('section', () {
    Future<void> mount(WidgetTester tester, _Personal personal) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: personal,
                builder: (context, _) =>
                    SyncChangesSection(personal: personal, run: (a) => a()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('one tap keeps this device or uses the other version', (
      tester,
    ) async {
      store.records[key('org:${room.id}')] = _record(
        revision: 3,
        server: {'archived': true},
        local: {'archived': false},
        conflict: {
          'state': 'conflict',
          'revision': 3,
          'existingValue': {'archived': true},
          'proposedValue': {'archived': false},
        },
      );
      store.records[key('network-policy:telegram')] = _record(
        revision: 2,
        server: {'groupPlacement': 'inbox'},
        local: {'groupPlacement': 'groups'},
        conflict: {
          'state': 'conflict',
          'revision': 2,
          'existingValue': {'groupPlacement': 'inbox'},
          'proposedValue': {'groupPlacement': 'groups'},
        },
      );
      // Created inside the fake-async zone, so storage futures complete on
      // pump (see auto_transcription_client_test).
      final personal = await open();
      await mount(tester, personal);
      expect(find.text('Changed on two devices'), findsOneWidget);
      expect(
        find.text('Chat settings · Fictional conversation'),
        findsOneWidget,
      );
      expect(
        find.text('This device: Archived: off\nOther version: Archived: on'),
        findsOneWidget,
      );
      expect(find.text('Keep this device’s version'), findsNWidgets(2));
      expect(find.textContaining('Concurrent change'), findsNothing);

      // Use the other version: adopted locally, nothing to send.
      await personal.resolveConflict('org:${room.id}', keepLocal: false);
      await tester.pumpAndSettle();
      expect(personal.conflicts.keys, ['network-policy:telegram']);
      expect(personal.values['org:${room.id}'], {'archived': true});
      expect(personal.pending, isEmpty);

      // Keep this device's version: written over the other one at its
      // revision, then shown as waiting for the background service.
      await tester.tap(find.text('Keep this device’s version'));
      await tester.pumpAndSettle();
      expect(personal.conflicts, isEmpty);
      final keep = personal.pending.values.single;
      expect(keep.baseRevision, 2);
      expect(keep.payload['value'], {'groupPlacement': 'groups'});
      expect(find.text('Waiting for confirmation'), findsOneWidget);
      expect(find.text('Network defaults · Telegram'), findsOneWidget);
    });
  });
}

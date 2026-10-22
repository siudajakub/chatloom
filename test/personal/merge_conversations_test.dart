// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline fixtures: fictional bridged rooms, no account, store or network.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart' show chatMenuItems;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/merge_picker_sheet.dart';
import 'package:chatloom/personal/ui/notion_network_adapter.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@fixture:example.invalid';
const _bot = '@bridge:example.invalid';
const _peer = '@person:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected I/O');
}

/// Beeper bridges usually leave `m.direct` empty: no native DM mapping.
class _Client extends Client {
  _Client() : super('synthetic merge', database: _NoDatabase());
  @override
  String get userID => _owner;
  final direct = <String, List<String>>{};
  @override
  Map<String, List<String>> get directChats => direct;
}

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String key = '',
  String sender = _bot,
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    senderId: sender,
    eventId: '\$fixture-$type-$key',
    originServerTs: DateTime.utc(2026),
  ),
);

Room _room(
  _Client client,
  String id, {
  String network = 'whatsapp',
  String? kind = 'dm',
  bool technical = false,
  int minute = 0,
  String bridgeSender = _bot,
  String bot = _bot,
}) {
  final room = Room(
    id: '!$id:example.invalid',
    client: client,
    membership: Membership.join,
  );
  client.rooms.add(room);
  _state(room, EventTypes.RoomName, {
    'name': technical ? 'Bridge control' : 'Fictional $id',
  });
  _state(
    room,
    'm.bridge',
    {
      'bridgebot': bot,
      'protocol': {'id': network},
      'com.beeper.room_type.v2': ?kind,
    },
    key: 'fixture',
    sender: bridgeSender == _bot ? bot : bridgeSender,
  );
  final members = [_owner, bot, if (!technical) _peer];
  for (final member in members) {
    _state(room, EventTypes.RoomMember, {'membership': 'join'}, key: member);
  }
  room.summary.mJoinedMemberCount = members.length;
  room.summary.mInvitedMemberCount = 0;
  room.lastEvent = Event(
    room: room,
    type: EventTypes.Message,
    eventId: '\$last-$id',
    senderId: _peer,
    originServerTs: DateTime.utc(2026, 10, 19, 12, minute),
    content: {'msgtype': MessageTypes.Text, 'body': 'Fictional'},
  );
  return room;
}

/// Presentation adapter: values change at once, every change stays pending
/// until [ack] (the worker's acknowledgement), like the replica's metadata
/// slot. Replica coalescing itself has separate core tests.
class _Private extends PersonalClient {
  _Private(super.client)
    : super.forTesting(
        openStore: () async => throw StateError('No fixture files'),
      );
  bool available = true;
  @override
  bool get ready => available;
  @override
  Future<void> load() async {}
  var _ops = 0;
  final writes = <String>[];

  void _stage(String kind, String key, Map<String, dynamic> payload) {
    pending.removeWhere((_, op) => op.entityId == key);
    final id = 'synthetic:${_ops++}';
    pending[id] = PersonalOperation(
      opId: id,
      kind: kind,
      entityId: key,
      payload: payload,
      createdAt: DateTime.utc(2026),
    );
  }

  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    writes.add('put $key');
    _stage('metadata.put', key, {'value': value});
    values[key] = value;
    notifyListeners();
  }

  @override
  Future<void> delete(String key) async {
    if (pending.values.any((op) => op.entityId == key)) {
      throw StateError('Metadata already awaiting acknowledgement');
    }
    writes.add('delete $key');
    _stage('metadata.delete', key, {});
    notifyListeners();
  }

  void ack(String key) {
    final ops = pending.values.where((op) => op.entityId == key).toList();
    for (final op in ops) {
      pending.remove(op.opId);
      if (op.kind == 'metadata.delete') values.remove(key);
    }
    notifyListeners();
  }
}

class _Matrix extends MatrixState {
  Client active;
  _Matrix(this.active);
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [active], store: AppSettings.store);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late _Client client;
  late _Private personal;
  late Room whatsapp, telegram, signal, group, technical;
  setUp(() {
    client = _Client();
    whatsapp = _room(client, 'wa', minute: 3);
    telegram = _room(client, 'tg', network: 'telegram', minute: 2);
    signal = _room(client, 'sig', network: 'signal', minute: 1);
    group = _room(client, 'grp', network: 'telegram', kind: 'group');
    technical = _room(client, 'ctl', technical: true);
    personal = _Private(client);
  });
  tearDown(() {
    personal.dispose();
    PersonalClient.unmergeAcknowledgementWait = const Duration(seconds: 20);
  });

  test('a saved merge of bridged DMs without m.direct is one inbox row', () {
    // Regression: merge validity required native m.direct, which Beeper
    // bridges do not write, so every saved merge silently did nothing.
    expect(client.directChats, isEmpty);
    final saved = PersonGroup(
      id: 'person-a',
      name: 'Fictional person',
      members: [personal.ref(whatsapp), personal.ref(telegram)],
      defaultRoomId: whatsapp.id,
    );
    personal.values['person:person-a'] = saved.toJson().cast<String, dynamic>();
    final projection = InboxProjection(personal);
    final rows = projection.rooms(client.rooms);
    expect(rows.where((r) => r == whatsapp || r == telegram), [whatsapp]);
    expect(projection.groupFor(telegram)?.id, 'person-a');
    expect(projection.groupById('person-a'), isNotNull);
    expect(projection.displayName(whatsapp), 'Fictional person');
    expect(notionRoomNetworks(projection, whatsapp), {'whatsapp', 'telegram'});
  });

  test('an explicitly declared network group still never merges', () {
    personal.values['person:bad'] = PersonGroup(
      id: 'bad',
      name: 'Fictional person',
      members: [personal.ref(whatsapp), personal.ref(group)],
      defaultRoomId: whatsapp.id,
    ).toJson().cast<String, dynamic>();
    final projection = InboxProjection(personal);
    expect(projection.groupFor(group), isNull);
    expect(projection.groupFor(whatsapp), isNull);
    expect(InboxProjection.mergeable(group), isFalse);
    expect(InboxProjection.mergeable(whatsapp), isTrue);
    expect(personal.values, contains('person:bad'));
  });

  test('forged bridge state from a non-bot member never grants a merge', () {
    final forged = _room(client, 'forged', bridgeSender: _peer);
    expect(forged.isDirectChatForDisplay, isTrue); // presentation only
    expect(InboxProjection.mergeable(forged), isFalse);
    personal.values['person:forged'] = PersonGroup(
      id: 'forged',
      name: 'Fictional person',
      members: [personal.ref(whatsapp), personal.ref(forged)],
      defaultRoomId: whatsapp.id,
    ).toJson().cast<String, dynamic>();
    expect(InboxProjection(personal).groupFor(forged), isNull);
    expect(
      mergeCandidates(personal, anchor: whatsapp).map((c) => c.entityId),
      isNot(contains(forged.id)),
    );
    expect(
      () => planMerge(personal, [whatsapp, forged], anchor: whatsapp),
      throwsArgumentError,
    );
    // A later group declaration by anyone also rules the bot's DM out.
    _state(
      whatsapp,
      'com.beeper.bridge',
      {
        'bridgebot': _bot,
        'protocol': {'id': 'whatsapp'},
        'com.beeper.room_type.v2': 'group',
      },
      key: 'other',
      sender: _peer,
    );
    expect(InboxProjection.mergeable(whatsapp), isFalse);
  });

  test('a 2-member bridged group without a room type never merges', () {
    // Its bot declares the DMs (`dm`) elsewhere, as every bridgev2 bridge
    // does; it leaves groups and channels undeclared.
    final pair = _room(client, 'pair', network: 'telegram', kind: null);
    expect(pair.isDirectChatForDisplay, isFalse);
    expect(InboxProjection.mergeable(pair), isFalse);
    expect(
      () => planMerge(personal, [whatsapp, pair], anchor: whatsapp),
      throwsArgumentError,
    );
    // A stale native m.direct entry does not turn it into a DM either.
    client.direct[_peer] = [pair.id];
    expect(pair.isDirectChatForDisplay, isFalse);
    expect(InboxProjection.mergeable(pair), isFalse);
  });

  test('a bridge that never declares kinds keeps the legacy rule', () {
    const legacyBot = '@legacy-bridge:example.invalid';
    final pair = _room(
      client,
      'legacy',
      network: 'telegram',
      kind: null,
      bot: legacyBot,
    );
    expect(pair.isDirectChatForDisplay, isTrue); // complete member list
    expect(InboxProjection.mergeable(pair), isFalse);
    // A native m.direct mapping keeps such a chat mergeable.
    client.direct[_peer] = [pair.id];
    expect(InboxProjection.mergeable(pair), isTrue);
  });

  test('an unacknowledged merge cannot be unmerged silently', () async {
    PersonalClient.unmergeAcknowledgementWait = const Duration(
      milliseconds: 50,
    );
    final plan = planMerge(personal, [whatsapp, telegram], anchor: whatsapp);
    await applyMerge(personal, plan);
    final removal = personal.removeGroup(plan.group.id);
    expect(InboxProjection(personal).groupFor(whatsapp), isNull);
    await expectLater(removal, throwsStateError);
    // Shown again, nothing staged: the user sees it is still merged.
    expect(InboxProjection(personal).groupFor(whatsapp)?.id, plan.group.id);
    expect(personal.writes, isNot(contains('delete person:${plan.group.id}')));
  });

  test('picker candidates: DMs and persons only, local search', () {
    personal.values['nickname:${signal.id}'] = {'name': 'Private nickname'};
    final candidates = mergeCandidates(personal, anchor: whatsapp);
    final ids = candidates.map((c) => c.entityId).toList();
    expect(ids, [telegram.id, signal.id]); // newest first, anchor excluded
    expect(ids, isNot(contains(group.id)));
    expect(ids, isNot(contains(technical.id)));
    String only(String query) =>
        candidates.where((c) => c.matches(query)).single.entityId;
    expect(only('TELEGRAM'), telegram.id);
    expect(only('private nick'), signal.id);
    expect(candidates.where((c) => c.matches('fictional sig')).length, 1);
    expect(candidates.where((c) => c.matches('nobody')), isEmpty);
  });

  test(
    'merge shows one row at once; unmerge right after it restores',
    () async {
      final plan = planMerge(personal, [whatsapp, telegram], anchor: whatsapp);
      expect(plan.createsGroup, isTrue);
      await applyMerge(personal, plan);
      var projection = InboxProjection(personal);
      final rows = projection.rooms(client.rooms);
      expect(rows, contains(whatsapp));
      expect(rows, isNot(contains(telegram)));
      final merged = projection.groupFor(whatsapp)!;
      expect(merged.members.map((m) => m.roomId), [whatsapp.id, telegram.id]);
      expect(merged.name, 'Fictional wa');
      // Opening the person resolves both sources (route lookup).
      expect(projection.groupById(merged.id)?.members, hasLength(2));

      // The merge still awaits its acknowledgement: unmerge must not fail.
      final removal = personal.removeGroup(merged.id);
      projection = InboxProjection(personal);
      expect(projection.rooms(client.rooms), containsAll([whatsapp, telegram]));
      expect(personal.writes, isNot(contains('delete person:${merged.id}')));
      personal.ack('person:${merged.id}');
      await removal;
      expect(personal.writes, contains('delete person:${merged.id}'));
      expect(personal.groups, isEmpty); // hidden while the delete is pending
      personal.ack('person:${merged.id}');
      expect(personal.values, isNot(contains('person:${merged.id}')));
      expect(
        InboxProjection(personal).rooms(client.rooms),
        containsAll([whatsapp, telegram]),
      );
    },
  );

  test('undo before acknowledgement cancels nothing it cannot', () async {
    final plan = planMerge(personal, [whatsapp, telegram], anchor: whatsapp);
    await applyMerge(personal, plan);
    final undo = undoMerge(personal, plan);
    expect(InboxProjection(personal).groupFor(whatsapp), isNull);
    // Merging again before the delete is staged cancels the removal.
    await personal.putGroup(plan.group);
    await undo;
    expect(InboxProjection(personal).groupFor(whatsapp)?.id, plan.group.id);
    expect(personal.writes, isNot(contains('delete person:${plan.group.id}')));
  });

  test(
    'adding a chat to a merged person keeps its id; persons unite',
    () async {
      final first = planMerge(personal, [whatsapp, telegram], anchor: whatsapp);
      await applyMerge(personal, first);
      personal.ack('person:${first.group.id}');
      final candidates = mergeCandidates(personal, anchor: signal);
      final person = candidates.singleWhere((c) => c.group != null);
      expect(person.entityId, 'person:${first.group.id}');
      expect(person.networks, {'whatsapp', 'telegram'});
      final extend = planMerge(personal, [
        signal,
        ...person.sources,
      ], anchor: signal);
      expect(extend.createsGroup, isFalse);
      expect(extend.group.id, first.group.id);
      expect(extend.group.members, hasLength(3));
      expect(extend.absorbed, isEmpty);
      await applyMerge(personal, extend);
      expect(
        InboxProjection(personal)
            .rooms(client.rooms)
            .where((r) => [whatsapp, telegram, signal].contains(r)),
        hasLength(1),
      );
      await undoMerge(personal, extend);
      expect(InboxProjection(personal).groupFor(signal), isNull);
      expect(InboxProjection(personal).groupFor(telegram)?.id, first.group.id);
    },
  );

  test('two merged persons merge into one; the other is unmerged', () async {
    final extra = _room(client, 'ig', network: 'instagram');
    final a = planMerge(personal, [whatsapp, telegram], anchor: whatsapp);
    await applyMerge(personal, a);
    personal.ack('person:${a.group.id}');
    final b = planMerge(personal, [signal, extra], anchor: signal);
    await applyMerge(personal, b);
    personal.ack('person:${b.group.id}');
    final both = planMerge(personal, [whatsapp, signal], anchor: whatsapp);
    expect(both.group.id, a.group.id);
    expect(both.absorbed.single.id, b.group.id);
    expect(both.group.members, hasLength(4));
    await applyMerge(personal, both);
    await _flush();
    expect(personal.groups.map((g) => g.id), [a.group.id]);
    expect(InboxProjection(personal).groupFor(extra)?.id, a.group.id);
  });

  test('a network group or another account cannot be planned', () {
    expect(
      () => planMerge(personal, [whatsapp, group], anchor: whatsapp),
      throwsArgumentError,
    );
    final other = _Client();
    final foreign = _room(other, 'foreign');
    expect(
      () => planMerge(personal, [whatsapp, foreign], anchor: whatsapp),
      throwsArgumentError,
    );
    expect(() => planMerge(personal, [whatsapp]), throwsArgumentError);
  });

  test('long-press menu: read state, pin, mute, archive, merge, ignore', () {
    List<String> labels(Room room) => [
      for (final item in chatMenuItems(
        personal,
        room,
        pinLabel: 'Pin',
        unpinLabel: 'Unpin',
      ))
        item.label,
    ];
    expect(labels(whatsapp), [
      'Mark as unread',
      'Pin',
      'Mute…',
      'Archive',
      'Merge…',
      'Ignore chat',
    ]);
    personal.values['person:p'] = PersonGroup(
      id: 'p',
      name: 'Fictional person',
      members: [personal.ref(whatsapp), personal.ref(telegram)],
      defaultRoomId: whatsapp.id,
    ).toJson().cast<String, dynamic>();
    expect(labels(telegram), [
      'Mark as unread',
      'Pin',
      'Mute…',
      'Archive',
      'Unmerge',
      'Ignore chat',
    ]);
    final groupMenu = chatMenuItems(
      personal,
      group,
      pinLabel: 'Pin',
      unpinLabel: 'Unpin',
    );
    expect(
      groupMenu.singleWhere((i) => i.action == ChatMenuAction.merge).enabled,
      isFalse,
    );
    personal.available = false;
    expect(
      chatMenuItems(
        personal,
        signal,
        pinLabel: 'Pin',
        unpinLabel: 'Unpin',
      ).where((i) => i.enabled).map((i) => i.label),
      // Read state is room account data / a receipt, and the Mute menu
      // still opens the notification settings without private sync.
      ['Mark as unread', 'Mute…'],
    );
    personal.available = true;
    // A muted, archived chat offers the way back; the mute ends by itself.
    personal.values['org:${signal.id}'] = {
      'muted': true,
      'mutedUntil': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      'archived': true,
    };
    expect(labels(signal), containsAll(['Unmute', 'Unarchive']));
    personal.values['org:${signal.id}'] = {
      'muted': true,
      'mutedUntil': DateTime.now()
          .subtract(const Duration(minutes: 1))
          .toUtc()
          .toIso8601String(),
    };
    expect(labels(signal), containsAll(['Mute…', 'Archive']));
    expect(
      muteMenuItems(
        canMute: false,
      ).where((i) => i.enabled).map((i) => i.action),
      [MuteChoice.settings],
    );
    expect(muteMenuItems(canMute: true).map((i) => i.label), [
      'For 1 hour',
      'For 8 hours',
      'For 1 week',
      'Until I unmute',
      'Notification settings…',
    ]);
  });

  test('a timed mute limits notifications until it ends', () {
    PersonalNotificationMode mode() =>
        InboxProjection(personal).notificationModeFor(whatsapp);
    String iso(Duration offset) =>
        DateTime.now().add(offset).toUtc().toIso8601String();
    expect(mode(), PersonalNotificationMode.all);
    personal.values['org:${whatsapp.id}'] = {
      'muted': true,
      'mutedUntil': iso(const Duration(hours: 1)),
      'notificationMode': 'all',
    };
    expect(mode(), PersonalNotificationMode.mentionsOnly);
    personal.values['org:${whatsapp.id}'] = {
      'muted': true,
      'mutedUntil': iso(const Duration(minutes: -1)),
    };
    expect(mode(), PersonalNotificationMode.all);
    // Muting never loosens a fully muted network default.
    personal.values['network-policy:whatsapp'] = {'notifications': 'muted'};
    personal.values['org:${whatsapp.id}'] = {'muted': true};
    expect(mode(), PersonalNotificationMode.muted);
    personal.values.remove('network-policy:whatsapp');
    personal.values.remove('org:${whatsapp.id}');
  });

  testWidgets('picker: search, select, confirm', (tester) async {
    final matrix = _Matrix(client);
    List<MergeCandidate>? result;
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: matrix,
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => result = await showMergePicker(
                    context,
                    personal: personal,
                    anchor: whatsapp,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Fictional tg'), findsOneWidget);
    expect(find.text('Fictional sig'), findsOneWidget);
    expect(find.text('Fictional grp'), findsNothing);
    final confirm = find.byKey(const ValueKey('merge-confirm'));
    expect(
      tester
          .widget<ButtonStyleButton>(
            find.descendant(
              of: confirm,
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'telegram');
    await tester.pumpAndSettle();
    expect(find.text('Fictional sig'), findsNothing);
    await tester.tap(find.text('Fictional tg'));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result?.map((c) => c.entityId), [telegram.id]);
  });

  testWidgets('menu panel renders its items and returns the choice', (
    tester,
  ) async {
    ChatMenuAction? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => chosen = await showChatActionsMenu(
                context,
                anchor: const Rect.fromLTWH(0, 100, 400, 64),
                title: 'Fictional chat',
                items: chatMenuItems(
                  personal,
                  whatsapp,
                  pinLabel: 'Pin',
                  unpinLabel: 'Unpin',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (final label in [
      'Mark as unread',
      'Pin',
      'Mute…',
      'Archive',
      'Merge…',
      'Ignore chat',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    for (final gone in ['Leave', 'More', 'Add tag', 'Notifications']) {
      expect(find.text(gone), findsNothing);
    }
    await tester.tap(find.text('Merge…'));
    await tester.pumpAndSettle();
    expect(chosen, ChatMenuAction.merge);
  });
}

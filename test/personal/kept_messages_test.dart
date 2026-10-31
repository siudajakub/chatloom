// SPDX-License-Identifier: AGPL-3.0-or-later
// "Keep deleted messages": which deletions are kept, the bounded device
// store, clearing, sign-out, privacy, the SDK hook and the deletion
// notification text. Fictional offline fixtures; no account or network.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/pages/settings_chat/settings_chat.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/kept_message_notification.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/settings_switch_list_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@owner:example.invalid';
const _anna = '@anna:example.invalid';
const _bot = '@whatsappbot:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('kept fixture', database: _NoDatabase());
  @override
  String get userID => _owner;
}

class _MemoryStorage implements KeptMessagesStorage {
  final records = <String, Map<String, dynamic>>{};
  int writes = 0;
  final deleted = <String>[];
  @override
  Future<Map<String, Map<String, dynamic>>> readAll() async => {...records};
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    writes++;
    records[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    records.remove(key);
  }
}

class _SigningOut extends PersonalClient {
  _SigningOut(super.client)
    : super.forTesting(openStore: () => throw StateError('No fixture store'));
  final purged = <String>[];
  @override
  Future<void> purgeLocalRecordsOnSignOut(String prefix) async =>
      purged.add(prefix);
}

void main() {
  late _Client client;
  late Room room;
  late _MemoryStorage storage;
  late KeptMessages kept;
  var options = const KeepDeletedOptions(enabled: true);
  var now = DateTime.utc(2026, 10, 31, 12);
  var sequence = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  setUp(() {
    client = _Client();
    room = Room(id: '!kept:example.invalid', client: client)
      ..membership = Membership.join;
    client.rooms.add(room);
    room.setState(
      Event(
        room: room,
        type: 'm.bridge',
        stateKey: 'fixture',
        content: {
          'bridgebot': _bot,
          'protocol': {'id': 'whatsapp'},
        },
        eventId: r'$bridge',
        senderId: _bot,
        originServerTs: DateTime.utc(2026),
      ),
    );
    storage = _MemoryStorage();
    options = const KeepDeletedOptions(enabled: true);
    now = DateTime.utc(2026, 10, 31, 12);
    kept = KeptMessages(
      storageFor: (_) => storage,
      optionsFor: () => options,
      now: () => now,
    );
  });

  tearDown(() => MessageDeletions.debugReset(client));

  Event message({
    String sender = _anna,
    String body = 'a fictional secret',
    Map<String, Object?> extra = const {},
    String type = EventTypes.Message,
  }) => Event(
    room: room,
    eventId: '\$m${sequence++}',
    senderId: sender,
    type: type,
    originServerTs: DateTime.utc(2026, 10, 31, 11),
    content: {'msgtype': 'm.text', 'body': body, ...extra},
  );

  RedactionCapture capture(
    Event original, {
    String redactor = _anna,
    Map<String, Object?> content = const {},
    Event? edit,
    DateTime? at,
  }) => RedactionCapture(
    room: room,
    original: original,
    latestEdit: edit,
    redaction: Event(
      room: room,
      eventId: '\$r${sequence++}',
      senderId: redactor,
      type: EventTypes.Redaction,
      originServerTs: at ?? DateTime.utc(2026, 10, 31, 11, 30),
      content: {'redacts': original.eventId, ...content},
      redacts: original.eventId,
    ),
  );

  Event redacted(Event original, RedactionCapture by) =>
      original..setRedactionEvent(by.redaction);

  group('what is kept', () {
    test('off by default: nothing is kept, stored or announced', () async {
      expect(AppSettings.keepDeletedMessages.value, isFalse);
      expect(KeepDeletedOptions.fromSettings().enabled, isFalse);
      options = KeepDeletedOptions.off;
      var announced = 0;
      kept.attach(client, onKept: (_, _) => announced++);
      expect(client.onBeforeRedaction, isNull);
      final original = message();
      await kept.capture(capture(original));
      expect(storage.writes, 0);
      expect(announced, 0);
      expect(kept.lookUp(redacted(original, capture(original))), isNull);
    });

    test('another person\'s deletion: kept once, announced once', () async {
      var announced = 0;
      kept.attach(client, onKept: (_, k) => announced++);
      expect(client.onBeforeRedaction, isNotNull);
      final original = message(body: 'call me later');
      final by = capture(original, at: DateTime.utc(2026, 10, 31, 11, 45));
      await kept.capture(by);
      await kept.capture(by);
      expect(storage.writes, 1);
      expect(announced, 1);
      final copy = kept.lookUp(redacted(original, by))!;
      expect(copy.content['body'], 'call me later');
      expect(copy.deletedAt, DateTime.utc(2026, 10, 31, 11, 45));
      expect(copy.deletedBy, _anna);
      expect(copy.kind, DeletedKind.other);
      expect(personalPreviewLabel(original), isNot(contains('call me')));
    });

    test('own deletions only with their own switch, never announced', () async {
      var announced = 0;
      kept.attach(client, onKept: (_, _) => announced++);
      final own = message(sender: _owner);
      await kept.capture(capture(own, redactor: _owner));
      expect(storage.writes, 0);
      options = const KeepDeletedOptions(enabled: true, own: true);
      await kept.capture(capture(own, redactor: _owner));
      expect(storage.writes, 1);
      expect(announced, 0);
      options = const KeepDeletedOptions(enabled: true, byOthers: false);
      await kept.capture(capture(message()));
      expect(storage.writes, 1);
    });

    test('view-once and disappearing only with the explicit opt-in', () async {
      final timed = capture(
        message(),
        redactor: _bot,
        content: {'reason': 'Message disappeared'},
      );
      final viewOnce = capture(
        message(extra: {'com.beeper.view_limited': {'count': 1}}),
      );
      final disappearing = capture(
        message(
          extra: {
            'com.beeper.disappearing_timer': {
              'type': 'after_read',
              'timer': 60000,
            },
          },
        ),
      );
      for (final c in [timed, viewOnce, disappearing]) {
        expect(kept.keepable(c, options), isNull);
      }
      options = const KeepDeletedOptions(enabled: true, disappearing: true);
      for (final c in [timed, viewOnce, disappearing]) {
        expect(kept.keepable(c, options)?.kind, DeletedKind.disappeared);
      }
    });

    test('reactions, edits, tidy-ups and undecryptable messages never', () {
      final reaction = message(type: EventTypes.Reaction);
      final edit = message(
        extra: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.edit,
            'event_id': r'$x',
          },
        },
      );
      final undelivered = message(sender: _owner);
      MessageDeletions.markQuietTarget(room, undelivered.eventId);
      final locked = Event(
        room: room,
        eventId: r'$locked',
        senderId: _anna,
        type: EventTypes.Encrypted,
        originServerTs: DateTime.utc(2026),
        content: {'algorithm': 'm.megolm.v1.aes-sha2', 'ciphertext': 'x'},
      );
      const all = KeepDeletedOptions(
        enabled: true,
        own: true,
        disappearing: true,
      );
      for (final original in [reaction, edit, undelivered, locked]) {
        expect(kept.keepable(capture(original), all), isNull);
      }
      final quiet = capture(message(sender: _owner), redactor: _owner);
      MessageDeletions.markQuiet(room, quiet.redaction.eventId);
      expect(kept.keepable(quiet, all), isNull);
    });

    test('the newest edit is what was last seen', () {
      final original = message(body: 'first');
      final edit = Event(
        room: room,
        eventId: r'$edit',
        senderId: _anna,
        type: EventTypes.Message,
        originServerTs: DateTime.utc(2026, 10, 31, 11, 10),
        content: {
          'msgtype': 'm.text',
          'body': '* second',
          'm.new_content': {'msgtype': 'm.text', 'body': 'second'},
          'm.relates_to': {
            'rel_type': RelationshipTypes.edit,
            'event_id': original.eventId,
          },
        },
      );
      final copy = kept.keepable(capture(original, edit: edit), options)!;
      expect(copy.content['body'], 'second');
      expect(copy.content.containsKey('m.relates_to'), isFalse);
      expect(copy.edited, isTrue);
    });
  });

  group('device store', () {
    test('bounded by age and count when loaded', () async {
      kept = KeptMessages(
        storageFor: (_) => storage,
        optionsFor: () => options,
        capacity: 2,
        now: () => now,
      );
      KeptMessage entry(int i, DateTime deletedAt) => KeptMessage(
        roomId: room.id,
        eventId: '\$old$i',
        senderId: _anna,
        type: EventTypes.Message,
        content: {'msgtype': 'm.text', 'body': 'old $i'},
        sentAt: deletedAt,
        deletedAt: deletedAt,
        deletedBy: _anna,
        kind: DeletedKind.other,
      );
      storage.records
        ..['${room.id}|\$old0'] = entry(0, now.subtract(const Duration(days: 181))).toJson()
        ..['${room.id}|\$old1'] = entry(1, now.subtract(const Duration(days: 3))).toJson()
        ..['${room.id}|\$old2'] = entry(2, now.subtract(const Duration(days: 2))).toJson()
        ..['${room.id}|\$old3'] = entry(3, now.subtract(const Duration(days: 1))).toJson()
        ..['${room.id}|broken'] = {'v': 99};
      kept.load(client);
      await kept.debugReady(client);
      expect(kept.countFor(client), 2);
      expect(storage.records.keys, {
        '${room.id}|\$old2',
        '${room.id}|\$old3',
      });
      // A new deletion pushes the oldest out.
      await kept.capture(capture(message()));
      expect(kept.countFor(client), 2);
      expect(storage.records.containsKey('${room.id}|\$old2'), isFalse);
    });

    test('a store that was not open yet is read on the next load', () async {
      var failing = true;
      final flaky = _FlakyStorage(storage, () => failing);
      kept = KeptMessages(storageFor: (_) => flaky, optionsFor: () => options);
      storage.records['${room.id}|\$a'] = KeptMessage(
        roomId: room.id,
        eventId: r'$a',
        senderId: _anna,
        type: EventTypes.Message,
        content: const {'body': 'a'},
        sentAt: now,
        deletedAt: now,
        deletedBy: _anna,
        kind: DeletedKind.other,
      ).toJson();
      kept.load(client);
      await kept.debugReady(client);
      expect(kept.countFor(client), 0);
      failing = false;
      kept.load(client);
      await kept.debugReady(client);
      expect(kept.countFor(client), 1);
    });

    test('"Clear kept messages" deletes everything of the account', () async {
      kept.attach(client);
      await kept.capture(capture(message()));
      await kept.capture(capture(message()));
      expect(kept.countFor(client), 2);
      await kept.clear(client);
      expect(kept.countFor(client), 0);
      expect(storage.records, isEmpty);
    });

    test('sign-out forgets them and purges the device store', () async {
      kept.attach(client);
      await kept.capture(capture(message()));
      final personal = _SigningOut(client);
      await kept.forget(client, personal);
      expect(personal.purged, [PersonalKeptMessagesStorage.prefix]);
      expect(kept.countFor(client), 0);
      expect(client.onBeforeRedaction, isNull);
    });

    test('the hook follows the setting', () {
      options = KeepDeletedOptions.off;
      kept.attach(client);
      expect(client.onBeforeRedaction, isNull);
      options = const KeepDeletedOptions(enabled: true);
      kept.refreshHooks();
      expect(client.onBeforeRedaction, isNotNull);
      options = KeepDeletedOptions.off;
      kept.refreshHooks();
      expect(client.onBeforeRedaction, isNull);
    });

    test('turning keeping off hides what was kept', () async {
      kept.attach(client);
      final original = message();
      final by = capture(original);
      await kept.capture(by);
      redacted(original, by);
      expect(kept.lookUp(original), isNotNull);
      options = KeepDeletedOptions.off;
      expect(kept.lookUp(original), isNull);
    });
  });

  group('privacy', () {
    test('no content in toString', () {
      final original = message(body: 'top secret words');
      final by = capture(original);
      final copy = kept.keepable(by, options)!;
      expect(copy.toString(), isNot(contains('secret')));
      expect(by.toString(), isNot(contains('secret')));
      expect('$copy $by', isNot(contains(_anna)));
    });

    test('deletion notification text follows the notification privacy', () {
      final l10n = englishL10n;
      final locked = deletionNotificationText(
        previews: true,
        locked: true,
        chatName: 'Family',
        deleterName: 'Anna',
        preview: 'secret',
        group: true,
        l10n: l10n,
      );
      expect('${locked.title} ${locked.body}', isNot(contains('Anna')));
      expect(locked.body, isNot(contains('secret')));
      final generic = deletionNotificationText(
        previews: false,
        locked: false,
        chatName: 'Family',
        deleterName: 'Anna',
        preview: 'secret',
        group: true,
        l10n: l10n,
      );
      expect(generic.body, 'A message was deleted');
      expect(generic.title, isNot(contains('Family')));
      final direct = deletionNotificationText(
        previews: true,
        locked: false,
        chatName: 'Anna',
        deleterName: 'Anna',
        preview: 'see you',
        group: false,
        l10n: l10n,
      );
      expect(direct.title, 'Anna deleted a message');
      expect(direct.body, '“see you”');
      final groupText = deletionNotificationText(
        previews: true,
        locked: false,
        chatName: 'Family',
        deleterName: 'Anna',
        preview: 'see you',
        group: true,
        l10n: l10n,
      );
      expect(groupText.title, 'Family');
      expect(groupText.body, 'Anna deleted a message: “see you”');
      expect(
        deletionNotificationId('c', room.id, r'$a'),
        isNot(deletionNotificationId('c', room.id, r'$b')),
      );
    });
  });

  group('settings', () {
    setUp(() async {
      for (final setting in [
        AppSettings.keepDeletedMessages,
        AppSettings.keepDeletedByOthers,
        AppSettings.keepDeletedOwn,
        AppSettings.keepDeletedDisappearing,
      ]) {
        await AppSettings.store.remove(setting.key);
      }
    });

    testWidgets('a master switch, then which deletions are kept', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const SettingsChat(),
        ),
      );
      await tester.pumpAndSettle();
      expect(AppSettings.keepDeletedByOthers.value, isTrue);
      expect(AppSettings.keepDeletedOwn.value, isFalse);
      expect(AppSettings.keepDeletedDisappearing.value, isFalse);
      final master = find.byKey(const Key('settings_keep_deleted'));
      await tester.ensureVisible(master);
      expect(find.text('Keep deleted messages'), findsOneWidget);
      expect(find.textContaining('reached this device'), findsOneWidget);
      expect(find.text('Nothing is kept on this device'), findsOneWidget);
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(AppSettings.keepDeletedMessages.value, isTrue);
      for (final (key, setting) in [
        ('settings_keep_deleted_own', AppSettings.keepDeletedOwn),
        (
          'settings_keep_deleted_disappearing',
          AppSettings.keepDeletedDisappearing,
        ),
      ]) {
        final row = find.byKey(Key(key));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(setting.value, isTrue);
      }
      final others = find.byWidgetPredicate(
        (w) =>
            w is SettingsSwitchListTile &&
            w.setting == AppSettings.keepDeletedByOthers,
      );
      expect(others, findsOneWidget);
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(AppSettings.keepDeletedMessages.value, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}

class _FlakyStorage implements KeptMessagesStorage {
  _FlakyStorage(this.inner, this.failing);
  final KeptMessagesStorage inner;
  final bool Function() failing;
  @override
  Future<Map<String, Map<String, dynamic>>> readAll() async {
    if (failing()) throw StateError('Encrypted storage is not open');
    return inner.readAll();
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) =>
      inner.write(key, value);
  @override
  Future<void> delete(String key) => inner.delete(key);
}

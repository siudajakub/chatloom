// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('previews off keep the fully generic text', () {
    final text = messageNotificationText(
      previews: false,
      chatName: 'Anna',
      senderName: 'Anna',
      preview: 'Secret plans',
      group: false,
    );
    expect(text.title, 'ChatLoom');
    expect(text.body, 'Open the app to read your message.');
    expect(text.detailed, isFalse);
  });

  test('the app lock hides sender, chat and preview even with previews on', () {
    for (final group in [false, true]) {
      final text = messageNotificationText(
        previews: true,
        chatName: 'Family',
        senderName: 'Anna',
        preview: 'Secret plans',
        group: group,
        locked: true,
      );
      expect(text.title, 'New message');
      expect(text.body, 'Open the app to read');
      expect(text.detailed, isFalse);
    }
    final test = messageNotificationText(
      previews: false,
      chatName: 'Family',
      senderName: 'Anna',
      preview: null,
      group: true,
      test: true,
      locked: true,
    );
    expect(test.title, 'New message (test)');
  });

  test('app lock detection: four or more digits, and fails closed', () async {
    Future<bool> pin(String? value) => appLockPinConfigured(() async => value);
    expect(await pin(null), isFalse);
    expect(await pin(''), isFalse);
    expect(await pin('123'), isFalse);
    expect(await pin('1234'), isTrue);
    expect(await pin('123456'), isTrue);
    expect(
      await appLockPinConfigured(
        () async => throw StateError('Synthetic storage failure'),
      ),
      isTrue,
    );
    debugAppLockConfigured = () async => true;
    addTearDown(() => debugAppLockConfigured = null);
    expect(await personalAppLockConfigured(), isTrue);
  });

  test('unavailable content keeps the generic body under the chat name', () {
    final text = messageNotificationText(
      previews: true,
      chatName: 'Family',
      senderName: 'Anna',
      preview: null,
      group: true,
    );
    expect(text.title, 'Family');
    expect(text.body, 'Open the app to read your message.');
    expect(text.detailed, isFalse);
  });

  test('direct chats show the sender, groups the chat and sender', () {
    final direct = messageNotificationText(
      previews: true,
      chatName: 'Anna (private nickname)',
      senderName: 'Anna',
      preview: 'Photo',
      group: false,
    );
    expect(direct.title, 'Anna');
    expect(direct.body, 'Photo');
    expect(direct.detailed, isTrue);
    final group = messageNotificationText(
      previews: true,
      chatName: 'Family',
      senderName: 'Anna',
      preview: 'Voice message',
      group: true,
      test: true,
    );
    expect(group.title, 'Family (test)');
    expect(group.body, 'Anna: Voice message');
  });

  test('messaging style keeps recent messages without duplicates', () {
    final text = messageNotificationText(
      previews: true,
      chatName: 'Family',
      senderName: 'Anna',
      preview: 'Third',
      group: true,
    );
    final at = DateTime.utc(2026, 10, 17, 12);
    final previous = MessagingStyleInformation(
      const Person(name: 'You'),
      messages: [
        for (var i = 0; i < 6; i++)
          Message('Old $i', at.subtract(Duration(minutes: 10 - i)), null),
        Message('Third', at, null),
      ],
    );
    final style = messagingStyle(
      text: text,
      chatName: 'Family',
      group: true,
      senderName: 'Anna',
      senderKey: 'opaque',
      timestamp: at,
      preview: 'Third',
      previous: previous,
    );
    expect(style.messages, hasLength(6));
    expect(style.messages!.last.text, 'Third');
    expect(style.messages!.where((m) => m.text == 'Third'), hasLength(1));
    expect(style.messages!.last.person!.name, 'Anna');
    expect(style.conversationTitle, 'Family');
    expect(style.groupConversation, isTrue);
    expect(style.person.name, 'You');
  });

  test('messaging style restores sender icons Android does not return', () {
    final text = messageNotificationText(
      previews: true,
      chatName: 'Family',
      senderName: 'Anna',
      preview: 'New',
      group: true,
    );
    final at = DateTime.utc(2026, 10, 17, 12);
    final anna = ByteArrayAndroidIcon(Uint8List.fromList([1]));
    final ben = ByteArrayAndroidIcon(Uint8List.fromList([2]));
    final previous = MessagingStyleInformation(
      const Person(name: 'You'),
      messages: [
        Message('From Ben', at, const Person(name: 'Ben', key: 'ben')),
        Message('From Anna', at, const Person(name: 'Anna', key: 'anna')),
        Message('From Cleo', at, const Person(name: 'Cleo', key: 'cleo')),
      ],
    );
    expect(notificationKeysWithoutIcon(previous), {'ben', 'anna', 'cleo'});
    final style = messagingStyle(
      text: text,
      chatName: 'Family',
      group: true,
      senderName: 'Anna',
      senderKey: 'anna',
      timestamp: at.add(const Duration(minutes: 1)),
      preview: 'New',
      senderIcon: anna,
      knownIcons: {'ben': ben},
      previous: previous,
    );
    final icons = {
      for (final m in style.messages!) m.text: m.person!.icon,
    };
    expect(icons['From Ben'], same(ben));
    expect(icons['From Anna'], same(anna));
    expect(icons['From Cleo'], isNull);
    expect(icons['New'], same(anna));
    expect(style.messages!.first.person!.name, 'Ben');
  });

  test('an older message handled after a newer one is sorted into place, '
      'not appended (concurrent pushes)', () {
    final text = messageNotificationText(
      previews: true,
      chatName: 'Anna',
      senderName: 'Anna',
      preview: 'First',
      group: false,
    );
    final at = DateTime.utc(2026, 10, 17, 12);
    final previous = MessagingStyleInformation(
      const Person(name: 'You'),
      messages: [
        Message('Second', at.add(const Duration(minutes: 1)), null),
        Message('Third', at.add(const Duration(minutes: 2)), null),
      ],
    );
    final style = messagingStyle(
      text: text,
      chatName: 'Anna',
      group: false,
      senderName: 'Anna',
      senderKey: 'opaque',
      timestamp: at,
      preview: 'First',
      previous: previous,
      maxMessages: 2,
    );
    // Bounded to the newest two, in time order.
    expect(style.messages!.map((m) => m.text), ['Second', 'Third']);
    final unbounded = messagingStyle(
      text: text,
      chatName: 'Anna',
      group: false,
      senderName: 'Anna',
      senderKey: 'opaque',
      timestamp: at,
      preview: 'First',
      previous: previous,
    );
    expect(unbounded.messages!.map((m) => m.text), [
      'First',
      'Second',
      'Third',
    ]);
  });

  test('summary line', () {
    expect(notificationSummaryLine(1, 1), '1 message in 1 chat');
    expect(notificationSummaryLine(5, 2), '5 messages in 2 chats');
  });

  test('messages and reminders use separate English channels', () {
    // A new id: Android fixes sound and vibration per channel.
    expect(PersonalNotificationChannels.messagesId, 'chatloom_messages_v2');
    expect(
      PersonalNotificationChannels.messagesId,
      AppConfig.pushNotificationsChannelId,
    );
    expect(PersonalNotificationChannels.legacyMessagesIds, ['fluffychat_push']);
    expect(
      PersonalNotificationChannels.legacyMessagesIds,
      isNot(contains(PersonalNotificationChannels.messagesId)),
    );
    expect(PersonalNotificationChannels.messages.name, 'Messages');
    // One short buzz and ChatLoom's own sound.
    final messages = PersonalNotificationChannels.messages;
    expect(messages.enableVibration, isTrue);
    expect(messages.vibrationPattern, [0, 120]);
    expect(messages.playSound, isTrue);
    expect(messages.sound, isA<RawResourceAndroidNotificationSound>());
    expect(messages.sound!.sound, 'chatloom_message');
    expect(
      File('android/app/src/main/res/raw/chatloom_message.ogg').existsSync(),
      isTrue,
    );
    expect(
      File('android/app/src/main/res/raw/keep.xml').readAsStringSync(),
      contains('@raw/chatloom_message'),
    );
    expect(PersonalNotificationChannels.remindersId, 'personal_reminders');
    expect(
      PersonalNotificationChannels.remindersId,
      AppConfig.personalRemindersChannelId,
    );
    expect(PersonalNotificationChannels.reminders.name, 'Reminders');
    expect(PersonalNotificationChannels.messages.importance, Importance.high);
    expect(PersonalNotificationChannels.reminders.importance, Importance.high);
    // Bots and service chats: shown, but no sound and no pop-up.
    expect(PersonalNotificationChannels.serviceId, 'chatloom_service');
    expect(PersonalNotificationChannels.service.name, 'Network bots');
    expect(PersonalNotificationChannels.service.importance, Importance.low);
    expect(PersonalNotificationChannels.service.playSound, isFalse);
  });

  test('push paths contain no Polish strings or device-locale lookups', () {
    const files = [
      'lib/utils/push_helper.dart',
      'lib/utils/background_push.dart',
      'lib/utils/notification_background_handler.dart',
      'lib/widgets/local_notifications_extension.dart',
      'lib/personal/reminder_notification.dart',
      'lib/personal/message_notification.dart',
      'lib/personal/push_diagnostics.dart',
      'lib/personal/ui/push_diagnostics_page.dart',
    ];
    for (final path in files) {
      final source = File(path).readAsStringSync();
      for (final banned in [
        'Masz przypomnienie',
        'Przypomnienia',
        'PlatformDispatcher.instance.locale',
      ]) {
        expect(source, isNot(contains(banned)), reason: '$path: $banned');
      }
      expect(
        RegExp('[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]').hasMatch(source),
        isFalse,
        reason: '$path contains Polish characters',
      );
    }
  });

  group('message channel migration', () {
    setUp(PersonalNotificationChannels.debugReset);
    tearDown(PersonalNotificationChannels.debugReset);

    AndroidNotificationChannel legacy({
      Importance importance = Importance.high,
      bool playSound = true,
      bool enableVibration = true,
    }) => AndroidNotificationChannel(
      'fluffychat_push',
      'Messages',
      importance: importance,
      playSound: playSound,
      enableVibration: enableVibration,
    );

    test('creates the new channel with the buzz and sound, deletes the old '
        'one, and is idempotent', () async {
      final android = _FakeAndroidNotifications([legacy()]);
      final plugin = _FakeNotifications(android);
      await PersonalNotificationChannels.ensure(plugin);
      final created =
          android.channels[PersonalNotificationChannels.messagesId]!;
      expect(created.importance, Importance.high);
      expect(created.vibrationPattern, [0, 120]);
      expect(created.enableVibration, isTrue);
      expect(created.playSound, isTrue);
      expect(
        (created.sound! as RawResourceAndroidNotificationSound).sound,
        'chatloom_message',
      );
      expect(android.channels.keys, isNot(contains('fluffychat_push')));
      expect(android.deleted, ['fluffychat_push']);
      expect(
        android.channels.keys,
        containsAll([
          PersonalNotificationChannels.remindersId,
          PersonalNotificationChannels.serviceId,
        ]),
      );

      // Same isolate: nothing more to do.
      await PersonalNotificationChannels.ensure(plugin);
      expect(android.created, hasLength(3));
      // Another isolate (the push isolate) after the migration: the old
      // channel is gone, the new one is created again unchanged and nothing
      // is deleted.
      PersonalNotificationChannels.debugReset();
      await PersonalNotificationChannels.ensure(plugin);
      expect(android.deleted, ['fluffychat_push']);
      expect(
        android
            .channels[PersonalNotificationChannels.messagesId]!
            .vibrationPattern,
        [0, 120],
      );
    });

    test('carries over what the user turned down on the old channel', () async {
      final android = _FakeAndroidNotifications([
        legacy(
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        ),
      ]);
      await PersonalNotificationChannels.ensure(_FakeNotifications(android));
      final created =
          android.channels[PersonalNotificationChannels.messagesId]!;
      expect(created.importance, Importance.low);
      expect(created.playSound, isFalse);
      expect(created.sound, isNull);
      expect(created.enableVibration, isFalse);
      expect(created.vibrationPattern, isNull);
      expect(android.deleted, ['fluffychat_push']);

      final blocked = _FakeAndroidNotifications([
        legacy(importance: Importance.none),
      ]);
      PersonalNotificationChannels.debugReset();
      await PersonalNotificationChannels.ensure(_FakeNotifications(blocked));
      expect(
        blocked.channels[PersonalNotificationChannels.messagesId]!.importance,
        Importance.none,
      );
    });

    test(
      'a fresh install creates the new channel and deletes nothing',
      () async {
        final android = _FakeAndroidNotifications([]);
        await PersonalNotificationChannels.ensure(_FakeNotifications(android));
        expect(
          android.channels[PersonalNotificationChannels.messagesId]!.importance,
          Importance.high,
        );
        expect(android.deleted, isEmpty);
      },
    );

    test('an unreadable channel list creates the channels and retries the '
        'migration on the next call', () async {
      final android = _FakeAndroidNotifications([legacy()])..failRead = true;
      final plugin = _FakeNotifications(android);
      await PersonalNotificationChannels.ensure(plugin);
      expect(android.channels.keys, contains('fluffychat_push'));
      expect(
        android.channels.keys,
        contains(PersonalNotificationChannels.messagesId),
      );
      android.failRead = false;
      await PersonalNotificationChannels.ensure(plugin);
      expect(android.deleted, ['fluffychat_push']);
    });

    test('other platforms do nothing', () async {
      await PersonalNotificationChannels.ensure(_FakeNotifications(null));
    });
  });
}

class _FakeAndroidNotifications
    implements AndroidFlutterLocalNotificationsPlugin {
  _FakeAndroidNotifications(List<AndroidNotificationChannel> initial) {
    for (final channel in initial) {
      channels[channel.id] = channel;
    }
  }

  final channels = <String, AndroidNotificationChannel>{};
  final created = <AndroidNotificationChannel>[];
  final deleted = <String>[];
  bool failRead = false;

  @override
  Future<List<AndroidNotificationChannel>?> getNotificationChannels() async {
    if (failRead) throw StateError('unreadable');
    return channels.values.toList();
  }

  @override
  Future<void> createNotificationChannel(
    AndroidNotificationChannel notificationChannel,
  ) async {
    created.add(notificationChannel);
    channels[notificationChannel.id] = notificationChannel;
  }

  @override
  Future<void> deleteNotificationChannel({required String channelId}) async {
    deleted.add(channelId);
    channels.remove(channelId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected notification operation');
}

class _FakeNotifications implements FlutterLocalNotificationsPlugin {
  _FakeNotifications(this.android);

  final _FakeAndroidNotifications? android;

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => android as T?;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected notification operation');
}

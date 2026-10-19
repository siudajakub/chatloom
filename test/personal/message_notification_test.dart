// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/personal/message_notification.dart';
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
    expect(text.title, 'Personal Chat');
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

  test('summary line', () {
    expect(notificationSummaryLine(1, 1), '1 message in 1 chat');
    expect(notificationSummaryLine(5, 2), '5 messages in 2 chats');
  });

  test('messages and reminders use separate English channels', () {
    expect(PersonalNotificationChannels.messagesId, 'fluffychat_push');
    expect(
      PersonalNotificationChannels.messagesId,
      AppConfig.pushNotificationsChannelId,
    );
    expect(PersonalNotificationChannels.messages.name, 'Messages');
    expect(PersonalNotificationChannels.remindersId, 'personal_reminders');
    expect(
      PersonalNotificationChannels.remindersId,
      AppConfig.personalRemindersChannelId,
    );
    expect(PersonalNotificationChannels.reminders.name, 'Reminders');
    expect(PersonalNotificationChannels.messages.importance, Importance.high);
    expect(PersonalNotificationChannels.reminders.importance, Importance.high);
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
}

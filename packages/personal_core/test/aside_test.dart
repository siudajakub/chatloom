// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Aside survives serialization and activity without entering other views',
    () {
      final moved = ConversationMetadata(
        entityId: 'fixture',
        pinOrder: 0,
        archived: true,
        lowPriority: true,
        ignored: true,
        notificationMode: PersonalNotificationMode.all,
      ).moveTo(ChatPlacement.aside);
      final restored = ConversationMetadata.fromJson(
        jsonDecode(jsonEncode(moved.toJson())) as Map<String, dynamic>,
      ).onActivity();
      expect(restored.placement, ChatPlacement.aside);
      expect(restored.notificationMode, PersonalNotificationMode.all);
      expect(restored.isPinned, isTrue);
      expect(restored.visibleInInbox([]), isFalse);
      expect(restored.shouldNotify(), isFalse);
      expect(restored.shouldNotify(mentioned: true), isTrue);
      expect(restored.shouldNotify(threadReplyToMe: true), isFalse);
      final record = InboxRecord(
        representativeRoomId: 'fixture',
        entityId: 'fixture',
        displayName: 'Fictional group',
        isGroup: true,
        unread: true,
        hasDraft: true,
        unanswered: true,
        messageRequest: true,
        labelKeys: ['label'],
        metadata: restored,
      );
      for (final filter in InboxFilter.values) {
        expect(
          projectInbox([record], filter: filter, labelKey: 'label'),
          filter == InboxFilter.aside ? [record] : isEmpty,
          reason: filter.name,
        );
      }
      final inbox = restored.moveTo(ChatPlacement.inbox);
      expect(inbox.visibleInInbox([]), isTrue);
      expect(inbox.shouldNotify(), isTrue);
    },
  );

  test(
    'Aside handles inherited placement, archived flags and ignored precedence',
    () {
      InboxRecord record(String id, {bool ignored = false}) => InboxRecord(
        representativeRoomId: id,
        entityId: id,
        displayName: 'Fictional group',
        placement: ChatPlacement.aside,
        metadata: ConversationMetadata(
          entityId: id,
          archived: true,
          lowPriority: true,
          ignored: ignored,
        ),
      );
      final aside = record('aside');
      final ignored = record('ignored', ignored: true);
      expect(projectInbox([aside, ignored], filter: InboxFilter.aside), [
        aside,
      ]);
      expect(projectInbox([aside, ignored], filter: InboxFilter.ignored), [
        ignored,
      ]);
      expect(projectInbox([aside, ignored]), isEmpty);
      final preferences = NetworkPreferences.fromJson(
        jsonDecode(
              jsonEncode(
                const NetworkPreferences(
                  groupPlacement: ChatPlacement.aside,
                ).toJson(),
              ),
            )
            as Map<String, dynamic>,
        'whatsapp',
      );
      expect(preferences.groupPlacement, ChatPlacement.aside);
    },
  );

  test('Aside keeps an explicit full mute stricter than mentions', () {
    final muted = ConversationMetadata(
      entityId: 'fixture',
      placement: ChatPlacement.aside,
      notificationMode: PersonalNotificationMode.muted,
    );
    expect(muted.shouldNotify(mentioned: true), isFalse);
    expect(
      muted.moveTo(ChatPlacement.inbox).shouldNotify(mentioned: true),
      isFalse,
    );
  });
}

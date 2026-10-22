// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/notification_eligibility.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/reminder_notification.dart';
import 'package:chatloom/personal/round_video/telegram_media_protocol.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:universal_html/html.dart' as html;

extension LocalNotificationsExtension on MatrixState {
  static final html.AudioElement _audioPlayer = html.AudioElement()
    ..src = 'assets/assets/sounds/notification.mp3'
    ..load();

  Future<void> showLocalNotification(Event event) async {
    if (!PlatformInfos.supportsSystemNotifications) return;
    if (isTelegramMediaControl(event.type)) return;
    if (PersonalPrivacy.isJournal(event.room)) {
      // Same presenter, claim and trust checks as the background paths.
      if (!kIsWeb) {
        await presentDueReminder(
          event,
          plugin: FlutterLocalNotificationsPlugin(),
        );
      }
      return;
    }
    final client = event.room.client;
    if (event.senderId == client.userID ||
        OwnSenderResolver.of(client).isStronglyOwnEvent(event)) {
      return;
    }
    final personal = PersonalClient.of(client);
    try {
      // Eligibility needs local private metadata only, never the journal.
      await personal.loadLocal();
    } catch (_) {
      if (!kIsWeb) return;
    }
    if (!kIsWeb &&
        personal.syncFailure == PrivateSyncFailure.storageUnavailable) {
      return;
    }
    final projection = InboxProjection(personal);
    if (!await personalNotificationEligible(
      event,
      projection.metadataFor(event.room),
      notificationMode: projection.notificationModeFor(event.room),
    )) {
      return;
    }

    if (!mounted) return;
    final roomId = event.room.id;
    if (activeRoomId == roomId) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        return;
      }
    }

    // The app lock hides names and previews even when previews are on.
    final locked = await personalAppLockConfigured();
    final previews = !locked && AppSettings.personalNotificationPreviews.value;
    final available = previews && notificationContentAvailable(event);
    final text = messageNotificationText(
      previews: previews,
      chatName: projection.displayName(event.room),
      senderName: event.senderFromMemoryOrFallback.calcDisplayname(),
      preview: available ? personalPreviewLabel(event) : null,
      group: !event.room.isDirectChat,
      locked: locked,
    );
    final title = text.title;
    final body = text.body;
    if (!mounted) return;
    if (kIsWeb) {
      if (AppSettings.webNotificationSound.value) _audioPlayer.play();

      html.Notification(title, body: body, tag: event.room.id);
      return;
    }

    FlutterLocalNotificationsPlugin().show(
      id: messageNotificationId(client.clientName, event.room.id),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        macOS: DarwinNotificationDetails(
          threadIdentifier: '${client.clientName}_${event.room.id}',
        ),
      ),
      payload: ChatLoomPushPayload(
        client.clientName,
        event.room.id,
        event.eventId,
      ).toString(),
    );
  }
}

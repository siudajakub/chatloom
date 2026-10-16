// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/diagnostics.dart';
import 'package:fluffychat/personal/notification_eligibility.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/telegram_media_protocol.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:fluffychat/widgets/incoming_call_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
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
    if (isTelegramMediaControl(event.type)) return;
    if (PersonalPrivacy.isJournal(event.room)) {
      final target = await PersonalPrivacy.reminderTarget(event);
      if (target != null && !kIsWeb) {
        await PersonalClient.of(event.room.client).presentReminder(
          event,
          () => FlutterLocalNotificationsPlugin().show(
            id: ('reminder_${event.content['entityId']}').hashCode,
            title: 'Personal Chat',
            body: 'Masz przypomnienie o rozmowie.',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                AppConfig.pushNotificationsChannelId,
                'Przypomnienia',
                importance: Importance.high,
                visibility: NotificationVisibility.private,
              ),
              macOS: DarwinNotificationDetails(),
            ),
            payload: FluffyChatPushPayload(
              event.room.client.clientName,
              target.id,
              null,
            ).toString(),
          ),
        );
      }
      return;
    }
    final personal = PersonalClient.of(event.room.client);
    await personal.load();
    if (!kIsWeb &&
        personal.syncFailure == PrivateSyncFailure.storageUnavailable)
      return;
    final projection = InboxProjection(personal);
    if (!await personalNotificationEligible(
      event,
      projection.metadataFor(event.room),
      notificationMode: projection.notificationModeFor(event.room),
    )) {
      return;
    }

    if (event.type == RtcNotificationContent.eventType &&
        event.tryParseRtcNotificationContent()?.notificationType == .ring) {
      final context =
          FluffyChatApp.router.routerDelegate.navigatorKey.currentContext ??
          this.context;
      if (!context.mounted) return;
      showDialog<bool>(
        context: context,
        builder: (_) => IncomingCallDialog(event: event),
      ).then((joinCall) {
        if (joinCall != true) return;
        if (!context.mounted) return;
        setActiveClient(event.room.client);
        FluffyChatApp.router.go('/rooms/${event.room.id}?action=call');
      });
    }

    if (!mounted) return;
    final l10n = L10n.of(context);
    final roomId = event.room.id;
    if (activeRoomId == roomId) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        return;
      }
    }

    const title = 'Personal Chat';
    const body = 'Open the app to read your message.';
    if (!mounted) return;
    if (kIsWeb) {
      if (AppSettings.webNotificationSound.value) _audioPlayer.play();

      html.Notification(title, body: body, tag: event.room.id);
      return;
    }

    FlutterLocalNotificationsPlugin().show(
      id: event.room.id.hashCode,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        linux: LinuxNotificationDetails(
          sound: ThemeLinuxSound('message-new-instant'),
          actions: switch (event.type) {
            EventTypes.Message ||
            EventTypes.Encrypted ||
            EventTypes.Sticker => [
              LinuxNotificationAction(
                key: FluffyChatNotificationActions.markAsRead.name,
                label: l10n.markAsRead,
              ),
              LinuxNotificationAction(
                key: FluffyChatNotificationActions.mute.name,
                label: l10n.mute,
              ),
            ],
            RtcNotificationContent.eventType => [
              LinuxNotificationAction(
                key: FluffyChatNotificationActions.enterCall.name,
                label: l10n.enterCall,
              ),
            ],
            _ => [],
          },
        ),
        windows: WindowsNotificationDetails(timestamp: event.originServerTs),
        macOS: DarwinNotificationDetails(
          threadIdentifier: '${client.clientName}_${event.room.id}',
        ),
      ),
      payload: FluffyChatPushPayload(
        client.clientName,
        event.room.id,
        event.eventId,
      ).toString(),
    );
  }
}

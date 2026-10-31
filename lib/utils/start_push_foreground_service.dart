// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix_api_lite/utils/logs.dart';
import 'package:universal_html/html.dart' as html;

import 'foreground_service_controller.dart';

/// Lease names of the short foreground service (one native service, one
/// lease per running task).
abstract final class ForegroundServiceTasks {
  /// Handling a push: loading the message and showing its notification.
  static const push = 'background_push';

  /// Uploading files the user sent.
  static const sendFiles = 'send_files';

  /// Sending a reply typed into a notification while the app is closed.
  static const notificationReply = 'notification_reply';

  /// Another notification action (Mark as read) while the app is closed.
  static const notificationAction = 'notification_action';
}

/// The ongoing notification's channel. The ID stays the original one: a new
/// ID would leave the old channel behind in the system settings. Only its name
/// and description change (Android renames an existing channel in place).
abstract final class ForegroundServiceChannel {
  static const id = 'fluffychat_sync';
  static const name = 'Background activity';
  static const description =
      'Shown briefly while ChatLoom checks for new messages or finishes '
      'sending in the background';
}

/// What the ongoing notification says while [running] tasks hold the
/// service: the work the user started first, then push handling.
String foregroundServiceText(Iterable<String> running) {
  final tasks = running.toSet();
  if (tasks.contains(ForegroundServiceTasks.sendFiles)) return 'Sending files…';
  if (tasks.contains(ForegroundServiceTasks.notificationReply)) {
    return 'Sending your reply…';
  }
  if (tasks.contains(ForegroundServiceTasks.notificationAction)) {
    return 'Marking as read…';
  }
  return 'Checking for new messages…';
}

abstract class ForegroundServices {
  static final _controller = ForegroundServiceController(
    start: _startNativeService,
    stop: _stopNativeService,
    update: _updateNativeService,
    isRunning: _nativeServiceRunning,
  );
  static List<String> get runningServices => _controller.runningServices;

  /// Counted holds on the lease [name] (see [ForegroundLease]); a no-op
  /// where the platform has no such service.
  static ForegroundLease lease(String name, {Duration? maxHold}) =>
      ForegroundLease(
        start: () async => platformSupported && await startService(name),
        stop: () => stopService(name),
        maxHold: platformSupported ? maxHold : null,
      );

  /// Text of the ongoing notification as last shown by this isolate.
  static String? _shownText;
  static bool _channelNamed = false;

  static bool get platformSupported =>
      PlatformInfos.isMobile || PlatformInfos.isWeb;

  static bool _beforeUnload(html.Event e) {
    e.preventDefault();
    return true;
  }

  static Future<void> stopService(String name) async {
    try {
      await _controller.stop(name);
    } catch (_) {
      Logs().w('[PushHelper] Foreground service stop failed');
    }
  }

  static Future<bool> _nativeServiceRunning() async {
    if (kIsWeb || !PlatformInfos.isMobile) return true;
    return FlutterForegroundTask.isRunningService;
  }

  static Future<void> _stopNativeService() async {
    if (kIsWeb) {
      html.window.removeEventListener('beforeunload', _beforeUnload);
      return;
    }
    if (PlatformInfos.isMobile) {
      if (!await FlutterForegroundTask.isRunningService) return;
      final result = await FlutterForegroundTask.stopService();
      if (result is! ServiceRequestSuccess) {
        throw StateError('Foreground service stop failed');
      }
    }
  }

  static Future<bool> startService(String name) async {
    try {
      await _controller.start(name);
      return true;
    } catch (_) {
      Logs().w('[PushHelper] Foreground service start failed');
      return false;
    }
  }

  /// Renames the existing channel once per isolate (the plugin only creates
  /// a missing one). Never throws.
  static Future<void> _nameChannel() async {
    if (_channelNamed || !PlatformInfos.isAndroid) return;
    try {
      await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              ForegroundServiceChannel.id,
              ForegroundServiceChannel.name,
              description: ForegroundServiceChannel.description,
              importance: Importance.low,
              playSound: false,
              enableVibration: false,
              showBadge: false,
            ),
          )
          .timeout(const Duration(seconds: 2));
      _channelNamed = true;
    } catch (_) {}
  }

  static Future<void> _updateNativeService(List<String> running) async {
    if (kIsWeb || !PlatformInfos.isMobile) return;
    final text = foregroundServiceText(running);
    if (text == _shownText) return;
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: AppConfig.appName,
      notificationText: text,
    );
    if (result is ServiceRequestSuccess) _shownText = text;
  }

  static Future<void> _startNativeService() async {
    if (kIsWeb) {
      html.window.addEventListener('beforeunload', _beforeUnload);
      return;
    }
    if (PlatformInfos.isMobile) {
      final text = foregroundServiceText([
        ..._controller.runningServices,
        ?_controller.starting,
      ]);
      await _nameChannel();
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: ForegroundServiceChannel.id,
          channelName: ForegroundServiceChannel.name,
          channelDescription: ForegroundServiceChannel.description,
          onlyAlertOnce: true,
          playSound: false,
          enableVibration: false,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          allowWakeLock: true,
        ),
      );
      if (await FlutterForegroundTask.isRunningService) {
        Logs().d('[PushHelper] Foreground service already running');
        // Started by another isolate of this process: describe this task.
        _shownText = null;
        try {
          await _updateNativeService([?_controller.starting]);
        } catch (_) {}
        return;
      }
      final result = await FlutterForegroundTask.startService(
        serviceTypes: [ForegroundServiceTypes.shortService],
        notificationTitle: AppConfig.appName,
        notificationText: text,
        // The white status-bar silhouette, declared as manifest meta-data
        // (the plugin reads a resource id from there, not a drawable name).
        notificationIcon: NotificationIcon(
          metaDataName: 'pl.personal.chatloom.notification_icon',
        ),
      );
      if (result is! ServiceRequestSuccess) {
        throw StateError('Foreground service start failed');
      }
      _shownText = text;
    }
    return;
  }
}

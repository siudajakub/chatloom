// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:matrix/matrix_api_lite/utils/logs.dart';
import 'package:universal_html/html.dart' as html;

import '../l10n/l10n.dart';
import 'foreground_service_controller.dart';

abstract class ForegroundServices {
  static final _controller = ForegroundServiceController(
    start: _startNativeService,
    stop: _stopNativeService,
  );
  static List<String> get runningServices => _controller.runningServices;

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

  static Future<void> _stopNativeService() async {
    if (kIsWeb) {
      html.window.removeEventListener('beforeunload', _beforeUnload);
      return;
    }
    if (PlatformInfos.isMobile) {
      final result = await FlutterForegroundTask.stopService();
      if (result is! ServiceRequestSuccess) {
        throw StateError('Foreground service stop failed');
      }
    }
  }

  static Future<void> startService(String name) async {
    try {
      await _controller.start(name);
    } catch (_) {
      Logs().w('[PushHelper] Foreground service start failed');
    }
  }

  static Future<void> _startNativeService() async {
      if (kIsWeb) {
        html.window.addEventListener('beforeunload', _beforeUnload);
        return;
      }
      if (PlatformInfos.isMobile) {
        final l10n = await L10n.delegate.load(
          PlatformDispatcher.instance.locale,
        );
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'fluffychat_sync',
            channelName: l10n.loadingMessages,
            channelDescription: l10n.loadingMessages,
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
          return;
        }
        final result = await FlutterForegroundTask.startService(
          serviceTypes: [ForegroundServiceTypes.shortService],
          notificationTitle: 'FluffyChat',
          notificationText: l10n.loadingMessages,
          notificationIcon: NotificationIcon(metaDataName: 'ic_launcher'),
        );
        if (result is! ServiceRequestSuccess) {
          throw StateError('Foreground service start failed');
        }
      }
      return;
  }
}

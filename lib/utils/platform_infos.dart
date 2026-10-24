// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/utils/about_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

abstract class PlatformInfos {
  static bool get isWeb => kIsWeb;
  static bool get isLinux => !kIsWeb && Platform.isLinux;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isMacOS => !kIsWeb && Platform.isMacOS;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isCupertinoStyle => isIOS || isMacOS;

  static bool get isMobile => isAndroid || isIOS;

  /// For desktops which don't support ChachedNetworkImage yet
  static bool get isBetaDesktop => isWindows || isLinux;

  static bool get isDesktop => isLinux || isWindows || isMacOS;

  /// The private macOS client intentionally runs without system notifications.
  static bool get supportsSystemNotifications => !isMacOS;

  static bool get usesTouchscreen => !isMobile;

  static bool get supportsVideoPlayer =>
      !PlatformInfos.isWindows && !PlatformInfos.isLinux;

  /// ChatLoom's photo encoder (`lib/personal/media/photo_encoder.dart`):
  /// one quality profile on Android and macOS (the SDK's pure-Dart fallback
  /// upscaled, kept GPS and wrote JPEG q100).
  static bool get supportsCustomImageResizer =>
      PlatformInfos.isWeb || PlatformInfos.isMobile || PlatformInfos.isMacOS;

  /// Native video compression, thumbnails and metadata (light_compressor:
  /// MediaCodec on Android, AVFoundation on macOS).
  static bool get supportsVideoTranscode => isMobile || isMacOS;

  /// Web could also record in theory but currently creates broken opus
  static bool get platformCanRecord => (isMobile || isMacOS);

  static bool get supportsRoundCapture => isAndroid || isMacOS;

  static bool get supportsAppLock => (isMobile || isMacOS);

  static String get appDisplayName =>
      '${AppSettings.applicationName.value} ${isWeb ? 'web' : Platform.operatingSystem}${kReleaseMode ? '' : 'Debug'}';

  static Future<String> getVersion() async {
    var version = kIsWeb ? 'Web' : 'Unknown';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    return version;
  }

  /// Settings → About (a glass Notion dialog, `about_dialog.dart`).
  static Future<void> showDialog(BuildContext context) async {
    final version = await PlatformInfos.getVersion();
    if (!context.mounted) return;
    await showChatLoomAboutDialog(context, version: version);
  }
}

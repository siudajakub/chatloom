// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui';

import 'package:chatloom/ui/notion/notion_tokens.dart';

abstract class AppConfig {
  static const double messageFontSize = 16.0;
  static const bool hideTypingUsernames = false;

  static const String inviteLinkPrefix = 'https://matrix.to/#/';
  static const String deepLinkPrefix = 'pl.personal.chat://chat/';
  static const String schemePrefix = 'matrix:';
  static const String pushNotificationsChannelId = 'fluffychat_push';

  /// Dedicated channel so reminder alerts never rename the message channel.
  static const String personalRemindersChannelId = 'personal_reminders';

  /// The app UI, notifications and background paths are English-only.
  static const Locale appLocale = Locale('en');
  static const String pushNotificationsAppId = 'pl.personal.chat';

  /// Legacy FluffyChat radius, aligned with the Notion card radius.
  static const double borderRadius = NotionRadius.md;
  static const double columnWidth = 360.0;

  static const String appId = 'pl.personal.chat';
  static const String appSsoUrlScheme = 'pl.personal.chat.auth';

  /// User-visible product name. Never use it in storage keys or other
  /// persisted identifiers; see [legacyStorageAppName].
  static const String appName = 'ChatLoom';

  /// The name the app had when existing installs created persisted data
  /// (secure-storage session backups, login client names). It must never
  /// change, otherwise existing installs lose access to that data.
  static const String legacyStorageAppName = 'Personal Chat';

  /// ChatLoom is based on FluffyChat; its AGPL source and credits stay linked.
  static const String upstreamName = 'FluffyChat';
  static const String upstreamSourceCodeUrl =
      'https://github.com/krille-chan/fluffychat';
  static const String upstreamCredit =
      'ChatLoom is a modified version of FluffyChat v2.10.0 (modified since '
      'October 2026). FluffyChat © 2019-Present Christian Kußowski and the '
      'FluffyChat contributors. Licensed under the GNU Affero General Public '
      'License v3.0 or later.';

  static const String mainIsolatePortName = 'main_isolate';
  static const String pushIsolatePortName = 'push_isolate';
  static const String pushHelperCrashReportKey = 'push_helper_crash_report';

  static const String vodozemacVersion = '0.8.1';
}

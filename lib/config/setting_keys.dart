// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:async/async.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:managed_configurations/managed_configurations.dart';
import 'package:matrix/matrix_api_lite/utils/logs.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppSettings<T> {
  textMessageMaxLength<int>('textMessageMaxLength', 16384),

  /// Max lines for unselected HTML/text bubbles; 0 = unlimited (no fade).
  messagePreviewMaxLines<int>('chat.fluffy.message_preview_max_lines', 50),
  audioRecordingAutoGain<bool>('audioRecordingAutoGain', true),
  audioRecordingEchoCancel<bool>('audioRecordingEchoCancel', false),
  audioRecordingNoiseSuppress<bool>('audioRecordingNoiseSuppress', true),
  showNoGoogle<bool>('chat.fluffy.show_no_google', false),
  unifiedPushRegistered<bool>('chat.fluffy.unifiedpush.registered', false),
  unifiedPushEndpoint<String>('chat.fluffy.unifiedpush.endpoint', ''),
  pushNotificationsGatewayUrl<String>(
    'pushNotificationsGatewayUrl',
    'https://push.example.org/_matrix/push/v1/notify',
  ),
  pushNotificationsPusherFormat<String>(
    'pushNotificationsPusherFormat',
    'event_id_only',
  ),
  renderHtml<bool>('chat.fluffy.renderHtml', true),
  hideRedactedEvents<bool>('chat.fluffy.hideRedactedEvents', false),
  hideUnknownEvents<bool>('chat.fluffy.hideUnknownEvents', true),
  autoplayImages<bool>('chat.fluffy.autoplay_images', true),
  personalIncognito<bool>('pl.personal.incognito', true),

  /// Accent preset of the colour system (`NotionAccent.name`). Read by
  /// `ThemeController`, which rebuilds the theme live when it changes.
  appearanceAccent<String>('pl.personal.appearance.accent', 'blue'),

  /// Colour intensity (`NotionIntensity.name`): muted, balanced or vivid.
  appearanceIntensity<String>('pl.personal.appearance.intensity', 'balanced'),

  /// Prefetch voice notes and round videos (ciphertext into the encrypted
  /// media cache) as soon as a chat is open, so playback starts instantly.
  personalAutoDownloadVoiceRounds<bool>(
    'pl.personal.media.auto_download_voice_rounds',
    true,
  ),
  personalAutoDownloadWifiOnly<bool>(
    'pl.personal.media.auto_download_wifi_only',
    false,
  ),

  /// Voice note capture: platform voice-communication path (AEC + NS + AGC).
  personalVoiceIsolation<bool>('pl.personal.voice.isolation', false),

  /// Voice note capture: higher bitrate (Opus 96 kbps / AAC 128 kbps).
  personalVoiceHighQuality<bool>('pl.personal.voice.high_quality', false),

  /// Voice note playback speed, remembered across notes (Telegram).
  personalVoicePlaybackSpeed<double>('pl.personal.voice.playback_speed', 1.0),
  personalRoundHighQuality<bool>('pl.personal.round.high_quality', false),
  personalRoundStabilization<bool>('pl.personal.round.stabilization', true),
  personalRoundNoiseReduction<bool>('pl.personal.round.noise_reduction', true),

  /// Show sender and message preview (decrypted on this device only) in
  /// message notifications. Hidden while the app lock is set; on the lock
  /// screen Android hides it only with "hide sensitive content".
  personalNotificationPreviews<bool>(
    'pl.personal.notifications.previews',
    true,
  ),

  /// Inbox encryption notice dismissed until its issues change: an account
  /// hash and issue signatures (see `E2eeNoticeDismissal`), no ids.
  personalE2eeNoticeDismissed<String>('pl.personal.e2ee_notice.dismissed', ''),

  /// Settings › Advanced › Developer options: shows logs, the app
  /// configuration, manual push setup, key details and "Message info".
  /// Read only through `DeveloperOptions` (lib/personal/developer_options.dart).
  personalDeveloperOptions<bool>('pl.personal.developer_options', false),
  sendTypingNotifications<bool>('chat.fluffy.send_typing_notifications', true),
  sendPublicReadReceipts<bool>('chat.fluffy.send_public_read_receipts', true),
  swipeRightToLeftToReply<bool>('chat.fluffy.swipeRightToLeftToReply', true),
  sendOnEnter<bool>('chat.fluffy.send_on_enter', false),
  shareKeysWith<String>('chat.fluffy.share_keys_with_2', 'all'),
  displayChatDetailsColumn('chat.fluffy.display_chat_details_column', false),
  // AppConfig-mirrored settings
  applicationName<String>('chat.fluffy.application_name', 'ChatLoom'),
  defaultHomeserver<String>(
    'chat.fluffy.default_homeserver',
    'matrix.beeper.com',
  ),
  emojiSuggestionLocale<String>('emoji_suggestion_locale', ''),
  enableSoftLogout<bool>('chat.fluffy.enable_soft_logout', true),
  enableMatrixNativeOIDC<bool>('chat.fluffy.enable_matrix_native_oidc', true),
  presetHomeserver<String>('chat.fluffy.preset_homeserver', ''),
  welcomeText<String>('chat.fluffy.welcome_text', ''),
  // OIDC client registration metadata (RFC 7591). Empty optional URLs are
  // omitted from the registration request.
  website<String>(
    'chat.fluffy.website_url',
    'https://github.com/siudajakub/chatloom',
  ),
  logoUrl<String>('chat.fluffy.logo_url', ''),
  privacyPolicy<String>('chat.fluffy.privacy_policy_url', ''),
  tos<String>('chat.fluffy.tos_url', ''),
  sendTimelineEventTimeout<int>('chat.fluffy.send_timeline_event_timeout', 15),
  webNotificationSound<bool>('chat.fluffy.web_notification_sound', true),
  chatFilter<String>('chat.fluffy.chat_filter', 'allChats'),
  showThumbnailsInTimeline<bool>('chat.fluffy.showThumbnailsInTimeline', true),

  /// Double tap reacts with the network's first quick reaction (on by
  /// default, like Messenger/Instagram/Telegram).
  doubleTapToReact<bool>('chat.fluffy.double_tap_to_react', true),

  /// An emoji the user picked for double tap; empty means automatic: the
  /// network's first quick reaction, a heart wherever it has one.
  doubleTapReaction<String>('chat.fluffy.double_tap_reaction', ''),
  benchmarksInLogs<bool>('chat.fluffy.benchmarks_in_logs', false),
  fallbackLiveKitInstance<String>(
    'chat.fluffy.fallback_live_kit_instance',
    'https://livekit-jwt.fluffy.chat',
  );

  final String key;
  final T _defaultValue;

  const AppSettings(this.key, this._defaultValue);

  static SharedPreferences get store => _store!;
  static SharedPreferences? _store;

  static Map<String, Object?>? _platformConfiguration;

  T get defaultValue {
    final platformConfig = _platformConfiguration?[name];
    if (platformConfig is T) return platformConfig;
    return _defaultValue;
  }

  /// Keys that record this device's push registration, not a preference:
  /// [resetPreferences] keeps them so the registration stays consistent.
  static const deviceStateSettings = {
    unifiedPushRegistered,
    unifiedPushEndpoint,
    pushNotificationsGatewayUrl,
    pushNotificationsPusherFormat,
  };

  /// Restores every app preference to its default. It never clears the
  /// whole store: the account registry, push registration and other
  /// non-setting entries are kept.
  static Future<void> resetPreferences() async {
    final store = AppSettings.store;
    for (final setting in values) {
      if (deviceStateSettings.contains(setting)) continue;
      await store.remove(setting.key);
    }
    // The platform default that [init] writes on first start.
    await store.setBool(AppSettings.sendOnEnter.key, !PlatformInfos.isMobile);
  }

  static Future<SharedPreferences> init({bool loadWebConfigFile = true}) async {
    if (AppSettings._store != null) return AppSettings.store;

    final store = AppSettings._store = await SharedPreferences.getInstance();

    if (store.getBool(AppSettings.sendOnEnter.key) == null) {
      await store.setBool(AppSettings.sendOnEnter.key, !PlatformInfos.isMobile);
    }

    // Load configuration from config.json file or MDM:
    if (PlatformInfos.isMobile) {
      _platformConfiguration =
          await ManagedConfigurations().getManagedConfigurations;
    } else if (kIsWeb && loadWebConfigFile) {
      try {
        final configJsonString = utf8.decode(
          (await http.get(Uri.parse('config.json'))).bodyBytes,
        );
        _platformConfiguration =
            json.decode(configJsonString) as Map<String, Object?>;
      } on FormatException catch (_) {
        Logs().v('[ConfigLoader] config.json not found');
      } catch (e) {
        Logs().v('[ConfigLoader] config.json not found', e);
      }
    }

    return store;
  }
}

extension AppSettingsBoolNExtension on AppSettings<bool?> {
  bool? get value {
    final value = Result(() => AppSettings.store.getBool(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value;
  }

  Future<void> setItem(bool value) => AppSettings.store.setBool(key, value);
}

extension AppSettingsBoolExtension on AppSettings<bool> {
  bool get value {
    final value = Result(() => AppSettings.store.getBool(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(bool value) => AppSettings.store.setBool(key, value);
}

extension AppSettingsStringExtension on AppSettings<String> {
  String get value {
    final value = Result(() => AppSettings.store.getString(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(String value) => AppSettings.store.setString(key, value);
}

extension AppSettingsIntExtension on AppSettings<int> {
  int get value {
    final value = Result(() => AppSettings.store.getInt(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(int value) => AppSettings.store.setInt(key, value);
}

extension AppSettingsDoubleExtension on AppSettings<double> {
  double get value {
    final value = Result(() => AppSettings.store.getDouble(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(double value) => AppSettings.store.setDouble(key, value);
}

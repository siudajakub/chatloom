// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The system's power saving mode (BP-08): Android Battery Saver
/// (`PowerManager.isPowerSaveMode`) and macOS Low Power Mode
/// (`ProcessInfo.isLowPowerModeEnabled`), reported by `PowerSavingPlugin.kt`
/// and `MainFlutterWindow.swift` over `pl.personal.chat/power`.
///
/// While it is on, `NotionActivity` turns the app into a lite mode like
/// Telegram's power saver: Notion motion is reduced (content loops such as
/// Lottie stickers and inline GIF videos stay on their first frame, one-shot
/// motion jumps to its end) and glass falls back to its opaque tint. Sync,
/// sending, notifications and media the user starts are untouched.
abstract final class PowerSaving {
  static const channel = MethodChannel('pl.personal.chat/power');
  static final _active = ValueNotifier<bool>(false);
  static bool _started = false;

  /// Whether the system saves power; false where unsupported or unknown.
  static ValueListenable<bool> get active => _active;

  /// Starts listening (once) and returns [active].
  static ValueListenable<bool> watch() {
    if (!_started) {
      _started = true;
      if (!kIsWeb && (PlatformInfos.isAndroid || PlatformInfos.isMacOS)) {
        unawaited(_start());
      }
    }
    return _active;
  }

  static Future<void> _start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'powerSaving' && call.arguments is bool) {
        _active.value = call.arguments as bool;
      }
    });
    try {
      final value = await channel.invokeMethod<bool>('isPowerSaving');
      if (value != null) _active.value = value;
    } catch (_) {
      // Older native side or no plugin: stay in the normal mode.
    }
  }

  /// Sets the mode directly (tests).
  @visibleForTesting
  static void debugSet(bool value) => _active.value = value;

  @visibleForTesting
  static void debugReset() {
    _started = false;
    _active.value = false;
  }
}

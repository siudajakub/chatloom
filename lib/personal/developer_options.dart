// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:flutter/foundation.dart';

/// The single source of the "Developer options" switch
/// (Settings › Advanced). Off by default, like Android's developer options,
/// Signal's internal preferences and Telegram's hidden debug menu.
///
/// While it is on, Settings › Advanced › Developer offers the log viewer,
/// the app configuration editor, manual push gateway setup, notification
/// registration details, the account's server notification rules, the key
/// sharing policy and identity keys, and the message menu offers
/// "Message info" with the raw message source.
abstract final class DeveloperOptions {
  /// Route of the developer page inside the settings shell.
  static const route = '/rooms/settings/developer';

  static final ValueNotifier<bool> _changes = ValueNotifier(_read());

  /// Notifies when the switch changes; its value is [enabled].
  static ValueListenable<bool> get changes => _changes;

  static bool _read() {
    try {
      return AppSettings.personalDeveloperOptions.value;
    } catch (_) {
      // Settings storage not initialised (tests, early start): off.
      return false;
    }
  }

  /// Whether developer tools are shown. Reads the stored value, so a
  /// change made elsewhere (e.g. the configuration editor) is seen too.
  static bool get enabled => _read();

  static Future<void> setEnabled(bool value) async {
    await AppSettings.personalDeveloperOptions.setItem(value);
    _changes.value = value;
  }
}

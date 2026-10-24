// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class UpdateNotifier {
  static const String versionStoreKey = 'last_known_version';

  /// The text of the one-time notice after an update.
  static String updatedText(String version) =>
      'Updated to ${AppSettings.applicationName.value} $version';

  /// After a new version starts for the first time, says so once in a quiet
  /// themed snackbar (no dialog, no action, no banner), like Telegram's
  /// silent updates. The first install says nothing. The name is kept for
  /// the existing caller.
  static Future<void> showUpdateDialog(BuildContext context) async {
    final currentVersion = await PlatformInfos.getVersion();
    final store = await SharedPreferences.getInstance();
    final storedVersion = store.getString(versionStoreKey);
    if (!context.mounted) return;
    if (currentVersion == storedVersion) return;
    if (storedVersion != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(updatedText(currentVersion))));
    }
    await store.setString(versionStoreKey, currentVersion);
  }
}

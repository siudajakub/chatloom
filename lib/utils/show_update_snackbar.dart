// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class UpdateNotifier {
  static const String versionStoreKey = 'last_known_version';

  /// Upstream checked FluffyChat's GitHub releases for a Windows installer.
  /// ChatLoom has no public release feed, so no update banner is shown.
  static Future<void> showUpdateAvailableBanner(BuildContext context) async {}

  static Future<void> showUpdateDialog(BuildContext context) async {
    final l10n = L10n.of(context);
    final currentVersion = await PlatformInfos.getVersion();
    final store = await SharedPreferences.getInstance();
    final storedVersion = store.getString(versionStoreKey);
    if (!context.mounted) return;

    if (currentVersion != storedVersion) {
      if (storedVersion != null) {
        showDialog(
          barrierDismissible: true,
          context: context,
          builder: (context) => AlertDialog(
            title: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 256),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
                child: Image.asset('assets/logo/mini/banner.png'),
              ),
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 256),
              child: Column(
                mainAxisSize: .min,
                spacing: 16,
                children: [
                  Text(
                    l10n.updateInstalled(currentVersion),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
            actions: [
              AdaptiveDialogAction(
                bigButtons: true,
                targetPlatform: TargetPlatform.android,
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.close),
              ),
            ],
          ),
        );
      }
      await store.setString(versionStoreKey, currentVersion);
    }
  }
}

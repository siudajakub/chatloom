// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/device_settings/device_settings.dart';
import 'package:chatloom/pages/device_settings/device_signout.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

import 'user_device_list_item.dart';

class DevicesSettingsView extends StatelessWidget {
  final DevicesSettingsController controller;

  const DevicesSettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    return NotionSettingsScaffold(
      title: L10n.of(context).devices,
      showBack: !ChatLoomThemes.isColumnMode(context),
      child: FutureBuilder<bool>(
        future: controller.loadUserDevices(context),
        builder: (BuildContext context, snapshot) {
          if (snapshot.hasError) {
            return NotionEmptyState(
              icon: Icons.devices_other_outlined,
              title: humanErrorText(snapshot.error!, action: ErrorAction.load),
            );
          }
          if (!snapshot.hasData || controller.devices == null) {
            return const Center(child: NotionDelayedSpinner());
          }
          final others = controller.notThisDevice;
          final workers = controller.workerDeviceIds;
          final bulk = bulkSignOutDevices(others, workers);
          // Devices rise in once when they arrive; later rebuilds do not
          // animate.
          return NotionEntranceScope(
            child: ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: others.length + 1,
              itemBuilder: (BuildContext context, int i) {
                if (i == 0) {
                  return NotionEntrance(
                    playKey: 'this-device',
                    afterRoute: false,
                    rise: NotionMotion.riseList,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (controller.chatBackupEnabled == false)
                          const Padding(
                            padding: EdgeInsets.only(bottom: NotionSpace.xs),
                            child: NotionCallout(
                              icon: Icons.info_outlined,
                              title: 'Verify devices with your recovery key',
                              message:
                                  'Devices you connect to key backup with '
                                  'your recovery key are verified '
                                  'automatically.',
                            ),
                          ),
                        if (controller.thisDevice != null) ...[
                          NotionSectionHeader(
                            title: L10n.of(context).thisDevice,
                            padding: const EdgeInsets.only(
                              bottom: NotionSpace.xxs,
                            ),
                          ),
                          UserDeviceListItem(
                            controller.thisDevice!,
                            rename: controller.renameDeviceAction,
                            remove: controller.removeDeviceAction,
                            verify: controller.verifyDeviceAction,
                            block: controller.blockDeviceAction,
                            unblock: controller.unblockDeviceAction,
                          ),
                        ],
                        if (others.isEmpty)
                          NotionEmptyState(
                            icon: Icons.devices_outlined,
                            title: L10n.of(context).noOtherDevicesFound,
                          )
                        else ...[
                          const NotionSectionHeader(title: 'Other devices'),
                          // Never the ChatLoom worker; the dialog lists
                          // exactly what will be signed out.
                          if (bulk.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: NotionSpace.xs,
                              ),
                              child: NotionButton.destructive(
                                expand: true,
                                icon: Icons.logout_outlined,
                                label: 'Sign out all other devices',
                                onPressed: controller.removeOtherDevicesAction,
                              ),
                            ),
                        ],
                      ],
                    ),
                  );
                }
                i--;
                final device = others[i];
                return NotionEntrance(
                  playKey: device.deviceId,
                  afterRoute: false,
                  rise: NotionMotion.riseList,
                  child: UserDeviceListItem(
                    device,
                    isWorker: workers.contains(device.deviceId),
                    rename: controller.renameDeviceAction,
                    remove: controller.removeDeviceAction,
                    verify: controller.verifyDeviceAction,
                    block: controller.blockDeviceAction,
                    unblock: controller.unblockDeviceAction,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

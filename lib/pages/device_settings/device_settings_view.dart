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
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !ChatLoomThemes.isColumnMode(context),
        centerTitle: false,
        title: Text(L10n.of(context).devices),
      ),
      body: NotionSettingsBody(
        child: FutureBuilder<bool>(
          future: controller.loadUserDevices(context),
          builder: (BuildContext context, snapshot) {
            final theme = Theme.of(context);
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: .min,
                  children: <Widget>[
                    const Icon(Icons.error_outlined),
                    Text(
                      humanErrorText(snapshot.error!, action: ErrorAction.load),
                    ),
                  ],
                ),
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
                        mainAxisSize: .min,
                        children: [
                          if (controller.chatBackupEnabled == false)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8.0,
                              ),
                              child: ListTile(
                                leading: const CircleAvatar(
                                  child: Icon(Icons.info_outlined),
                                ),
                                subtitle: const Text(
                                  'Devices you connect to key backup with '
                                  'your recovery key are verified '
                                  'automatically.',
                                ),
                              ),
                            ),
                          if (controller.thisDevice != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 8.0,
                              ),
                              alignment: Alignment.centerLeft,
                              child: Text(
                                L10n.of(context).thisDevice,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                                textAlign: TextAlign.left,
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
                          // Never the ChatLoom worker; the dialog lists
                          // exactly what will be signed out.
                          if (bulk.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: NotionSpace.md,
                                vertical: NotionSpace.xs,
                              ),
                              child: NotionButton.destructive(
                                expand: true,
                                icon: Icons.logout_outlined,
                                label: 'Sign out all other devices',
                                onPressed: controller.removeOtherDevicesAction,
                              ),
                            )
                          else if (others.isNotEmpty)
                            const SizedBox.shrink()
                          else
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Text(
                                  L10n.of(context).noOtherDevicesFound,
                                ),
                              ),
                            ),
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
      ),
    );
  }
}

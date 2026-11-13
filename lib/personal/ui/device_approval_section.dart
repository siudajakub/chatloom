// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Settings → Sync: own devices whose private changes the background
/// service ignores, each with an Approve action. Shown on a device the
/// service already trusts; approving lets the other device's Aside, merges
/// and other private changes reach every device.
class DeviceApprovalSection extends StatelessWidget {
  final PersonalClient personal;

  /// The settings page's guarded runner (shows a snackbar on failure).
  final Future<void> Function(Future<void> Function() action) run;

  const DeviceApprovalSection({
    super.key,
    required this.personal,
    required this.run,
  });

  @override
  Widget build(BuildContext context) {
    final waiting = personal.canApproveDevices
        ? personal.devicesAwaitingApproval
        : const <String>[];
    final devices =
        personal.client.userDeviceKeys[personal.client.userID]?.deviceKeys;
    return NotionSizeReveal(
      visible: waiting.isNotEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotionSectionHeader(title: 'Devices waiting for approval'),
          Text(
            'Changes made on these devices do not reach your other devices '
            'until you approve them here.',
            style: context.notion.typography.footnoteMuted,
          ),
          for (final id in waiting)
            NotionListRow(
              key: ValueKey('device-approval-$id'),
              leading: const Icon(Icons.devices_other_outlined),
              title: devices?[id]?.deviceDisplayName ?? 'Another device',
              subtitle:
                  personal.approvalError(id) ??
                  (devices?[id]?.verified == true
                      ? 'Verified · not trusted by the background service'
                      : 'Not verified yet: verify it first in Security › Devices'),
              trailing: NotionButton(
                label: 'Approve',
                onPressed: personal.isApprovalPending(id)
                    ? null
                    : () => run(() => personal.approveDevice(id)),
              ),
            ),
        ],
      ),
    );
  }
}

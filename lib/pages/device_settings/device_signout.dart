// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/device_extension.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

// The ChatLoom worker is an ordinary device of the account. Signing it out
// stops transcription and reminders until it is enrolled again on the
// server, so the devices page names it and never removes it in bulk.

/// The worker's default session name (`worker/bin/worker.dart`), or a name
/// with "worker" in it after a rename. A false match only keeps a device out
/// of the bulk sign-out; it can still be signed out on its own.
bool isWorkerDeviceName(String? name) =>
    name != null && RegExp(r'\bworker\b', caseSensitive: false).hasMatch(name);

/// The worker's device ids among [devices]: the device whose identity key
/// ([identityKeys]: device id → curve25519 key) signed the newest trusted
/// worker heartbeat ([heartbeatDeviceKey], the way private sync recognises
/// the worker), plus any device named like it.
Set<String> findWorkerDeviceIds({
  required Iterable<Device> devices,
  Map<String, String?> identityKeys = const {},
  String? heartbeatDeviceKey,
}) => {
  for (final device in devices)
    if (isWorkerDeviceName(device.displayName) ||
        (heartbeatDeviceKey != null &&
            identityKeys[device.deviceId] == heartbeatDeviceKey))
      device.deviceId,
};

/// What "Sign out all other devices" removes: every other device except the
/// worker.
List<Device> bulkSignOutDevices(
  Iterable<Device> otherDevices,
  Set<String> workerIds,
) => [
  for (final device in otherDevices)
    if (!workerIds.contains(device.deviceId)) device,
];

/// Two steps for an irreversible bulk action: the list of exactly what will
/// be signed out (names and last activity, the worker kept), then a final
/// "Sign out now?". True only when both are confirmed.
Future<bool> confirmBulkSignOut(
  BuildContext context, {
  required List<Device> devices,
  required bool workerKept,
}) async {
  final count = devices.length;
  final noun = count == 1 ? 'device' : 'devices';
  final reviewed = await showNotionCustomDialog<bool>(
    context: context,
    builder: (context) => NotionDialog(
      title: 'Sign out $count other $noun?',
      content: _SignOutList(devices: devices, workerKept: workerKept),
      actions: [
        NotionButton.ghost(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        NotionButton.destructive(
          label: 'Sign out $count $noun',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  if (reviewed != true || !context.mounted) return false;
  return showNotionConfirmDialog(
    context: context,
    title: 'Are you sure?',
    message:
        '$count $noun will be signed out now. This can’t be undone; '
        'each one has to sign in again.',
    confirmLabel: 'Sign out',
    destructive: true,
  );
}

/// One device. The worker needs its name typed, because removing it stops
/// ChatLoom's background features on the server.
Future<bool> confirmDeviceSignOut(
  BuildContext context, {
  required Device device,
  required bool worker,
}) async {
  if (!worker) {
    return showNotionConfirmDialog(
      context: context,
      title: 'Sign out ${device.displayname}?',
      message:
          'This device loses access to your account and encrypted messages '
          'until it signs in again.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
  }
  const phrase = 'remove worker';
  final typed = await showTextInputDialog(
    context: context,
    title: 'Sign out the ChatLoom worker?',
    message:
        'Transcription and reminders stop until the worker is set up again '
        'on the server. Type "$phrase" to confirm.',
    hintText: phrase,
    okLabel: 'Sign out worker',
    isDestructive: true,
    autocorrect: false,
    validator: (input) => input.trim().toLowerCase() == phrase
        ? null
        : 'Type "$phrase" to confirm.',
  );
  return typed != null && typed.trim().toLowerCase() == phrase;
}

class _SignOutList extends StatelessWidget {
  const _SignOutList({required this.devices, required this.workerKept});

  final List<Device> devices;
  final bool workerKept;

  @override
  Widget build(BuildContext context) {
    final typography = context.notion.typography;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final device in devices)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: NotionSpace.xxs,
                    ),
                    child: Row(
                      spacing: NotionSpace.sm,
                      children: [
                        Icon(device.icon, size: NotionSize.icon),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                device.displayname,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: typography.callout,
                              ),
                              if (device.lastSeenTs != null)
                                Text(
                                  'Last active ${DateTime.fromMillisecondsSinceEpoch(device.lastSeenTs!).localizedTimeShort(context)}',
                                  style: typography.captionMuted,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: NotionSpace.sm),
        if (workerKept)
          Text(
            'The ChatLoom worker stays signed in, so transcription and '
            'reminders keep working.',
            style: typography.footnoteMuted,
          ),
        Text(
          'Signed-out devices can’t read your encrypted messages until they '
          'sign in again with your recovery key.',
          style: typography.footnoteMuted,
        ),
      ],
    );
  }
}

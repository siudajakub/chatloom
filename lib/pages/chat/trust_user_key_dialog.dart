// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/key_verification/key_verification_dialog.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/beautify_string_extension.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/widgets/adaptive_dialogs/dialog_text_field.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_notion_adaptive_dialog.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

Future<bool> showTrustUserInRoomDialog(BuildContext context, Room room) async {
  if (!room.encrypted) return true;

  List<User> users;
  try {
    users = await room.requestParticipants();
  } catch (error, stack) {
    // The member list could not be refreshed (offline, server error): ask
    // about the members already known. Encryption loads the list again,
    // and a failure there shows on the message itself.
    logBackgroundError('trust_check_members', error, stack);
    users = room.getParticipants();
  }
  if (!context.mounted) return false;

  users.removeWhere((user) {
    if (user.id == room.client.userID) return true;
    final keys = room.client.userDeviceKeys[user.id];
    final masterKey = keys?.masterKey;

    if (keys == null ||
        masterKey == null ||
        masterKey.verified ||
        masterKey.trustOnFirstUseSince != null) {
      return true;
    }
    return false;
  });

  if (users.isEmpty) return true;

  final l10n = L10n.of(context);

  // The question is a choice, not a destructive confirmation: a glass
  // dialog with the three answers stacked full width.
  final action = await showNotionAdaptiveDialog<_Action>(
    context: context,
    builder: (context) {
      final tokens = context.notion;
      return NotionAlertDialog(
        icon: Icon(Icons.lock_outlined, color: tokens.colors.accent),
        title: Text(
          users.length == 1
              ? l10n.messageCanOnlyBeReadByUser
              : l10n.messageCanOnlyBeReadByUsers,
          textAlign: TextAlign.center,
        ),
        content: SelectionArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final user in users) ...[
                  Row(
                    children: [
                      Avatar(
                        name: user.calcDisplayname(),
                        mxContent: user.avatarUrl,
                        size: NotionSize.iconSm,
                      ),
                      const SizedBox(width: NotionSpace.xs),
                      Expanded(
                        child: Text(
                          user.calcDisplayname(),
                          style: tokens.typography.footnoteMuted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: NotionSpace.xxs),
                  Builder(
                    builder: (context) {
                      final controller = TextEditingController(
                        text: l10n.publicKey(
                          room
                                  .client
                                  .userDeviceKeys[user.id]
                                  ?.masterKey
                                  ?.publicKey
                                  ?.beautifiedOneLine ??
                              '???',
                        ),
                      );
                      return DialogTextField(
                        controller: controller,
                        textStyle: tokens.typography.caption,
                        readOnly: true,
                        maxLines: 3,
                      );
                    },
                  ),
                  const SizedBox(height: NotionSpace.sm),
                ],
              ],
            ),
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: NotionSpace.xs,
              children: [
                NotionButton.primary(
                  key: const Key('trust_user_continue_button'),
                  expand: true,
                  label: l10n.continueText,
                  onPressed: () {
                    for (final user in users) {
                      room.client.userDeviceKeys[user.id]?.masterKey
                          ?.trustOnFirstUse();
                    }
                    Navigator.of(context).pop(_Action.allow);
                  },
                ),
                if (room.isDirectChat)
                  NotionButton(
                    expand: true,
                    label: l10n.interactiveVerification,
                    onPressed: () =>
                        Navigator.of(context).pop(_Action.verification),
                  ),
                NotionButton.ghost(
                  expand: true,
                  label: l10n.cancel,
                  onPressed: () => Navigator.of(context).pop(_Action.deny),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  if (action == null) return false;

  switch (action) {
    case _Action.allow:
      for (final user in users) {
        room.client.userDeviceKeys[user.id]?.masterKey?.trustOnFirstUse();
      }
    case _Action.deny:
      return false;
    case _Action.verification:
      try {
        final req = await room.client.userDeviceKeys[room.directChatMatrixID]
            ?.startVerification();
        if (req == null) return false;
        if (!context.mounted) return false;
        final success = await KeyVerificationDialog(request: req).show(context);
        return success == true;
      } catch (error, stack) {
        if (context.mounted) {
          await ErrorReporter.action(context).onErrorCallback(error, stack);
        }
        return false;
      }
  }

  return true;
}

enum _Action { allow, deny, verification }

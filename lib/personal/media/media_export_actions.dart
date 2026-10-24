// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/personal/media/media_store.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Label of the one-tap save of [event]: "Save to gallery" / "Save to
/// Downloads" on Android (where it lands without a dialog), "Save…" where a
/// save panel opens.
String mediaSaveLabel(Event event, {bool? android}) {
  if (!(android ?? PlatformInfos.isAndroid)) return 'Save…';
  return MediaStore.collectionFor(
    mimeType: event.attachmentMimetype,
    name: event.content.tryGet<String>('filename') ?? event.body,
  ).actionLabel;
}

/// Whether a second "Save as…" (the system dialog) is offered next to the
/// one-tap save: only on Android, where the one-tap save has no dialog.
bool mediaOffersSaveAs({bool? android}) => android ?? PlatformInfos.isAndroid;

/// Message-menu entries that export [display]'s attachment, in Telegram's
/// order: save, save as, copy image. [context] must outlive the menu (the
/// chat page's context): the download dialog and the confirmation use it.
List<ConversationMessageAction> mediaExportMenuActions(
  BuildContext context,
  Event display, {
  required bool canSave,
}) => [
  if (canSave) ...[
    ConversationMessageAction(
      icon: Icons.download_outlined,
      label: mediaSaveLabel(display),
      onSelected: () => display.saveFile(context),
    ),
    if (mediaOffersSaveAs())
      ConversationMessageAction(
        icon: Icons.save_as_outlined,
        label: 'Save as…',
        onSelected: () => display.saveFileAs(context),
      ),
  ],
  if (display.canCopyImage)
    ConversationMessageAction(
      icon: Icons.copy_all_outlined,
      label: 'Copy image',
      onSelected: () => display.copyImage(context),
    ),
];

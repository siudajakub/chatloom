// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_notion_adaptive_dialog.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';

enum OkCancelResult { ok, cancel }

/// A question with Cancel and a confirming button, as a glass
/// [NotionDialog] on every platform. Return/Enter confirms while no button
/// has focus; a destructive confirmation never does.
Future<OkCancelResult?> showOkCancelAlertDialog({
  required BuildContext context,
  required String title,
  String? message,
  String? okLabel,
  String? cancelLabel,
  bool isDestructive = false,
  bool useRootNavigator = true,
}) => showNotionAdaptiveDialog<OkCancelResult>(
  context: context,
  useRootNavigator: useRootNavigator,
  builder: (context) {
    void ok() => Navigator.of(context).pop<OkCancelResult>(OkCancelResult.ok);
    final dialog = NotionDialog(
      title: title,
      content: message == null ? null : DialogMessage(message),
      actions: [
        NotionButton.ghost(
          key: const Key('ok_cancel_alert_dialog_cancel_button'),
          label: cancelLabel ?? L10n.of(context).cancel,
          onPressed: () =>
              Navigator.of(context).pop<OkCancelResult>(OkCancelResult.cancel),
        ),
        NotionButton(
          key: const Key('ok_cancel_alert_dialog_ok_button'),
          label: okLabel ?? L10n.of(context).ok,
          variant: isDestructive
              ? NotionButtonVariant.destructive
              : NotionButtonVariant.primary,
          onPressed: ok,
        ),
      ],
    );
    // Enter must not confirm a destructive action by accident.
    return isDestructive
        ? dialog
        : NotionDialogSubmit(onSubmit: ok, child: dialog);
  },
);

/// A notice with a single closing button, as a glass [NotionDialog].
Future<OkCancelResult?> showOkAlertDialog({
  required BuildContext context,
  required String title,
  String? message,
  String? okLabel,
  bool useRootNavigator = true,
}) => showNotionAdaptiveDialog<OkCancelResult>(
  context: context,
  useRootNavigator: useRootNavigator,
  builder: (context) {
    void ok() => Navigator.of(context).pop<OkCancelResult>(OkCancelResult.ok);
    return NotionDialogSubmit(
      onSubmit: ok,
      child: NotionDialog(
        title: title,
        content: message == null ? null : DialogMessage(message),
        actions: [
          NotionButton.primary(
            key: const Key('ok_alert_dialog_ok_button'),
            label: okLabel ?? L10n.of(context).close,
            onPressed: ok,
          ),
        ],
      ),
    );
  },
);

/// The body text of a dialog: muted callout, selectable, links open with
/// the [UrlLauncher]; scrolls when it is taller than the screen.
class DialogMessage extends StatelessWidget {
  final String text;
  const DialogMessage(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return SingleChildScrollView(
      child: SelectableLinkify(
        text: text,
        textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
        style: tokens.typography.calloutMuted,
        linkStyle: tokens.typography.callout.copyWith(
          color: tokens.colors.accent,
          decoration: TextDecoration.underline,
          decorationColor: tokens.colors.accent,
        ),
        options: const LinkifyOptions(humanize: false),
        onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
      ),
    );
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Source-room actions shared by the unified conversation overflow menu.
Future<void> performNotionRoomAction(
  BuildContext context,
  Room room,
  String action,
) async {
  switch (action) {
    case 'details':
      context.go('/rooms/${Uri.encodeComponent(room.id)}/details');
    case 'search':
      context.go('/rooms/${Uri.encodeComponent(room.id)}/search');
    case 'encryption':
      context.go('/rooms/${Uri.encodeComponent(room.id)}/encryption');
    case 'leave':
      final l10n = L10n.of(context);
      final router = GoRouter.of(context);
      final confirmed = await showOkCancelAlertDialog(
        context: context,
        title: l10n.areYouSure,
        message: l10n.archiveRoomDescription,
        okLabel: l10n.leave,
        cancelLabel: l10n.cancel,
        isDestructive: true,
      );
      if (confirmed != OkCancelResult.ok || !context.mounted) return;
      final result = await showFutureLoadingDialog(
        context: context,
        future: room.leave,
      );
      if (result.error == null) router.go('/rooms');
  }
}

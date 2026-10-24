// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// A list of choices in the dock's glass language: a bottom sheet of
/// [NotionGlassMenuRow]s on phones (Telegram's action sheet), a centred
/// glass dialog on desktop (macOS, Linux, Windows), where a sheet rising
/// from the bottom of a wide window is far from the pointer. Never a
/// Cupertino action sheet.
Future<T?> showModalActionPopup<T>({
  required BuildContext context,
  required List<AdaptiveModalAction<T>> actions,
  String? title,
  String? message,
  String? cancelLabel,
  bool useRootNavigator = true,
}) {
  final desktop = switch (Theme.of(context).platform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    _ => false,
  };
  if (desktop) {
    return showNotionCustomDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      builder: (context) => NotionDialogFrame(
        padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
        child: _ActionList<T>(
          title: title,
          message: message,
          cancelLabel: cancelLabel,
          actions: actions,
          entrance: false,
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    sheetAnimationStyle: NotionMotion.sheetStyleOf(context),
    isScrollControlled: true,
    useRootNavigator: useRootNavigator,
    context: context,
    // A glass sheet like the dock; rows keep rounded highlights inset
    // from its edges.
    backgroundColor: Colors.transparent,
    elevation: 0,
    shape: NotionShapes.sheet,
    constraints: BoxConstraints(
      maxWidth: 512,
      maxHeight: MediaQuery.sizeOf(context).height - NotionSpace.xxl,
    ),
    builder: (context) => NotionGlassPanel(
      borderRadius: NotionGlass.sheetRadius,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
          child: _ActionList<T>(
            title: title,
            message: message,
            cancelLabel: cancelLabel,
            actions: actions,
            entrance: true,
          ),
        ),
      ),
    ),
  );
}

class _ActionList<T> extends StatelessWidget {
  final String? title;
  final String? message;
  final String? cancelLabel;
  final List<AdaptiveModalAction<T>> actions;

  /// Rows rise in one after another while a sheet slides up; a dialog
  /// already scales in as a whole.
  final bool entrance;

  const _ActionList({
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.actions,
    required this.entrance,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final title = this.title;
    final message = this.message;
    final cancelLabel = this.cancelLabel;
    final children = <Widget>[
      if (title != null || message != null) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NotionSpace.md,
            NotionSpace.xs,
            NotionSpace.md,
            NotionSpace.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: tokens.typography.sectionLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (message != null) ...[
                if (title != null) const SizedBox(height: NotionSpace.xxs),
                Text(message, style: tokens.typography.footnoteMuted),
              ],
            ],
          ),
        ),
        const NotionGlassDivider(vertical: false),
      ],
      for (final action in actions)
        NotionGlassMenuRow(
          leading: action.icon == null
              ? null
              : IconTheme.merge(
                  data: IconThemeData(
                    color: action.isDestructive
                        ? tokens.colors.danger
                        : tokens.colors.text,
                  ),
                  child: action.icon!,
                ),
          title: action.label,
          style: NotionType.callout.copyWith(
            color: action.isDestructive ? tokens.colors.danger : null,
            fontWeight: action.isDefaultAction ? FontWeight.w600 : null,
          ),
          onTap: () => Navigator.of(context).pop<T>(action.value),
        ),
      if (cancelLabel != null) ...[
        const NotionGlassDivider(vertical: false),
        NotionGlassMenuRow(
          title: cancelLabel,
          style: NotionType.callout.copyWith(
            color: tokens.colors.textSecondary,
          ),
          onTap: () => Navigator.of(context).pop(null),
        ),
      ],
    ];
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: entrance
          ? NotionEntrance.stagger(afterRoute: false, children)
          : children,
    );
  }
}

class AdaptiveModalAction<T> {
  final String label;
  final T value;
  Icon? icon;
  final bool isDefaultAction;
  final bool isDestructive;

  AdaptiveModalAction({
    required this.label,
    required this.value,
    this.icon,
    this.isDefaultAction = false,
    this.isDestructive = false,
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_glass.dart';
import 'notion_tokens.dart';

/// The glass shell of every dialog: a `Dialog` without its own surface that
/// holds a [NotionGlassPanel] with [NotionGlass.dialogRadius] (blurred once
/// the [NotionDialogRoute] has settled). `NotionDialog`, [NotionAlertDialog]
/// and the loading dialog are built on it, so all of them look the same on
/// every platform (no Cupertino alert on macOS).
class NotionDialogFrame extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  const NotionDialogFrame({
    super.key,
    required this.child,
    this.padding = NotionSpace.dialog,
    this.maxWidth = NotionSize.dialogMaxWidth,
  });

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(NotionSpace.xl),
    backgroundColor: Colors.transparent,
    shape: const RoundedRectangleBorder(borderRadius: NotionGlass.dialogRadius),
    clipBehavior: Clip.none,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: NotionGlassPanel(
        borderRadius: NotionGlass.dialogRadius,
        padding: padding,
        child: child,
      ),
    ),
  );
}

/// `NotionDialog` with widget slots, the drop-in for `AlertDialog.adaptive`
/// in legacy dialogs whose title, content or actions are widgets (key
/// verification, permission level, push rule details). Title in `headline`,
/// content in `callout`, actions right-aligned and wrapping like
/// `NotionDialog`.
class NotionAlertDialog extends StatelessWidget {
  /// Shown centred above the title (a status glyph).
  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;

  const NotionAlertDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final actions = this.actions ?? const <Widget>[];
    return NotionDialogFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (icon != null) ...[
            Center(
              child: IconTheme.merge(
                data: IconThemeData(
                  size: NotionSize.avatar,
                  color: tokens.colors.text,
                ),
                child: icon!,
              ),
            ),
            const SizedBox(height: NotionSpace.sm),
          ],
          if (title != null)
            Semantics(
              header: true,
              child: DefaultTextStyle.merge(
                style: tokens.typography.headline,
                child: title!,
              ),
            ),
          if (content != null) ...[
            if (title != null || icon != null)
              const SizedBox(height: NotionSpace.md),
            Flexible(
              child: DefaultTextStyle.merge(
                style: tokens.typography.callout,
                child: content!,
              ),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: NotionSpace.xl),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: NotionSpace.xs,
              runSpacing: NotionSpace.xs,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// Return/Enter confirms a dialog while no control inside it has focus
/// (macOS and hardware keyboards), like the default button of a native
/// alert. A focused button or field keeps its own Enter.
class NotionDialogSubmit extends StatelessWidget {
  final VoidCallback onSubmit;
  final Widget child;

  const NotionDialogSubmit({
    super.key,
    required this.onSubmit,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent || !node.hasPrimaryFocus) {
        return KeyEventResult.ignored;
      }
      final key = event.logicalKey;
      if (key != LogicalKeyboardKey.enter &&
          key != LogicalKeyboardKey.numpadEnter) {
        return KeyEventResult.ignored;
      }
      onSubmit();
      return KeyEventResult.handled;
    },
    child: child,
  );
}

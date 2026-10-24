// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/ui/notion/notion.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

class AdaptiveDialogAction extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool autofocus;
  final Widget child;
  final bool bigButtons;
  final BorderRadius? borderRadius;
  final TargetPlatform? targetPlatform;

  const AdaptiveDialogAction({
    super.key,
    required this.onPressed,
    required this.child,
    this.autofocus = false,
    this.bigButtons = false,
    this.borderRadius,
    this.targetPlatform,
  });

  @override
  Widget build(BuildContext context) {
    // A dialog that still builds a Cupertino alert (owned by another
    // screen, not yet on `NotionAlertDialog`) keeps matching actions.
    if (context.findAncestorWidgetOfExactType<CupertinoAlertDialog>() != null) {
      return CupertinoDialogAction(
        onPressed: onPressed,
        isDefaultAction: autofocus,
        child: child,
      );
    }
    // Everywhere else the Notion buttons (pills from the theme) on every
    // platform: the default action filled, the others text-only; big
    // buttons stretch to the dialog width.
    const padding = EdgeInsets.symmetric(horizontal: NotionSpace.md);
    final minimumSize = Size(bigButtons ? double.infinity : 64, 40);
    final shape = borderRadius == null
        ? null
        : RoundedRectangleBorder(borderRadius: borderRadius!);
    final Widget button = autofocus
        ? FilledButton(
            onPressed: onPressed,
            autofocus: autofocus,
            style: FilledButton.styleFrom(
              padding: padding,
              minimumSize: minimumSize,
              shape: shape,
            ),
            child: child,
          )
        : bigButtons
        ? OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              padding: padding,
              minimumSize: minimumSize,
              shape: shape,
            ),
            child: child,
          )
        : TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              padding: padding,
              minimumSize: minimumSize,
              shape: shape,
            ),
            child: child,
          );
    return NotionPressable(
      enabled: onPressed != null,
      child: bigButtons
          ? Padding(
              padding: const EdgeInsets.symmetric(
                vertical: NotionSpace.xxs / 2,
              ),
              child: SizedBox(width: double.infinity, child: button),
            )
          : button,
    );
  }
}

class AdaptiveDialogInkWell extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  const AdaptiveDialogInkWell({
    super.key,
    required this.onTap,
    required this.child,
    this.padding = const EdgeInsets.all(NotionSpace.md),
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return NotionPressable(
      enabled: onTap != null,
      child: Material(
        color: onTap == null ? colors.background : colors.selected,
        borderRadius: NotionRadius.mdAll,
        child: InkWell(
          borderRadius: NotionRadius.mdAll,
          onTap: onTap,
          child: Padding(
            padding: padding,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class AdaptiveIconTextButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const AdaptiveIconTextButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = context.notion.colors.text;
    return Expanded(
      child: AdaptiveDialogInkWell(
        padding: const EdgeInsets.all(NotionSpace.xs),
        onTap: onTap,
        child: Column(
          mainAxisSize: .min,
          children: [
            Icon(icon, color: color),
            Text(
              label,
              style: NotionType.caption.copyWith(color: color),
              maxLines: 1,
              overflow: .ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

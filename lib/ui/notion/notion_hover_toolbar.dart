// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_tokens.dart';

/// One action of a [NotionHoverToolbar].
@immutable
class NotionHoverAction {
  final IconData icon;

  /// Tooltip and semantics label.
  final String label;
  final VoidCallback onPressed;
  const NotionHoverAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
}

/// The small toolbar a pointer shows beside a hovered message (Messenger
/// desktop, Telegram Desktop): a few icon actions in one opaque dock-tone
/// pill with the hairline. It sits next to scrolling content, so it never
/// blurs. Compact on purpose: it only exists for a mouse or trackpad, where
/// a 32 pt target is the platform norm (touch keeps the long-press menu).
/// Fades in over `quick` (instant under reduced motion) and settles to
/// identity; hiding is immediate.
class NotionHoverToolbar extends StatelessWidget {
  final List<NotionHoverAction> actions;
  const NotionHoverToolbar({super.key, required this.actions});

  /// Edge of one action button.
  static const double slot = 32;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final toolbar = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: NotionRadius.pillAll,
        border: Border.all(color: context.notion.glass.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(NotionSpace.xxs / 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              NotionPressable(
                scale: NotionMotion.pressIcon,
                child: Tooltip(
                  message: action.label,
                  child: Semantics(
                    button: true,
                    label: action.label,
                    excludeSemantics: true,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        customBorder: NotionShapes.pill,
                        onTap: action.onPressed,
                        child: SizedBox.square(
                          dimension: slot,
                          child: Icon(
                            action.icon,
                            size: NotionSize.iconSm + 2,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    final duration = NotionMotion.of(context, NotionMotion.quick);
    if (duration == Duration.zero) return toolbar;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: NotionMotion.standard,
      child: toolbar,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
    );
  }
}

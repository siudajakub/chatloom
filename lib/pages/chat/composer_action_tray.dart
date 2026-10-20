// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Builds an action that owns its own anchor, for example an attachment popup
/// menu. Call [used] once the action actually ran so the composer collapses.
typedef ComposerAnchorBuilder =
    Widget Function(BuildContext context, VoidCallback used);

/// One inline composer action. Presentation only: the caller owns what the
/// action does, its availability and its routing.
class ComposerAction {
  final IconData icon;

  /// Tooltip and semantics label; also the overflow menu text.
  final String label;

  /// Runs the action. Required for overflow use; null disables the action
  /// unless [anchor] renders its own control in the tray.
  final VoidCallback? onPressed;

  /// Replaces the default icon button in the tray (never in the overflow
  /// menu). Place anchored actions first so they keep a visible slot.
  final ComposerAnchorBuilder? anchor;

  /// Whether using the action collapses the tray.
  final bool collapseOnUse;

  /// Renders the toggle state of a mode switch.
  final bool selected;

  const ComposerAction({
    required this.icon,
    required this.label,
    this.onPressed,
    this.anchor,
    this.collapseOnUse = true,
    this.selected = false,
  });
}

/// Shared geometry and motion of the inline tray.
abstract final class ComposerTrayLayout {
  static const double slot = NotionSize.touchTarget;
  static const Duration duration = NotionMotion.medium;
  static const Curve curve = NotionMotion.emphasized;
  static const double slideDistance = 8;

  /// Share of the tray animation by which each further action starts later,
  /// so the actions pop in one after another.
  static const double itemStagger = .12;

  /// Start scale of an action while the tray opens.
  static const double itemFrom = .7;

  /// Narrowest editor while the tray is open. The tray collapses on the first
  /// typed character, so the editor only needs to stay recognisable.
  static const double expandedEditorMin = 32;

  /// How many actions are shown inline for [slots] available 48dp slots, and
  /// whether the remainder moves into a "More actions" overflow menu.
  static ({int visible, bool overflow}) fit(int count, int slots) {
    if (count <= slots) return (visible: count, overflow: false);
    return (visible: math.max(1, slots - 1), overflow: true);
  }

  static int slotsFor(int count, int slots) {
    final layout = fit(count, slots);
    return layout.visible + (layout.overflow ? 1 : 0);
  }
}

/// The always-present tray slot between "+" and the editor. Its width grows
/// from zero, so the editor narrows and slides instead of being replaced.
class ComposerActionTray extends StatelessWidget {
  final List<ComposerAction> actions;

  /// 0 = collapsed, 1 = open.
  final Animation<double> progress;

  /// Number of 48dp slots that fit next to the editor.
  final int slots;

  /// Hard upper bound of the tray width; never lets the row overflow.
  final double maxWidth;

  /// False while collapsed or collapsing: no hits and no semantics.
  final bool interactive;
  final bool reduceMotion;
  final ValueChanged<ComposerAction> onUsed;

  const ComposerActionTray({
    super.key,
    required this.actions,
    required this.progress,
    required this.slots,
    required this.maxWidth,
    required this.interactive,
    required this.onUsed,
    this.reduceMotion = false,
  });

  void _use(ComposerAction action) {
    if (action.collapseOnUse) onUsed(action);
    action.onPressed?.call();
  }

  Widget _item(BuildContext context, ComposerAction action) {
    final anchor = action.anchor;
    return SizedBox.square(
      dimension: ComposerTrayLayout.slot,
      child: anchor != null
          ? anchor(context, () {
              if (action.collapseOnUse) onUsed(action);
            })
          : NotionIconButton(
              icon: action.icon,
              label: action.label,
              selected: action.selected,
              onPressed: action.onPressed == null ? null : () => _use(action),
            ),
    );
  }

  /// Themed menu (`menuTheme`/`menuButtonTheme`), like the transcript menu.
  Widget _overflow(BuildContext context, List<ComposerAction> hidden) =>
      SizedBox.square(
        dimension: ComposerTrayLayout.slot,
        child: MenuAnchor(
          alignmentOffset: const Offset(0, NotionSpace.xxs),
          menuChildren: [
            for (final action in hidden)
              MenuItemButton(
                leadingIcon: Icon(action.icon, size: NotionSize.icon),
                // 48dp rows like the other composer targets.
                style: MenuItemButton.styleFrom(
                  minimumSize: const Size(0, NotionSize.touchTarget),
                ),
                onPressed: action.onPressed == null ? null : () => _use(action),
                child: Text(action.label),
              ),
          ],
          builder: (context, controller, _) => NotionIconButton(
            icon: Icons.more_horiz,
            label: 'More actions',
            selected: controller.isOpen,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final layout = ComposerTrayLayout.fit(actions.length, slots);
    final count = layout.visible + (layout.overflow ? 1 : 0);
    final natural = count * ComposerTrayLayout.slot;
    final content = math.min(natural, math.max(0.0, maxWidth));
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final items = [
      for (final action in actions.take(layout.visible)) _item(context, action),
      if (layout.overflow)
        _overflow(context, actions.skip(layout.visible).toList()),
    ];
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          reduceMotion
              ? items[i]
              : _TrayItem(progress: progress, index: i, child: items[i]),
      ],
    );
    return ExcludeSemantics(
      excluding: !interactive,
      child: IgnorePointer(
        ignoring: !interactive,
        child: AnimatedBuilder(
          animation: progress,
          child: FadeTransition(opacity: progress, child: row),
          builder: (context, child) {
            final t = progress.value.clamp(0.0, 1.0);
            final slide = reduceMotion
                ? 0.0
                : (1 - t) * ComposerTrayLayout.slideDistance * (rtl ? 1 : -1);
            return SizedBox(
              width: content * t,
              height: ComposerTrayLayout.slot,
              child: ClipRect(
                child: OverflowBox(
                  alignment: AlignmentDirectional.centerStart,
                  minWidth: natural,
                  maxWidth: natural,
                  child: Transform.translate(
                    offset: Offset(slide, 0),
                    child: child,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One tray action fading and scaling in slightly after the previous one,
/// driven by the tray's own progress (no controller of its own).
class _TrayItem extends AnimatedWidget {
  const _TrayItem({
    required Animation<double> progress,
    required this.index,
    required this.child,
  }) : super(listenable: progress);

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    final start = math.min(.5, index * ComposerTrayLayout.itemStagger);
    final local = ((t - start) / (1 - start)).clamp(0.0, 1.0);
    final scale =
        ComposerTrayLayout.itemFrom + (1 - ComposerTrayLayout.itemFrom) * local;
    return Opacity(
      opacity: local,
      child: Transform.scale(scale: scale, child: child),
    );
  }
}

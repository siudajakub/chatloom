// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_glass.dart';
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
/// desktop, Telegram Desktop): a few icon actions in one glass pill with the
/// hairline. It only exists for a mouse or trackpad (touch keeps the
/// long-press menu), floats in the overlay above the timeline and blurs
/// what scrolls beneath it.
///
/// Motion follows the glass rules (DESIGN.md "Glass"): the blur never fades
/// or scales. The glass grows out of the bubble-side edge
/// ([NotionGlassReveal]) while the icons fade in and the pill drifts
/// [drift] toward its place; [visible] false plays it back and then calls
/// [onHidden]. Reduced motion shows and hides it at once.
class NotionHoverToolbar extends StatefulWidget {
  final List<NotionHoverAction> actions;

  /// Whether the toolbar is shown; false plays the exit.
  final bool visible;

  /// The side facing the hovered bubble: the glass grows from it.
  final bool bubbleOnRight;

  /// Called once the exit has finished (at once under reduced motion).
  final VoidCallback? onHidden;

  const NotionHoverToolbar({
    super.key,
    required this.actions,
    this.visible = true,
    this.bubbleOnRight = false,
    this.onHidden,
  });

  /// Edge of one action button: roomier than the 32 pt desktop minimum so
  /// a pointer moving across never falls between two buttons.
  static const double slot = 36;

  /// How long the pointer may be off both the bubble and the toolbar
  /// before the toolbar starts to hide (crossing a gap, a diagonal path).
  static const Duration hideGrace = Duration(milliseconds: 180);

  /// Distance the pill travels toward its place on entrance.
  static const double drift = 4;

  @override
  State<NotionHoverToolbar> createState() => _NotionHoverToolbarState();
}

class _NotionHoverToolbarState extends State<NotionHoverToolbar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: NotionMotion.short,
    reverseDuration: NotionMotion.quick,
  )..addStatusListener(_status);
  late final CurvedAnimation _drift = CurvedAnimation(
    parent: _controller,
    curve: NotionMotion.standard,
  );
  Offset? _origin;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.value > 0) return;
    if (!widget.visible) return;
    if (NotionMotion.of(context, NotionMotion.short) == Duration.zero) {
      _controller.value = 1;
    } else {
      // The glass grows from the bubble-side edge, known after layout.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _measureOrigin();
        if (widget.visible) _controller.forward();
      });
    }
  }

  @override
  void didUpdateWidget(NotionHoverToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    final animate =
        NotionMotion.of(context, NotionMotion.short) != Duration.zero;
    if (widget.visible) {
      animate ? _controller.forward() : _controller.value = 1;
    } else if (animate && _controller.value > 0) {
      _controller.reverse();
    } else {
      _controller.value = 0;
      widget.onHidden?.call();
    }
  }

  void _measureOrigin() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = widget.bubbleOnRight
        ? box.size.centerRight(Offset.zero)
        : box.size.centerLeft(Offset.zero);
    setState(() => _origin = box.localToGlobal(local));
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.visible) {
      widget.onHidden?.call();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final row = Padding(
      padding: const EdgeInsets.all(NotionSpace.xxs / 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in widget.actions)
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
                        dimension: NotionHoverToolbar.slot,
                        child: Icon(
                          action.icon,
                          size: NotionSize.iconSm + 2,
                          color: tokens.colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    final glass = NotionGlassSurface(
      overlay: true,
      borderRadius: NotionRadius.pillAll,
      border: Border.all(color: tokens.glass.border),
      child: row,
    );
    final origin = _origin;
    final revealed = origin == null
        ? glass
        : NotionGlassReveal(
            animation: _controller,
            origin: origin,
            child: glass,
          );
    // Translation only: a moving blur stays a blur. Before the origin is
    // measured (the first frame) nothing is painted.
    final towardBubble = widget.bubbleOnRight ? 1.0 : -1.0;
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedBuilder(
        animation: _drift,
        child: revealed,
        builder: (context, child) => Visibility.maintain(
          visible: _controller.value > 0,
          child: Transform.translate(
            offset: Offset(
              towardBubble * NotionHoverToolbar.drift * (1 - _drift.value),
              0,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// One row of a composer menu, or a divider when [label] is null.
class ComposerMenuEntry<T> {
  final T? value;
  final IconData? icon;
  final String? label;

  const ComposerMenuEntry(T this.value, IconData this.icon, String this.label);
  const ComposerMenuEntry.divider() : value = null, icon = null, label = null;

  bool get isDivider => label == null;
}

/// A glass menu that grows out of a composer button ("+" or the send
/// button) and sits just above it, like the attach and send menus in
/// Telegram and Messenger. [alignEnd] lines the panel up with the anchor's
/// end edge (the send button) instead of its start edge (the "+").
///
/// Returns the chosen value, or null when dismissed (outside tap, Escape,
/// back).
Future<T?> showComposerMenu<T>(
  BuildContext anchorContext, {
  required List<ComposerMenuEntry<T>> entries,
  bool alignEnd = false,
  String? semanticLabel,
}) {
  final navigator = Navigator.of(anchorContext, rootNavigator: true);
  final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
  final box = anchorContext.findRenderObject() as RenderBox?;
  final window = overlay?.size ?? MediaQuery.sizeOf(anchorContext);
  final anchor = box == null || overlay == null || !box.hasSize
      ? Rect.fromLTWH(0, window.height, 0, 0)
      : box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final origin = Offset(anchor.center.dx, anchor.top);
  return showNotionPopover<T>(
    context: anchorContext,
    alignment: window.isEmpty
        ? (alignEnd ? Alignment.bottomRight : Alignment.bottomLeft)
        : Alignment(
            (origin.dx / window.width * 2 - 1).clamp(-1.0, 1.0),
            (origin.dy / window.height * 2 - 1).clamp(-1.0, 1.0),
          ),
    builder: (context) => LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final width = math.max(
          0.0,
          math.min(
            constraints.maxWidth - 2 * NotionSpace.md,
            scale > 1.4 ? 320.0 : 248.0,
          ),
        );
        final padding = MediaQuery.paddingOf(context);
        final top = padding.top + NotionSpace.md;
        final floor = constraints.maxHeight - padding.bottom - NotionSpace.md;
        // Above the button (the composer sits at the bottom); below it when
        // there is more room there.
        final above = anchor.top - NotionSpace.xs - top;
        final below = floor - anchor.bottom - NotionSpace.xs;
        final maxHeight = math.max(96.0, math.max(above, below));
        final start = alignEnd ? anchor.right - width : anchor.left;
        final left = start
            .clamp(
              NotionSpace.md,
              math.max(
                NotionSpace.md,
                constraints.maxWidth - width - NotionSpace.md,
              ),
            )
            .toDouble();
        return CustomSingleChildLayout(
          delegate: _ComposerMenuLayout(
            anchor: anchor,
            left: left,
            width: width,
            top: top,
            floor: floor,
            preferAbove: above >= below,
          ),
          child: Builder(
            builder: (context) => Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
              },
              child: Actions(
                actions: {
                  DismissIntent: CallbackAction<DismissIntent>(
                    onInvoke: (_) {
                      Navigator.of(context).pop();
                      return null;
                    },
                  ),
                },
                child: Focus(
                  autofocus: true,
                  child: Semantics(
                    container: true,
                    label: semanticLabel,
                    child: NotionGlassPanel(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxHeight),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            vertical: NotionSpace.xxs,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final entry in entries)
                                if (entry.isDivider)
                                  const NotionGlassDivider(vertical: false)
                                else
                                  NotionGlassMenuRow(
                                    key: ValueKey(
                                      'composer-menu-${entry.label}',
                                    ),
                                    leading: Icon(entry.icon),
                                    title: entry.label!,
                                    onTap: () =>
                                        Navigator.of(context).pop(entry.value),
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Places the menu above its anchor when it fits there (or there is more
/// room above), otherwise below; always inside the safe area.
class _ComposerMenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final double left, width, top, floor;
  final bool preferAbove;
  const _ComposerMenuLayout({
    required this.anchor,
    required this.left,
    required this.width,
    required this.top,
    required this.floor,
    required this.preferAbove,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(
        width: width,
      ).copyWith(maxHeight: math.max(0.0, floor - top));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final over = anchor.top - NotionSpace.xs - child.height;
    final under = anchor.bottom + NotionSpace.xs;
    final fitsAbove = over >= top;
    final fitsBelow = under + child.height <= floor;
    final y = fitsAbove && (preferAbove || !fitsBelow)
        ? over
        : fitsBelow
        ? under
        : over;
    return Offset(left, y.clamp(top, math.max(top, floor - child.height)));
  }

  @override
  bool shouldRelayout(_ComposerMenuLayout old) =>
      old.anchor != anchor ||
      old.left != left ||
      old.width != width ||
      old.top != top ||
      old.floor != floor ||
      old.preferAbove != preferAbove;
}

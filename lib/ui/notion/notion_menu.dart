// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'notion.dart' show NotionIconButton;
import 'notion_glass.dart';
import 'notion_modal_routes.dart';
import 'notion_tokens.dart';

/// One row of a [showNotionMenu], or a section divider.
@immutable
class NotionMenuEntry<T> {
  final T? value;
  final String? label;

  /// Leading icon; [leading] wins when both are set (e.g. an avatar).
  final IconData? icon;
  final Widget? leading;

  /// A second, muted line (a native language name, "Muted until 14:30").
  final String? subtitle;

  /// A disabled row stays visible and explains itself by its label.
  final bool enabled;

  /// Danger-coloured (Leave, Ban): still one tap, the caller confirms if the
  /// action is irreversible.
  final bool destructive;

  /// Highlighted with a check, for a single-choice list (a language).
  final bool selected;

  /// Finder key; defaults to `ValueKey('<keyPrefix>-<label>')`.
  final Key? key;
  final String? semanticsLabel;

  const NotionMenuEntry({
    required T this.value,
    required String this.label,
    this.icon,
    this.leading,
    this.subtitle,
    this.enabled = true,
    this.destructive = false,
    this.selected = false,
    this.key,
    this.semanticsLabel,
  });

  const NotionMenuEntry.divider()
    : value = null,
      label = null,
      icon = null,
      leading = null,
      subtitle = null,
      enabled = false,
      destructive = false,
      selected = false,
      key = null,
      semanticsLabel = null;

  bool get isDivider => label == null;
}

/// The app's one menu: a glass panel (`NotionGlassPanel` of
/// `NotionGlassMenuRow`s) that grows out of its anchor with the popover
/// reveal (`showNotionPopover`), the way the dock's network selector and
/// Telegram/Messenger menus open. Used for header ⋯ menus, overflow
/// buttons, the composer's attach/send menus and row menus; never a
/// Material `PopupMenuButton`/`MenuAnchor` (opaque, shadow, no reveal).
///
/// The anchor is [anchor] (global coordinates), else a click [position]
/// (desktop right click), else [anchorContext]'s own box. The panel sits
/// below the anchor when there is more room there (headers), above it
/// otherwise (the composer), always inside the safe area; on a phone and
/// on a desktop it is the same panel. [alignEnd] lines it up with the
/// anchor's end edge; null picks the edge nearer the screen side the anchor
/// is on. Escape, back and an outside tap dismiss it.
///
/// Returns the chosen value, or null when dismissed.
Future<T?> showNotionMenu<T>(
  BuildContext anchorContext, {
  required List<NotionMenuEntry<T>> entries,
  Rect? anchor,
  Offset? position,
  bool? alignEnd,
  String? semanticLabel,
  String keyPrefix = 'menu',
  double? width,
}) {
  final navigator = Navigator.of(anchorContext, rootNavigator: true);
  final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
  final window = overlay?.size ?? MediaQuery.sizeOf(anchorContext);
  final rect = _anchorRect(anchorContext, overlay, window, anchor, position);
  final end = alignEnd ?? rect.center.dx > window.width / 2;
  // The reveal grows from the edge the panel attaches to.
  final fromTop = rect.center.dy < window.height / 2;
  final origin = Offset(
    end ? rect.right : rect.left,
    fromTop ? rect.bottom : rect.top,
  );
  return showNotionPopover<T>(
    context: anchorContext,
    alignment: window.isEmpty
        ? (end ? Alignment.bottomRight : Alignment.bottomLeft)
        : Alignment(
            (origin.dx / window.width * 2 - 1).clamp(-1.0, 1.0),
            (origin.dy / window.height * 2 - 1).clamp(-1.0, 1.0),
          ),
    builder: (context) => LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final panelWidth = math.max(
          0.0,
          math.min(
            constraints.maxWidth - 2 * NotionSpace.md,
            width ?? (scale > 1.4 ? 320.0 : 248.0),
          ),
        );
        final padding = MediaQuery.paddingOf(context);
        final top = padding.top + NotionSpace.md;
        final floor = constraints.maxHeight - padding.bottom - NotionSpace.md;
        final above = rect.top - NotionSpace.xs - top;
        final below = floor - rect.bottom - NotionSpace.xs;
        final maxHeight = math.max(96.0, math.max(above, below));
        final start = end ? rect.right - panelWidth : rect.left;
        final left = start
            .clamp(
              NotionSpace.md,
              math.max(
                NotionSpace.md,
                constraints.maxWidth - panelWidth - NotionSpace.md,
              ),
            )
            .toDouble();
        return CustomSingleChildLayout(
          delegate: _NotionMenuLayout(
            anchor: rect,
            left: left,
            width: panelWidth,
            top: top,
            floor: floor,
            preferAbove: above >= below,
          ),
          child: _NotionMenuPanel<T>(
            entries: entries,
            maxHeight: maxHeight,
            semanticLabel: semanticLabel,
            keyPrefix: keyPrefix,
          ),
        );
      },
    ),
  );
}

Rect _anchorRect(
  BuildContext context,
  RenderBox? overlay,
  Size window,
  Rect? anchor,
  Offset? position,
) {
  Offset local(Offset global) =>
      overlay == null ? global : overlay.globalToLocal(global);
  if (anchor != null) {
    return local(anchor.topLeft) & anchor.size;
  }
  if (position != null) return local(position) & Size.zero;
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) {
    return Rect.fromLTWH(0, window.height, 0, 0);
  }
  return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
}

class _NotionMenuPanel<T> extends StatelessWidget {
  final List<NotionMenuEntry<T>> entries;
  final double maxHeight;
  final String? semanticLabel;
  final String keyPrefix;
  const _NotionMenuPanel({
    required this.entries,
    required this.maxHeight,
    required this.semanticLabel,
    required this.keyPrefix,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return Shortcuts(
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
            explicitChildNodes: true,
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
                          _row(context, entry, colors),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    NotionMenuEntry<T> entry,
    NotionColors colors,
  ) {
    final color = !entry.enabled
        ? colors.textTertiary
        : entry.destructive
        ? colors.danger
        : null;
    final leading =
        entry.leading ?? (entry.icon == null ? null : Icon(entry.icon));
    return NotionGlassMenuRow(
      key: entry.key ?? ValueKey('$keyPrefix-${entry.label}'),
      leading: leading == null
          ? null
          : IconTheme.merge(
              data: IconThemeData(color: color),
              child: leading,
            ),
      title: entry.label!,
      subtitle: entry.subtitle,
      semanticsLabel: entry.semanticsLabel,
      selected: entry.selected,
      style: color == null ? null : NotionType.callout.copyWith(color: color),
      trailing: entry.selected
          ? const Icon(Icons.check_rounded, size: NotionSize.iconSm)
          : null,
      onTap: entry.enabled
          ? () => Navigator.of(context).pop(entry.value)
          : null,
    );
  }
}

/// Places the menu above its anchor when it fits there and there is more
/// room above (the composer), otherwise below (headers); always inside the
/// safe area.
class _NotionMenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final double left, width, top, floor;
  final bool preferAbove;
  const _NotionMenuLayout({
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
  bool shouldRelayout(_NotionMenuLayout old) =>
      old.anchor != anchor ||
      old.left != left ||
      old.width != width ||
      old.top != top ||
      old.floor != floor ||
      old.preferAbove != preferAbove;
}

/// An icon button that opens a [showNotionMenu] anchored to itself and
/// shows its pressed (selected) state while the menu is open; the header ⋯
/// of conversations, the composer tray overflow, list-row menus.
///
/// [entries] is built when the menu opens, so it reflects current state.
class NotionMenuButton<T> extends StatefulWidget {
  final IconData icon;

  /// Tooltip and semantics label.
  final String label;
  final List<NotionMenuEntry<T>> Function() entries;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final bool? alignEnd;
  final String keyPrefix;

  const NotionMenuButton({
    super.key,
    required this.icon,
    required this.label,
    required this.entries,
    required this.onSelected,
    this.enabled = true,
    this.alignEnd,
    this.keyPrefix = 'menu',
  });

  @override
  State<NotionMenuButton<T>> createState() => _NotionMenuButtonState<T>();
}

class _NotionMenuButtonState<T> extends State<NotionMenuButton<T>> {
  bool _open = false;

  Future<void> _show() async {
    if (_open) return;
    setState(() => _open = true);
    final value = await showNotionMenu<T>(
      context,
      entries: widget.entries(),
      alignEnd: widget.alignEnd,
      semanticLabel: widget.label,
      keyPrefix: widget.keyPrefix,
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (value != null) widget.onSelected(value);
  }

  @override
  Widget build(BuildContext context) => NotionIconButton(
    icon: widget.icon,
    label: widget.label,
    selected: _open,
    onPressed: widget.enabled ? _show : null,
  );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_tokens.dart';

/// How [NotionGlassSurface] renders below a [NotionGlassScope].
enum NotionGlassMode {
  /// Glass when the renderer and accessibility settings allow it.
  auto,

  /// Always blur (goldens, previews).
  on,

  /// Always the solid fallback (low-end devices, diagnostics).
  off,
}

/// Overrides glass rendering for a subtree, e.g. a low-end device flag.
class NotionGlassScope extends InheritedWidget {
  final NotionGlassMode mode;

  const NotionGlassScope({super.key, required this.mode, required super.child});

  static NotionGlassMode modeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NotionGlassScope>()?.mode ??
      NotionGlassMode.auto;

  @override
  bool updateShouldNotify(NotionGlassScope oldWidget) => oldWidget.mode != mode;
}

/// Build-time kill switch: `--dart-define=PERSONAL_GLASS=false`.
const bool notionGlassBuildEnabled = bool.fromEnvironment(
  'PERSONAL_GLASS',
  defaultValue: true,
);

/// Whether glass may blur here. `auto` requires Impeller (the only renderer
/// where backdrop blur is cheap and shader filters are supported) and no
/// high-contrast / reduced-motion preference.
bool notionGlassEnabled(BuildContext context) {
  switch (NotionGlassScope.modeOf(context)) {
    case NotionGlassMode.on:
      return true;
    case NotionGlassMode.off:
      return false;
    case NotionGlassMode.auto:
      if (!notionGlassBuildEnabled || !ui.ImageFilter.isShaderFilterSupported) {
        return false;
      }
      return !MediaQuery.highContrastOf(context) &&
          !MediaQuery.disableAnimationsOf(context);
  }
}

/// The only glass primitive: a translucent, backdrop-blurred fill.
///
/// Use it for fixed chrome (header, floating dock, composer) above scrolling
/// content and, with [overlay], for menus, popovers, dialogs and sheets.
/// Without glass support it paints the same tint fully opaque, so layout and
/// contrast never depend on the blur. Never inside a scrolling list item.
///
/// Bars on one page share a single backdrop read when an ancestor
/// [BackdropGroup] exists ([BackdropFilter.grouped]).
class NotionGlassSurface extends StatelessWidget {
  final Widget child;

  /// Fill override (e.g. selection mode); defaults to [NotionGlass.tint],
  /// [NotionGlass.dockTint] or [NotionGlass.overlayTint].
  final Color? tint;

  /// Uses [NotionGlass.dockTint] instead of the bar tint.
  final bool dock;

  /// A modal surface (menu, popover, dialog, sheet): uses
  /// [NotionGlass.overlayTint] and blurs only once its route has settled.
  /// While the route animates (enter, exit, drag-to-dismiss) it paints the
  /// opaque fallback, so the blur is never animated and never sits inside the
  /// route's fade.
  final bool overlay;
  final BorderRadius borderRadius;

  /// Draws the glass hairline on these edges (all edges for the dock).
  final Border? border;
  final AlignmentGeometry? alignment;

  /// Isolates the surface in its own layer so content scrolling beneath
  /// re-composites the blur without repainting the surface's children.
  final bool repaintBoundary;

  const NotionGlassSurface({
    super.key,
    required this.child,
    this.tint,
    this.dock = false,
    this.overlay = false,
    this.borderRadius = BorderRadius.zero, // design-lint: allow full-bleed bars
    this.border,
    this.alignment,
    this.repaintBoundary = true,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = notionGlassEnabled(context);
    final surface = overlay && enabled
        ? _RouteSettled(builder: _paint)
        : _paint(context, enabled);
    return repaintBoundary ? RepaintBoundary(child: surface) : surface;
  }

  Widget _paint(BuildContext context, bool enabled) {
    final glass = context.notion.glass;
    final fill =
        tint ??
        (overlay
            ? glass.overlayTint
            : dock
            ? glass.dockTint
            : glass.tint);
    // BorderRadius.zero marks the full-bleed bars.
    final square = borderRadius == BorderRadius.zero; // design-lint: allow bars
    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: enabled ? fill : fill.withValues(alpha: 1),
        borderRadius: square ? null : borderRadius,
        border: border,
      ),
      child: alignment == null
          ? child
          : Align(alignment: alignment!, child: child),
    );
    if (!enabled) {
      // Still clip so ink splashes respect the rounded dock.
      return square
          ? surface
          : ClipRRect(borderRadius: borderRadius, child: surface);
    }
    surface = BackdropFilter.grouped(
      filter: ui.ImageFilter.blur(
        sigmaX: glass.blurSigma,
        sigmaY: glass.blurSigma,
        tileMode: TileMode.mirror,
      ),
      child: surface,
    );
    return square
        ? ClipRect(child: surface)
        : ClipRRect(borderRadius: borderRadius, child: surface);
  }
}

/// Rebuilds with `settled == true` only while the enclosing route's
/// animation is complete (no route: always settled). Listens to status
/// changes only, never to animation ticks.
class _RouteSettled extends StatefulWidget {
  final Widget Function(BuildContext context, bool settled) builder;
  const _RouteSettled({required this.builder});

  @override
  State<_RouteSettled> createState() => _RouteSettledState();
}

class _RouteSettledState extends State<_RouteSettled> {
  Animation<double>? _animation;
  bool _settled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _animation)) return;
    _animation?.removeStatusListener(_status);
    _animation = animation?..addStatusListener(_status);
    _settled = animation == null || animation.isCompleted;
  }

  void _status(AnimationStatus status) {
    final settled = status == AnimationStatus.completed;
    if (settled != _settled && mounted) setState(() => _settled = settled);
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_status);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _settled);
}

/// Rounded glass container with the dock's hairline: menus, popovers,
/// dialogs and sheet bodies. Hosts ink ([Material] transparency) so rows
/// inside it splash on the glass.
///
/// ```dart
/// NotionGlassPanel(child: Column(children: [for (final o in options) NotionGlassMenuRow(...)]))
/// ```
///
/// [overlay] (default) blurs only after the route settles. Pass
/// `blur: false` for a panel that sits inside scrolling content: it keeps
/// the radius, tint and hairline but never reads the backdrop.
class NotionGlassPanel extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final Color? tint;
  final bool overlay;
  final bool blur;

  const NotionGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = NotionGlass.panelRadius,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.overlay = true,
    this.blur = true,
  });

  @override
  Widget build(BuildContext context) {
    final glass = context.notion.glass;
    Widget panel = NotionGlassSurface(
      overlay: overlay,
      dock: !overlay,
      tint: tint,
      borderRadius: borderRadius,
      border: Border.all(color: glass.border),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(padding: padding, child: child),
      ),
    );
    if (!blur) {
      panel = NotionGlassScope(mode: NotionGlassMode.off, child: panel);
    }
    return panel;
  }
}

/// The dock's vertical hairline between two actions (1 × 36, inset 12).
/// `vertical: false` gives the inset horizontal hairline used between
/// sections of a glass menu.
class NotionGlassDivider extends StatelessWidget {
  final bool vertical;
  const NotionGlassDivider({super.key, this.vertical = true});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).dividerColor;
    if (!vertical) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NotionSpace.sm,
          vertical: NotionSpace.xxs,
        ),
        child: SizedBox(
          height: NotionSize.border,
          width: double.infinity,
          child: ColoredBox(color: color),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NotionSpace.sm),
      child: SizedBox(
        width: NotionSize.border,
        height: 36,
        child: ColoredBox(color: color),
      ),
    );
  }
}

/// One row of a glass menu (network selector, popovers): 48 pt high, inset
/// from the panel edge, with a rounded selected/pressed highlight instead of
/// a full-bleed rectangle.
class NotionGlassMenuRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final TextStyle? style;

  /// Announced instead of [title]; the row's content is one semantics node.
  final String? semanticsLabel;

  const NotionGlassMenuRow({
    super.key,
    required this.title,
    this.semanticsLabel,
    this.leading,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xxs + 2),
      child: Semantics(
        button: onTap != null,
        selected: selected,
        label: semanticsLabel ?? title,
        child: Material(
          color: selected ? colors.selected : Colors.transparent,
          shape: NotionShapes.row,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: NotionShapes.row,
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: NotionSize.touchTarget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NotionSpace.xs - 2,
                    vertical: NotionSpace.xs,
                  ),
                  child: Row(
                    children: [
                      if (leading != null) ...[
                        IconTheme.merge(
                          data: const IconThemeData(size: NotionSize.iconMd),
                          child: leading!,
                        ),
                        const SizedBox(width: NotionSpace.sm),
                      ],
                      Expanded(
                        child: Text(title, style: style ?? NotionType.callout),
                      ),
                      if (trailing != null) ...[
                        const SizedBox(width: NotionSpace.xs - 2),
                        trailing!,
                      ],
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
}

/// A floating glass pill button in the dock's language: icon (and optional
/// label) on the dock tint with the hairline, content presses with
/// [NotionPressable], ink clipped to the pill.
///
/// Blurs only when [blur] is true; keep it false unless the pill floats over
/// scrolling content as fixed chrome (scroll-to-bottom, a floating action).
class NotionGlassPill extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final VoidCallback? onPressed;

  /// Tooltip and semantics label for an icon-only pill.
  final String? tooltip;
  final bool selected;
  final bool blur;
  final Widget? trailing;

  const NotionGlassPill({
    super.key,
    this.icon,
    this.label,
    this.onPressed,
    this.tooltip,
    this.selected = false,
    this.blur = false,
    this.trailing,
  }) : assert(icon != null || label != null, 'Pass an icon or a label');

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final iconOnly = label == null;
    Widget content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: iconOnly ? NotionSpace.sm : NotionSpace.md,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) Icon(icon, size: NotionSize.iconLg),
          if (icon != null && label != null)
            const SizedBox(width: NotionSpace.xs),
          if (label != null)
            Flexible(
              child: Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NotionType.callout,
              ),
            ),
          if (trailing != null) ...[
            const SizedBox(width: NotionSpace.xxs + 2),
            trailing!,
          ],
        ],
      ),
    );
    content = InkWell(
      onTap: onPressed,
      customBorder: NotionShapes.pill,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: NotionSize.touchTarget,
          minWidth: NotionSize.touchTarget,
        ),
        // The content presses inside the ink, like the dock, so the pill
        // (and its blur) never scales.
        child: NotionPressable(
          enabled: onPressed != null,
          scale: iconOnly ? NotionMotion.pressIcon : NotionMotion.pressButton,
          child: Center(widthFactor: 1, child: content),
        ),
      ),
    );
    Widget pill = NotionGlassSurface(
      dock: true,
      tint: selected ? tokens.colors.selected : null,
      borderRadius: NotionGlass.dockRadius,
      border: Border.all(color: tokens.glass.border),
      child: Material(type: MaterialType.transparency, child: content),
    );
    if (!blur) {
      pill = NotionGlassScope(mode: NotionGlassMode.off, child: pill);
    }
    final tooltip = this.tooltip;
    if (tooltip != null) pill = Tooltip(message: tooltip, child: pill);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      selected: selected,
      label: iconOnly ? tooltip : null,
      child: pill,
    );
  }
}

/// Full-width glass bar: app bar background (`AppBar.flexibleSpace`) or the
/// composer strip. Pair with `extendBodyBehindAppBar: true` and add
/// `MediaQuery.paddingOf(context).top` to the scroll view's top padding.
class NotionGlassBar extends StatelessWidget {
  final Widget child;
  final Color? tint;
  final AlignmentGeometry? alignment;

  /// Hairline on the edge facing the content.
  final bool hairlineTop;
  final bool hairlineBottom;

  const NotionGlassBar({
    super.key,
    this.child = const SizedBox.expand(),
    this.tint,
    this.alignment,
    this.hairlineTop = false,
    this.hairlineBottom = false,
  });

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: context.notion.glass.border);
    return NotionGlassSurface(
      tint: tint,
      alignment: alignment,
      border: hairlineTop || hairlineBottom
          ? Border(
              top: hairlineTop ? side : BorderSide.none,
              bottom: hairlineBottom ? side : BorderSide.none,
            )
          : null,
      child: child,
    );
  }
}

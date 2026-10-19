// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

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
/// Use it exclusively for fixed chrome (header, floating dock, composer)
/// above scrolling content. Without glass support it paints the same tint
/// fully opaque, so layout and contrast never depend on the blur.
///
/// Bars on one page share a single backdrop read when an ancestor
/// [BackdropGroup] exists ([BackdropFilter.grouped]).
class NotionGlassSurface extends StatelessWidget {
  final Widget child;

  /// Fill override (e.g. selection mode); defaults to [NotionGlass.tint].
  final Color? tint;

  /// Uses [NotionGlass.dockTint] instead of the bar tint.
  final bool dock;
  final BorderRadius borderRadius;

  /// Draws the glass hairline on these edges (all edges for the dock).
  final Border? border;
  final AlignmentGeometry? alignment;

  const NotionGlassSurface({
    super.key,
    required this.child,
    this.tint,
    this.dock = false,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.alignment,
  });

  @override
  Widget build(BuildContext context) {
    final glass = context.notion.glass;
    final enabled = notionGlassEnabled(context);
    final fill = tint ?? (dock ? glass.dockTint : glass.tint);
    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: enabled ? fill : fill.withValues(alpha: 1),
        borderRadius: borderRadius == BorderRadius.zero ? null : borderRadius,
        border: border,
      ),
      child: alignment == null
          ? child
          : Align(alignment: alignment!, child: child),
    );
    if (!enabled) {
      // Still clip so ink splashes respect the rounded dock.
      return borderRadius == BorderRadius.zero
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
    return borderRadius == BorderRadius.zero
        ? ClipRect(child: surface)
        : ClipRRect(borderRadius: borderRadius, child: surface);
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

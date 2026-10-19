// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';

/// Dialog route with the Notion entrance: the barrier fades, the dialog
/// fades in while scaling up from 94 % on a critically damped spring curve,
/// and leaves faster (fade plus a small shrink). No blur.
///
/// Prefer `showNotionDialog` / `showNotionConfirmDialog`; use
/// [showNotionCustomDialog] for a custom dialog body.
class NotionDialogRoute<T> extends DialogRoute<T> {
  NotionDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
  });

  @override
  Duration get transitionDuration => NotionMotion.medium;

  @override
  Duration get reverseTransitionDuration => NotionMotion.quick;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => NotionDialogTransition(animation: animation, child: child);
}

/// Presents [builder] (usually a `NotionDialog` or a `Dialog`) in a
/// [NotionDialogRoute]. The drop-in for `showDialog`.
///
/// ```dart
/// final ok = await showNotionCustomDialog<bool>(
///   context: context,
///   builder: (context) => NotionDialog(title: 'Rename', content: field),
/// );
/// ```
Future<T?> showNotionCustomDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
  bool useSafeArea = true,
  RouteSettings? routeSettings,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final theme = Theme.of(context);
  return navigator.push<T>(
    NotionDialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          barrierColor ??
          theme.dialogTheme.barrierColor ??
          theme.colorScheme.scrim,
      barrierDismissible: barrierDismissible,
      useSafeArea: useSafeArea,
      settings: routeSettings,
    ),
  );
}

/// The dialog entrance as a widget, for `showGeneralDialog` /
/// `transitionBuilder` call sites that keep their own route.
class NotionDialogTransition extends StatefulWidget {
  const NotionDialogTransition({
    super.key,
    required this.animation,
    required this.child,
    this.from = NotionMotion.dialogFrom,
    this.alignment = Alignment.center,
  });

  final Animation<double> animation;
  final Widget child;

  /// Start scale ([NotionMotion.dialogFrom] or `popoverFrom`).
  final double from;

  /// Scale origin (the anchor of a popover).
  final Alignment alignment;

  @override
  State<NotionDialogTransition> createState() => _NotionDialogTransitionState();
}

class _NotionDialogTransitionState extends State<NotionDialogTransition> {
  late CurvedAnimation _fade;
  late CurvedAnimation _scale;

  @override
  void initState() {
    super.initState();
    _curves();
  }

  void _curves() {
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, .55, curve: NotionMotion.standard),
      reverseCurve: NotionMotion.exitFast,
    );
    _scale = CurvedAnimation(
      parent: widget.animation,
      curve: NotionMotion.smoothCurve,
      reverseCurve: NotionMotion.exitFast,
    );
  }

  @override
  void didUpdateWidget(NotionDialogTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animation, widget.animation)) {
      _fade.dispose();
      _scale.dispose();
      _curves();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = FadeTransition(opacity: _fade, child: widget.child);
    if (NotionMotion.reduced(context)) return fade;
    return AnimatedBuilder(
      animation: _scale,
      builder: (context, child) {
        // Leaving shrinks only a little; arriving grows from [from].
        final from = widget.animation.status == AnimationStatus.reverse
            ? 1 - (1 - widget.from) / 2
            : widget.from;
        return Transform.scale(
          scale: from + (1 - from) * _scale.value,
          alignment: widget.alignment,
          child: child,
        );
      },
      child: fade,
    );
  }
}

/// Anchored popover route (menus, the network selector): grows from
/// [alignment] (the corner nearest the anchor) with a quick spring and
/// leaves in [NotionMotion.instant].
class NotionPopoverRoute<T> extends RawDialogRoute<T> {
  NotionPopoverRoute({
    required WidgetBuilder builder,
    CapturedThemes? themes,
    this.alignment = Alignment.topRight,
    super.barrierDismissible = true,
    super.barrierColor = Colors.transparent,
    super.barrierLabel,
    super.settings,
  }) : super(
         pageBuilder: (context, animation, secondaryAnimation) {
           final child = Builder(builder: builder);
           return themes?.wrap(child) ?? child;
         },
         transitionDuration: NotionMotion.short,
       );

  /// Scale origin of the popover.
  final Alignment alignment;

  @override
  Duration get reverseTransitionDuration => NotionMotion.instant;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => NotionDialogTransition(
    animation: animation,
    from: NotionMotion.popoverFrom,
    alignment: alignment,
    child: child,
  );
}

/// Presents a popover built by [builder], which positions itself (for
/// example with `CustomSingleChildLayout` or `Align` around the anchor
/// rect). [alignment] is the scale origin.
///
/// ```dart
/// showNotionPopover<Network>(
///   context: context,
///   alignment: Alignment.bottomRight,
///   builder: (context) => _SelectorPanel(anchor: rect),
/// );
/// ```
Future<T?> showNotionPopover<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Alignment alignment = Alignment.topRight,
  bool barrierDismissible = true,
  Color barrierColor = Colors.transparent,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(
    NotionPopoverRoute<T>(
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      alignment: alignment,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      settings: routeSettings,
    ),
  );
}

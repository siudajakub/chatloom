// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Motion of the full-screen media viewer (Telegram/Messenger style): the
// photo flies out of its thumbnail, follows the finger when swiped away and
// flies back into the thumbnail when closed; a double tap zooms into the
// tapped point. Transform and opacity only; nothing runs at rest.
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_tokens.dart';

/// Transparent page route for a full-screen media viewer.
///
/// * A page route, so a [NotionMediaHero] in the viewer flies from the
///   thumbnail with the same tag (a dialog route never starts hero flights).
/// * The route itself draws nothing: the page reads [ModalRoute.animation]
///   for its backdrop and chrome ([NotionMediaBackdrop],
///   [NotionMediaChrome]), so the media is never inside a fading layer while
///   it flies.
/// * The page below stays where it is (no parallax or exit transition).
///
/// ```dart
/// Navigator.of(context, rootNavigator: true)
///     .push(NotionMediaRoute(builder: (_) => viewer));
/// ```
class NotionMediaRoute<T> extends PageRoute<T> {
  NotionMediaRoute({required this.builder, this.themes, super.settings});

  final WidgetBuilder builder;

  /// Themes captured from the opening context (`InheritedTheme.capture`).
  final CapturedThemes? themes;

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => NotionMotion.medium;

  @override
  Duration get reverseTransitionDuration => NotionMotion.reverse;

  /// The page below keeps still while the viewer covers it.
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  /// Share sheets and pickers opened from the viewer leave it in place.
  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final page = builder(context);
    return themes?.wrap(page) ?? page;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

/// The viewer's side of a shared-element flight: a [Hero] that keeps the
/// source thumbnail (already decoded) as the flying image, rounds its corners
/// from [sourceRadius] to square on the way in (and back on the way out), and
/// moves on a straight line with [NotionMotion.emphasized].
///
/// When nothing with the same tag is on the page below (the thumbnail scrolled
/// away, a source without a hero) or [tag] is null, the media fades and
/// scales in with the route instead. Under reduced motion there is no
/// flight, only the fade.
class NotionMediaHero extends StatelessWidget {
  const NotionMediaHero({
    super.key,
    required this.tag,
    required this.child,
    this.sourceRadius = NotionRadius.mdAll,
  });

  /// Null: no flight, only the route entrance.
  final Object? tag;
  final Widget child;

  /// Corner radius of the thumbnail the media flies from.
  final BorderRadius sourceRadius;

  /// Media in the viewer is full bleed: the flight squares the corners off.
  static const _fullBleed =
      BorderRadius.zero; // design-lint: allow full-bleed viewer media

  /// Straight flight path (the Material default arcs).
  static Tween<Rect?> rectTween(Rect? begin, Rect? end) =>
      RectTween(begin: begin, end: end);

  /// Builds the flying image from the hero that lives on the page below (the
  /// thumbnail), so the flight never waits for the full-size image.
  static HeroFlightShuttleBuilder shuttle(BorderRadius sourceRadius) =>
      (flightContext, animation, direction, fromHeroContext, toHeroContext) {
        final push = direction == HeroFlightDirection.push;
        final source = (push ? fromHeroContext : toHeroContext).widget as Hero;
        // The flight animation runs 0 → 1 from the start to the end hero.
        final from = push ? sourceRadius : _fullBleed;
        final to = push ? _fullBleed : sourceRadius;
        return AnimatedBuilder(
          animation: animation,
          child: source.child,
          builder: (context, child) => ClipRRect(
            borderRadius: BorderRadius.lerp(from, to, animation.value)!,
            child: child,
          ),
        );
      };

  @override
  Widget build(BuildContext context) {
    final tag = this.tag;
    if (tag == null) return _RouteMediaEntrance(child: child);
    final reduced = NotionMotion.reduced(context);
    return _RouteMediaEntrance(
      child: HeroMode(
        enabled: !reduced,
        child: Hero(
          tag: tag,
          curve: NotionMotion.emphasized,
          createRectTween: rectTween,
          flightShuttleBuilder: shuttle(sourceRadius),
          child: child,
        ),
      ),
    );
  }
}

/// Fallback entrance for media that has no hero to fly from: fade in and
/// scale up from [NotionMotion.dialogFrom] with the route. During a flight
/// the hero's own slot is hidden, so this never shows twice. Identity once
/// the route settled.
class _RouteMediaEntrance extends StatefulWidget {
  const _RouteMediaEntrance({required this.child});

  final Widget child;

  @override
  State<_RouteMediaEntrance> createState() => _RouteMediaEntranceState();
}

class _RouteMediaEntranceState extends State<_RouteMediaEntrance> {
  Animation<double>? _route;
  CurvedAnimation? _fade;
  CurvedAnimation? _scale;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (identical(route, _route)) return;
    _route = route;
    _fade?.dispose();
    _scale?.dispose();
    _fade = _scale = null;
    if (route == null) return;
    _fade = CurvedAnimation(
      parent: route,
      curve: const Interval(0, .6, curve: NotionMotion.standard),
      reverseCurve: NotionMotion.exitFast,
    );
    _scale = CurvedAnimation(
      parent: route,
      curve: NotionMotion.emphasized,
      reverseCurve: NotionMotion.exitFast,
    );
  }

  @override
  void dispose() {
    _fade?.dispose();
    _scale?.dispose();
    super.dispose();
  }

  static final _scaleTween = Tween<double>(begin: NotionMotion.dialogFrom, end: 1);

  @override
  Widget build(BuildContext context) {
    final fade = _fade;
    final scale = _scale;
    if (fade == null || scale == null) return widget.child;
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: _scaleTween.animate(scale),
        child: widget.child,
      ),
    );
  }
}

/// Drag-to-dismiss state of a full-screen viewer: the media follows the
/// finger vertically, the backdrop and chrome fade with [progress], and a
/// release either closes the viewer (past [distance] or flung faster than
/// [velocity] in the drag direction) or springs back to exactly 0
/// ([NotionMotion.snappy], keeping the release velocity).
///
/// Paint only: drive [NotionDismissTransform], [NotionMediaBackdrop] and
/// [NotionMediaChrome] with it; nothing rebuilds per frame.
class NotionDismissDrag {
  NotionDismissDrag({
    required TickerProvider vsync,
    this.distance = defaultDistance,
    this.velocity = defaultVelocity,
    this.fadeDistance = defaultFadeDistance,
  }) : _settle = AnimationController.unbounded(vsync: vsync) {
    _settle.addListener(() => offset.value = _settle.value);
  }

  /// Swipe distance (logical px) that closes the viewer.
  static const double defaultDistance = 120;

  /// Swipe speed (px/s) that closes the viewer from any distance.
  static const double defaultVelocity = 900;

  /// Distance over which the backdrop fades out completely.
  static const double defaultFadeDistance = 400;

  final double distance;
  final double velocity;
  final double fadeDistance;

  /// Vertical offset of the media (positive: down).
  final ValueNotifier<double> offset = ValueNotifier(0);
  final AnimationController _settle;
  bool _dragging = false;

  bool get dragging => _dragging;

  /// 0 at rest, 1 once dragged [fadeDistance] away.
  double get progress => (offset.value.abs() / fadeDistance).clamp(0.0, 1.0);

  void start() {
    _settle.stop();
    _dragging = true;
  }

  void update(double dy) {
    if (_dragging) offset.value += dy;
  }

  /// Ends the drag. True means "close now"; otherwise the media springs back.
  bool end(double velocityDy, {bool reduced = false}) {
    if (!_dragging) return false;
    _dragging = false;
    final travelled = offset.value;
    final flung =
        travelled != 0 &&
        velocityDy.abs() > velocity &&
        velocityDy.sign == travelled.sign;
    if (travelled.abs() > distance || flung) return true;
    springBack(velocity: velocityDy, reduced: reduced);
    return false;
  }

  /// Puts the media back (a pinch took over, or the drag was too short).
  void springBack({double velocity = 0, bool reduced = false}) {
    _dragging = false;
    if (reduced || offset.value == 0) {
      _settle.stop();
      offset.value = 0;
      return;
    }
    _settle
      ..value = offset.value
      ..animateWith(
        NotionMotion.springTo(
          NotionMotion.snappy,
          offset.value,
          0,
          velocity: velocity,
        ),
      );
  }

  void dispose() {
    _settle.dispose();
    offset.dispose();
  }
}

/// Moves [child] with a [NotionDismissDrag]: by the finger, and up to 15 %
/// smaller the further it travels. Identity at rest.
class NotionDismissTransform extends AnimatedWidget {
  NotionDismissTransform({
    super.key,
    required NotionDismissDrag drag,
    required this.child,
  }) : super(listenable: drag.offset);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final offset = (listenable as ValueNotifier<double>).value;
    if (offset == 0) return child;
    final height = MediaQuery.sizeOf(context).height;
    final shrink = height <= 0 ? 0.0 : (offset.abs() / height).clamp(0.0, 1.0);
    return Transform.translate(
      offset: Offset(0, offset),
      child: Transform.scale(scale: 1 - .15 * shrink, child: child),
    );
  }
}

/// The viewer backdrop: [color] that fades in with the route and out with a
/// dismiss drag. Paints one colour (no layer), behind a repaint boundary.
class NotionMediaBackdrop extends StatelessWidget {
  const NotionMediaBackdrop({
    super.key,
    required this.drag,
    this.color = NotionMediaColors.viewer,
  });

  final NotionDismissDrag drag;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([route, drag.offset]),
        builder: (context, _) {
          final t =
              NotionMotion.standard.transform(route.value.clamp(0.0, 1.0)) *
              (1 - drag.progress);
          return ColoredBox(color: color.withValues(alpha: color.a * t));
        },
      ),
    );
  }
}

/// Viewer chrome (top bar, arrows) that fades in with the route, hides
/// while the media is dragged away and toggles with [visible] (a tap on the
/// media, like Telegram). Ignores touches while hidden.
class NotionMediaChrome extends StatefulWidget {
  const NotionMediaChrome({
    super.key,
    required this.drag,
    required this.visible,
    required this.child,
  });

  final NotionDismissDrag drag;
  final bool visible;
  final Widget child;

  @override
  State<NotionMediaChrome> createState() => _NotionMediaChromeState();
}

class _NotionMediaChromeState extends State<NotionMediaChrome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: NotionMotion.short,
    reverseDuration: NotionMotion.quick,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(NotionMediaChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (NotionMotion.reduced(context)) {
      _shown.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _shown.forward();
    } else {
      _shown.reverse();
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
    return AnimatedBuilder(
      animation: Listenable.merge([route, _shown, widget.drag.offset]),
      child: widget.child,
      builder: (context, child) {
        final opacity =
            NotionMotion.standard.transform(route.value.clamp(0.0, 1.0)) *
            _shown.value *
            (1 - widget.drag.progress * 2.5).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: !widget.visible || widget.drag.offset.value != 0,
          child: Opacity(opacity: opacity, child: child),
        );
      },
    );
  }
}

/// Double-tap zoom for an `InteractiveViewer`: zooms to [scale] around the
/// tapped point, or back to fit when already zoomed, on
/// [NotionMotion.medium] / [NotionMotion.emphasized]. Ends exactly on the
/// target matrix; a new gesture stops it ([stop]).
class NotionDoubleTapZoom {
  NotionDoubleTapZoom({required TickerProvider vsync, this.scale = 2.5})
    : _controller = AnimationController(
        vsync: vsync,
        duration: NotionMotion.medium,
      ) {
    _curve = CurvedAnimation(
      parent: _controller,
      curve: NotionMotion.emphasized,
    );
    _controller
      ..addListener(_tick)
      ..addStatusListener(_status);
  }

  /// Zoom factor of a double tap.
  final double scale;
  final AnimationController _controller;
  late final CurvedAnimation _curve;
  TransformationController? _target;
  Matrix4Tween? _tween;

  /// True while [transform] is zoomed in beyond fit.
  static bool isZoomed(TransformationController transform) =>
      transform.value.getMaxScaleOnAxis() > 1.01;

  /// The matrix that zooms by [scale] while keeping [focal] (in the
  /// viewer's coordinates at fit) where it is.
  static Matrix4 zoomAt(Offset focal, double scale) =>
      Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(-focal.dx * (scale - 1), -focal.dy * (scale - 1), 0);

  void toggle(
    TransformationController transform,
    Offset focal, {
    bool reduced = false,
  }) {
    final end = isZoomed(transform) ? Matrix4.identity() : zoomAt(focal, scale);
    _controller.stop();
    if (reduced) {
      transform.value = end;
      return;
    }
    _target = transform;
    _tween = Matrix4Tween(begin: transform.value.clone(), end: end);
    _controller.forward(from: 0);
  }

  /// Leaves the matrix where it is (a pinch or pan started).
  void stop() {
    _controller.stop();
    _target = null;
  }

  void _tick() {
    final target = _target;
    final tween = _tween;
    if (target == null || tween == null) return;
    target.value = tween.evaluate(_curve);
  }

  void _status(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final target = _target;
    final end = _tween?.end;
    if (target != null && end != null) target.value = end.clone();
    _target = null;
  }

  void dispose() {
    _curve.dispose();
    _controller.dispose();
  }
}

/// Size of media with intrinsic [width] × [height] fitted (contained, also
/// scaled up) into [bounds]; null when the size is unknown. Gives a viewer
/// hero its final rectangle before the full image has loaded.
Size? notionFitMedia(num? width, num? height, Size bounds) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  if (!bounds.width.isFinite || !bounds.height.isFinite) return null;
  final scale = [
    bounds.width / width,
    bounds.height / height,
  ].reduce((a, b) => a < b ? a : b);
  return Size(width * scale, height * scale);
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// One motion vocabulary for the Notion UI: page navigation, durations,
/// curves, springs, press scales and modal styles.
///
/// Pages slide in from 8 % of the width with an emphasized fast-start curve
/// while fading in quickly; the page underneath drifts 6 % the other way and
/// dims under a light scrim, so a frame is never empty. Reduced motion keeps
/// only a short fade (or no animation for router pages, see
/// `lib/config/routes.dart`).
///
/// Taste: fast, decelerating, critically damped. Only small "reward"
/// elements (badges, reactions, the send button, empty-state icons) may use
/// [bouncy]. See DESIGN.md "Motion".
abstract final class NotionMotion {
  // ---------------------------------------------------------------- durations

  /// Press-down, exits of micro elements.
  static const Duration instant = Duration(milliseconds: 90);

  /// Icon swaps, colour tweens, selection.
  static const Duration quick = Duration(milliseconds: 140);

  /// Fades, badges, small reveals. `FluffyThemes.animationDuration`.
  static const Duration short = Duration(milliseconds: 200);

  /// Entrances, dialogs, size reveals.
  static const Duration medium = Duration(milliseconds: 260);

  /// Sheets and page pushes.
  static const Duration long = Duration(milliseconds: 320);

  /// Per-item interval of a staggered entrance.
  static const Duration stagger = Duration(milliseconds: 28);

  /// Never stagger more items than this; later items share the last delay.
  static const int staggerCap = 10;

  /// How long a loader stays invisible, so fast operations never flash one.
  static const Duration loaderGrace = Duration(milliseconds: 250);

  /// Total length of a [NotionRowHighlight] flash.
  static const Duration highlight = Duration(milliseconds: 900);

  /// Push duration. Short enough to feel immediate, long enough to read.
  static const Duration forward = long;

  /// Pop duration; exits feel faster than entrances.
  static const Duration reverse = Duration(milliseconds: 220);

  // ------------------------------------------------------------------- curves

  /// General UI tweens (colour, size, opacity). `FluffyThemes.animationCurve`.
  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Entrances, dialogs, sheets, page enter: very fast start, long landing.
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Exits: accelerate away.
  static const Curve exitFast = Cubic(0.3, 0.0, 0.8, 0.15);

  /// Page push curve.
  static const Curve enter = emphasized;

  /// Mirror of [enter] for pops: the page starts leaving at full speed.
  static const Curve exit = Curves.easeInCubic;

  // ------------------------------------------------------------------ springs

  /// Critically damped, quick: press release, toggles, small UI.
  static final SpringDescription snappy =
      SpringDescription.withDurationAndBounce(duration: _ms(240));

  /// Critically damped, unhurried: dialogs, sheets, popovers.
  static final SpringDescription smooth =
      SpringDescription.withDurationAndBounce(duration: _ms(360));

  /// Subtle overshoot. Only for badges, reactions, the send button and
  /// empty-state icons.
  static final SpringDescription bouncy =
      SpringDescription.withDurationAndBounce(duration: _ms(300), bounce: .22);

  /// Rest tolerance for UI springs: settles (and snaps exactly to the target)
  /// once the remaining motion is invisible.
  static const Tolerance springTolerance = Tolerance(
    distance: .001,
    velocity: .02,
  );

  /// Interruptible spring for `AnimationController.animateWith`, ending
  /// exactly on [to].
  static SpringSimulation springTo(
    SpringDescription spring,
    double from,
    double to, {
    double velocity = 0,
  }) => SpringSimulation(
    spring,
    from,
    to,
    velocity,
    tolerance: springTolerance,
    snapToEnd: true,
  );

  /// [snappy] as a time curve for tweens and switchers.
  static final NotionSpringCurve snappyCurve = NotionSpringCurve(snappy);

  /// [smooth] as a time curve.
  static final NotionSpringCurve smoothCurve = NotionSpringCurve(smooth);

  /// [bouncy] as a time curve (overshoots past 1.0).
  static final NotionSpringCurve bouncyCurve = NotionSpringCurve(bouncy);

  // ------------------------------------------------------- distances / scales

  /// Rise of a one-shot entrance, in logical pixels.
  static const double rise = 8;

  /// Rise of list rows in a staggered entrance.
  static const double riseList = 10;

  /// Rise of sheet content.
  static const double riseSheet = 12;

  /// Press scale of buttons.
  static const double pressButton = .96;

  /// Press scale of icon buttons and small glyphs.
  static const double pressIcon = .90;

  /// Press scale of list rows: barely there, but felt.
  static const double pressRow = .985;

  /// Start scale of a [NotionPop].
  static const double popFrom = .6;

  /// Start scale of a dialog.
  static const double dialogFrom = .94;

  /// Start scale of a popover or menu.
  static const double popoverFrom = .92;

  // ------------------------------------------------------------ route styles

  /// Bottom sheets (`showModalBottomSheet(sheetAnimationStyle: ...)`).
  static final AnimationStyle sheetStyle = AnimationStyle(
    duration: long,
    reverseDuration: reverse,
    curve: smoothCurve,
    reverseCurve: exitFast,
  );

  /// Popup menus (`showMenu`/`PopupMenuButton(popUpAnimationStyle: ...)`).
  static const AnimationStyle menuStyle = AnimationStyle(
    duration: short,
    reverseDuration: instant,
    curve: emphasized,
    reverseCurve: exitFast,
  );

  /// Sheet style honouring reduced motion (a quick plain slide).
  static AnimationStyle sheetStyleOf(BuildContext context) => reduced(context)
      ? const AnimationStyle(
          duration: quick,
          reverseDuration: instant,
          curve: standard,
        )
      : sheetStyle;

  /// [d], or zero under reduced motion.
  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;

  /// Delay of item [index] in a staggered entrance (capped).
  static Duration staggerFor(int index) => stagger * index.clamp(0, staggerCap);

  static Duration _ms(int ms) => Duration(milliseconds: ms);

  /// Horizontal start offset of an incoming page, as a fraction of the width.
  static const double incomingOffset = 0.08;

  /// Horizontal drift of the page underneath while another page covers it.
  static const double parallaxOffset = -0.06;

  /// Distance an outgoing page travels while it follows a back gesture.
  static const double gestureOffset = 0.3;

  /// Strength of the scrim over a covered page, relative to the theme scrim.
  static const double coveredScrim = 0.35;

  /// Fraction of the (curved) page animation over which a pushed page fades
  /// in. Short, so the translucent window over glass bars is brief.
  static const double pageFadeWindow = 0.35;

  /// Whether the user asked for less motion (Android "remove animations",
  /// iOS Reduce Motion). The single reduced-motion check for the whole app;
  /// depends only on the `disableAnimations` aspect of [MediaQuery].
  static bool reduced(BuildContext context) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
      WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .reduceMotion;

  /// Completes once the route that hosts [context], and every page route
  /// around it (a nested navigator's shell sliding in), has finished its
  /// entrance; immediately when nothing is animating in. Use it to start work
  /// that would otherwise land in the middle of a page transition: network
  /// refreshes, history pages, platform channel reads.
  ///
  /// Callers must re-check `mounted` after awaiting.
  static Future<void> routeSettled(BuildContext context) {
    final completer = Completer<void>();
    final binding = WidgetsBinding.instance;
    void check() {
      if (completer.isCompleted) return;
      final entering = context.mounted ? _entering(context) : null;
      if (entering == null) {
        completer.complete();
        return;
      }
      final animation = entering.animation;
      if (animation == null) {
        binding.addPostFrameCallback((_) => check());
        binding.ensureVisualUpdate();
        return;
      }
      late final AnimationStatusListener listener;
      listener = (status) {
        if (status == AnimationStatus.forward) return;
        animation.removeStatusListener(listener);
        check();
      };
      animation.addStatusListener(listener);
    }

    // ModalRoute.of may not be read during initState; check after the frame
    // that mounts the page, and make sure such a frame is coming.
    binding.addPostFrameCallback((_) => check());
    binding.ensureVisualUpdate();
    return completer.future;
  }

  /// Whether a page route around [context] is still entering.
  static bool isEntering(BuildContext context) => _entering(context) != null;

  /// The first page route around [context] that is still entering, or null.
  /// `animation` is the route animation to wait on, or null when the route
  /// is still offstage (its first frame, while heroes measure it: its
  /// animation then reads as completed) and the next frame must be awaited.
  ///
  /// Read from enclosing [NotionPageTransition]s, which (unlike
  /// [ModalRoute.of]) does not make the caller rebuild on route changes.
  static ({Animation<double>? animation})? _entering(BuildContext context) {
    ({Animation<double>? animation})? entering;
    var found = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is NotionPageTransition) {
        found = true;
        entering = _routeEntering(widget.route, widget.animation);
        if (entering != null) return false;
      }
      return true;
    });
    if (found) return entering;
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (route == null || animation == null) return null;
    return _routeEntering(route, animation);
  }

  static ({Animation<double>? animation})? _routeEntering(
    ModalRoute<dynamic> route,
    Animation<double> animation,
  ) {
    if (route.offstage) return (animation: null);
    if (animation.status == AnimationStatus.forward) {
      return (animation: animation);
    }
    return null;
  }

  /// Runs [action] after [routeSettled] when [context] is still mounted.
  static void afterRouteSettled(BuildContext context, VoidCallback action) {
    unawaited(
      routeSettled(context).then((_) {
        if (context.mounted) action();
      }),
    );
  }

  /// Like [afterRouteSettled], but runs [action] synchronously when no route
  /// around [context] is entering (or motion is reduced). Call it from
  /// `didChangeDependencies`, never from `initState`. Returns whether
  /// [action] already ran.
  static bool whenRouteSettled(BuildContext context, VoidCallback action) {
    if (reduced(context) || _entering(context) == null) {
      action();
      return true;
    }
    afterRouteSettled(context, action);
    return false;
  }
}

/// A [SpringDescription] as a time [Curve], for tweens, switchers and route
/// styles that take a curve. Use [duration] as the tween duration so the
/// spring is not cut short. For interruptible, velocity-preserving motion
/// drive an `AnimationController` with a `SpringSimulation` instead (see
/// `NotionPressable`).
class NotionSpringCurve extends Curve {
  NotionSpringCurve(this.spring, {this.tolerance = .001});

  final SpringDescription spring;

  /// Distance from the target (as a fraction of the travel) treated as rest.
  final double tolerance;

  late final SpringSimulation _simulation = SpringSimulation(spring, 0, 1, 0);
  late final double _settle = _settleTime();

  /// Natural length of the motion until it rests within [tolerance].
  Duration get duration => Duration(
    microseconds: (_settle * Duration.microsecondsPerSecond).round(),
  );

  double _settleTime() {
    const step = 1 / 240;
    var last = 0.0;
    for (var t = 0.0; t <= 4; t += step) {
      if ((_simulation.x(t) - 1).abs() > tolerance) last = t;
    }
    return last + step;
  }

  @override
  double transformInternal(double t) => _simulation.x(t * _settle);
}

/// Haptic feedback vocabulary. Only for send and long-press; screens decide.
abstract final class NotionHaptics {
  /// A light tick: message sent, long-press menu opened.
  static void light() => unawaited(HapticFeedback.lightImpact());

  /// Message sent.
  static void send() => light();

  /// Long-press recognised (context menu, reaction picker, drag start).
  static void longPress() => light();
}

/// Builds [child] only once the hosting route finished animating in, showing
/// [placeholder] before. Keeps expensive subtrees (platform calls, grids,
/// blurred images) out of the frames of a page transition.
class AfterRouteTransition extends StatefulWidget {
  const AfterRouteTransition({
    super.key,
    required this.child,
    this.placeholder = const SizedBox.shrink(),
  });

  final Widget child;
  final Widget placeholder;

  @override
  State<AfterRouteTransition> createState() => _AfterRouteTransitionState();
}

class _AfterRouteTransitionState extends State<AfterRouteTransition>
    with SingleTickerProviderStateMixin {
  Animation<double>? _animation;
  bool _ready = false;
  bool _started = false;

  /// Fades the child in when it replaced the placeholder; null when the
  /// child was ready on the first frame (no fade, no extra layer).
  AnimationController? _fade;
  CurvedAnimation? _fadeCurve;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready || _started) return;
    _started = true;
    _wait();
  }

  void _wait() {
    final entering = NotionMotion.reduced(context)
        ? null
        : NotionMotion._entering(context);
    if (entering == null) {
      _ready = true;
      return;
    }
    final animation = entering.animation;
    if (animation == null) {
      // Offstage first frame: look again after it.
      final binding = WidgetsBinding.instance;
      binding.addPostFrameCallback((_) => _recheck());
      binding.ensureVisualUpdate();
      return;
    }
    _animation = animation;
    animation.addStatusListener(_status);
  }

  void _recheck() {
    if (!mounted || _ready) return;
    _wait();
    if (_ready) {
      final fade = _fade = AnimationController(
        vsync: this,
        duration: NotionMotion.quick,
      )..forward();
      _fadeCurve = CurvedAnimation(parent: fade, curve: NotionMotion.standard);
      setState(() {});
    }
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.forward) return;
    _animation?.removeStatusListener(_status);
    _animation = null;
    _recheck();
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_status);
    _fadeCurve?.dispose();
    _fade?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return widget.placeholder;
    final fade = _fadeCurve;
    if (fade == null) return widget.child;
    return FadeTransition(opacity: fade, child: widget.child);
  }
}

/// The Notion page transition for Android, desktop and web.
///
/// Supports Android predictive back: the top page follows the back gesture
/// and the page underneath is revealed, then the gesture commits or cancels.
class NotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const NotionPageTransitionsBuilder();

  @override
  Duration get transitionDuration => NotionMotion.forward;

  @override
  Duration get reverseTransitionDuration => NotionMotion.reverse;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => NotionPageTransition(
    route: route,
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    child: child,
  );
}

/// Applies the Notion page motion to [child]. A route with a zero
/// [PageRoute.transitionDuration] is treated as instant: no visual change and
/// no gesture handling, with an unchanged widget structure so that switching
/// between instant and animated (for example when a window crosses the
/// two-column breakpoint) never remounts the page.
class NotionPageTransition extends StatefulWidget {
  const NotionPageTransition({
    super.key,
    required this.route,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<NotionPageTransition> createState() => _NotionPageTransitionState();
}

class _NotionPageTransitionState extends State<NotionPageTransition> {
  late CurvedAnimation _primary;
  late CurvedAnimation _secondary;

  PageRoute<dynamic> get route => widget.route;

  bool get instant {
    try {
      return route.navigator == null ||
          route.transitionDuration == Duration.zero;
    } catch (_) {
      return true;
    }
  }

  @override
  void initState() {
    super.initState();
    _curves();
    _NotionBackGestures.instance.add(this);
  }

  void _curves() {
    _primary = CurvedAnimation(
      parent: widget.animation,
      curve: NotionMotion.enter,
      reverseCurve: NotionMotion.exit,
    );
    _secondary = CurvedAnimation(
      parent: widget.secondaryAnimation,
      curve: NotionMotion.enter,
      reverseCurve: NotionMotion.exit,
    );
  }

  @override
  void didUpdateWidget(NotionPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animation, widget.animation) ||
        !identical(oldWidget.secondaryAnimation, widget.secondaryAnimation)) {
      _primary.dispose();
      _secondary.dispose();
      _curves();
    }
  }

  @override
  void dispose() {
    _NotionBackGestures.instance.remove(this);
    _primary.dispose();
    _secondary.dispose();
    super.dispose();
  }

  void gestureChanged() {
    if (mounted) setState(() {});
  }

  /// Linear while a finger drives the route; during the commit animation the
  /// framework restarts the controller from 1.0, so continue from the value
  /// the gesture was released at.
  double _gestureValue(double raw, double? commitFrom) {
    if (commitFrom == null) return raw;
    return commitFrom * (1 - Curves.easeOutCubic.transform(1 - raw));
  }

  @override
  Widget build(BuildContext context) {
    final navigator = route.navigator;
    final gesture = navigator?.userGestureInProgress ?? false;
    final commitFrom = gesture
        ? _NotionBackGestures.instance.commitFrom(navigator!)
        : null;
    final reduced = NotionMotion.reduced(context);
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    var dx = 0.0;
    var opacity = 1.0;
    var cover = 0.0;
    if (!instant) {
      final primary = gesture
          ? _gestureValue(widget.animation.value, commitFrom)
          : _primary.value;
      final secondary = gesture
          ? _gestureValue(widget.secondaryAnimation.value, commitFrom)
          : _secondary.value;
      if (reduced) {
        // A plain short fade: the emphasized page curve would make it a cut.
        final raw = gesture ? primary : widget.animation.value;
        opacity = (Curves.easeOut.transform(raw) / 0.4).clamp(0.0, 1.0);
      } else {
        opacity = (primary / NotionMotion.pageFadeWindow).clamp(0.0, 1.0);
        dx =
            (1 - primary) *
                (gesture
                    ? NotionMotion.gestureOffset
                    : NotionMotion.incomingOffset) +
            secondary * NotionMotion.parallaxOffset;
        cover = secondary;
      }
    }
    final scrim = Theme.of(context).colorScheme.scrim;
    return FractionalTranslation(
      translation: Offset(rtl ? -dx : dx, 0),
      child: Opacity(
        opacity: opacity,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            color: cover <= 0
                ? null
                : scrim.withValues(
                    alpha: scrim.a * NotionMotion.coveredScrim * cover,
                  ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Routes Android predictive back gestures to exactly one Notion page route.
///
/// Flutter calls every [WidgetsBindingObserver]; with nested navigators
/// (go_router shells) several routes are "current" at once. This picks the
/// deepest frontmost page, escalates from a first page to the page hosting
/// its navigator, and declines whenever something else (a dialog, sheet,
/// [PopScope] veto or instant route) should receive the back event, in which
/// case the framework falls back to an ordinary pop.
final class _NotionBackGestures with WidgetsBindingObserver {
  _NotionBackGestures._();
  static final instance = _NotionBackGestures._();

  final Set<_NotionPageTransitionState> _clients = {};
  _NotionPageTransitionState? _active;
  final Expando<double> _commitFrom = Expando();
  final Expando<bool> _committing = Expando();

  double? commitFrom(NavigatorState navigator) =>
      _committing[navigator] == true ? _commitFrom[navigator] : null;

  void add(_NotionPageTransitionState client) {
    if (_clients.isEmpty) WidgetsBinding.instance.addObserver(this);
    _clients.add(client);
  }

  void remove(_NotionPageTransitionState client) {
    _clients.remove(client);
    if (identical(_active, client)) _active = null;
    if (_clients.isEmpty) WidgetsBinding.instance.removeObserver(this);
  }

  List<_NotionPageTransitionState> _ancestors(_NotionPageTransitionState c) {
    final result = <_NotionPageTransitionState>[];
    c.context.visitAncestorElements((element) {
      if (element is StatefulElement &&
          element.state is _NotionPageTransitionState) {
        result.add(element.state as _NotionPageTransitionState);
      }
      return true;
    });
    return result;
  }

  bool _current(_NotionPageTransitionState c) {
    try {
      return c.mounted && c.route.isCurrent;
    } catch (_) {
      return false;
    }
  }

  _NotionPageTransitionState? _pick() {
    final clients = _clients.where((c) => c.mounted).toList();
    final ancestors = {for (final c in clients) c: _ancestors(c)};
    _NotionPageTransitionState? best;
    for (final c in clients) {
      if (!_current(c) || !ancestors[c]!.every(_current)) continue;
      if (best == null || ancestors[c]!.length > ancestors[best]!.length) {
        best = c;
      }
    }
    if (best == null) return null;
    // Something registered lives inside the chosen page but is not
    // frontmost: its navigator shows a dialog or another route on top.
    final chosen = best;
    if (clients.any((c) => ancestors[c]!.contains(chosen))) return null;
    var target = chosen;
    while (true) {
      if (target.instant) return null;
      final route = target.route;
      if (route.popGestureEnabled) return target;
      // A first page bubbles the back event to the page hosting its
      // navigator, unless it vetoes or handles the pop itself.
      if (!route.isFirst ||
          route.willHandlePopInternally ||
          route.popDisposition != RoutePopDisposition.bubble) {
        return null;
      }
      final parents = ancestors[target]!;
      if (parents.isEmpty) return null;
      target = parents.first;
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    _active = null;
    if (backEvent.isButtonEvent) return false;
    final target = _pick();
    if (target == null) return false;
    final navigator = target.route.navigator;
    if (navigator == null) return false;
    _committing[navigator] = null;
    _commitFrom[navigator] = null;
    _active = target;
    target.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    target.gestureChanged();
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    final target = _active;
    if (target == null || !target.mounted) return;
    target.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() {
    final target = _active;
    _active = null;
    if (target == null || !target.mounted) return;
    target.route.handleCancelBackGesture();
    target.gestureChanged();
  }

  @override
  void handleCommitBackGesture() {
    final target = _active;
    _active = null;
    if (target == null || !target.mounted) return;
    final navigator = target.route.navigator;
    if (navigator != null) {
      _commitFrom[navigator] = target.route.animation?.value ?? 1;
      _committing[navigator] = true;
    }
    target.route.handleCommitBackGesture();
    target.gestureChanged();
  }
}

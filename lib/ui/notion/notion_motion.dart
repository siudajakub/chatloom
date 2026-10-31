// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_activity.dart';
import 'notion_display_preferences.dart';

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

  /// Fades, badges, small reveals. `ChatLoomThemes.animationDuration`.
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

  /// Longest time a spinner or a content loop (shimmer, typing dots) keeps
  /// animating; then it rests on a static frame, so a wait that never ends
  /// (failed media, an offline worker) stops drawing frames.
  static const Duration loopCap = Duration(seconds: 30);

  /// Longest time a live-state loop ([NotionPulse]: recording, a ringing
  /// call) keeps animating before it rests.
  static const Duration liveLoopCap = Duration(minutes: 2);

  /// Repetitions of a loop of [period] that fit in [cap] (at least one).
  static int loopCount(Duration period, {Duration cap = loopCap}) =>
      period <= Duration.zero
      ? 1
      : (cap.inMicroseconds / period.inMicroseconds).ceil().clamp(1, 1 << 20);

  /// Total length of a [NotionRowHighlight] flash.
  static const Duration highlight = Duration(milliseconds: 900);

  /// Push duration. Short enough to feel immediate, long enough to read.
  static const Duration forward = long;

  /// Pop duration; exits feel faster than entrances.
  static const Duration reverse = Duration(milliseconds: 220);

  // ------------------------------------------------------------------- curves

  /// General UI tweens (colour, size, opacity). `ChatLoomThemes.animationCurve`.
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

  /// Opacity a refreshed list (another view or network) fades in from: a
  /// cue that the content changed, never a frame without content (an empty
  /// frame flashed the bare page through the glass header and dock).
  static const double refreshFrom = .5;

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

  /// Menu style honouring reduced motion (a near-instant fade instead of the
  /// emphasized grow).
  static AnimationStyle menuStyleOf(BuildContext context) => reduced(context)
      ? const AnimationStyle(
          duration: instant,
          reverseDuration: instant,
          curve: standard,
        )
      : menuStyle;

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

  /// Distance an outgoing page travels per unit of Android back progress:
  /// 1.0 follows the finger across the width (Telegram style), see
  /// [NotionPageTransition].
  static const double gestureTravel = 1.0;

  /// Curve of the rest of a committed back gesture: leaves at about twice
  /// the average speed and decelerates, so the release never stalls or
  /// jumps.
  static const Curve gestureCommit = Curves.easeOutQuad;

  /// Strength of the scrim over a covered page, relative to the theme scrim.
  static const double coveredScrim = 0.35;

  /// Fraction of the (curved) page animation over which a pushed page fades
  /// in. Short, so the translucent window over glass bars is brief.
  static const double pageFadeWindow = 0.35;

  /// Whether the user asked for less motion (Android "remove animations",
  /// iOS Reduce Motion), or the app is not in front of the user
  /// ([NotionActivity]: another app has focus, the window is hidden). The
  /// single reduced-motion check for the whole app; depends only on the
  /// `disableAnimations` aspect of [MediaQuery] and on [NotionActivity].
  static bool reduced(BuildContext context) =>
      NotionDisplayPreferences.of(context).reduceMotion ||
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
      WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .reduceMotion ||
      !NotionActivity.isActive(context) ||
      NotionActivity.isPowerSaving(context);

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

/// Haptic feedback vocabulary. Only for send, long-press and scrubbing;
/// screens decide.
///
/// On Android the vocabulary follows Facebook Messenger: a crisp click on
/// send, the system long-press buzz (`HapticFeedbackConstants.LONG_PRESS`, a
/// heavy click) when a hold is recognised or a recording starts, and a crisp
/// tick per choice while the finger scrubs. Other platforms keep the
/// original light / medium impacts and selection clicks.
abstract final class NotionHaptics {
  /// Settings → Appearance → Haptic feedback; set by `ThemeController`.
  static bool enabled = true;

  static bool get _android => defaultTargetPlatform == TargetPlatform.android;

  /// A light tick: message sent, a double-tap like, unlock. Android:
  /// `VIRTUAL_KEY` (a click).
  static void light() {
    if (enabled) unawaited(HapticFeedback.lightImpact());
  }

  /// Message sent.
  static void send() => light();

  /// Long-press recognised (context menu, reaction picker, drag start).
  /// Android: the system long-press buzz, Messenger's.
  static void longPress() {
    if (!enabled) return;
    unawaited(
      _android ? HapticFeedback.vibrate() : HapticFeedback.lightImpact(),
    );
  }

  /// A voice/round recording started (the hold became a recording).
  /// Android: the same long-press buzz; elsewhere a medium impact.
  static void recordStart() {
    if (!enabled) return;
    unawaited(
      _android ? HapticFeedback.vibrate() : HapticFeedback.mediumImpact(),
    );
  }

  /// A selection tick: the finger moved onto another choice while scrubbing
  /// (reaction bar, swipe-to-reply arming). Fires once per change, never per
  /// frame.
  static void selection() {
    if (!enabled) return;
    // Android: `heavyImpact` is a misleading name here. The engine maps it to
    // `HapticFeedbackConstants.CONTEXT_CLICK` (EFFECT_TICK), a short crisp
    // tick, whereas `selectionClick` maps to `CLOCK_TICK`, a texture tick
    // that many devices barely render.
    unawaited(
      _android ? HapticFeedback.heavyImpact() : HapticFeedback.selectionClick(),
    );
  }
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
/// Supports Android predictive back (Telegram style): the top page follows
/// the finger across the width while the page underneath slides back into
/// place from its parallax offset and its scrim lifts. Releasing past the
/// system threshold lets the page continue from where the finger left it and
/// leave the screen ([NotionMotion.gestureCommit]); cancelling (the system
/// first animates the progress back to zero) returns it to rest. Neither
/// path ever jumps, and the page underneath never moves past its rest.
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

  @override
  Widget build(BuildContext context) {
    final navigator = route.navigator;
    final gesture = (navigator?.userGestureInProgress ?? false)
        ? _NotionBackGestures.instance.gestureOf(navigator!)
        : null;
    final reduced = NotionMotion.reduced(context);
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    var dx = 0.0;
    var opacity = 1.0;
    var cover = 0.0;
    if (!instant && gesture != null) {
      // The finger drives exactly one route: this page when it is the one
      // being dragged, or the page right underneath it through its
      // secondary animation. Everything else stays at rest.
      final own = identical(gesture.route, route);
      final primary = own
          ? gesture.value(widget.animation)
          : widget.animation.value;
      final secondary = gesture.value(widget.secondaryAnimation);
      if (reduced) {
        opacity = (Curves.easeOut.transform(primary) / 0.4).clamp(0.0, 1.0);
      } else {
        // Physical direction: towards the edge the finger moves to.
        dx =
            gesture.direction *
            ((1 - primary) * NotionMotion.gestureTravel +
                secondary * NotionMotion.parallaxOffset);
        cover = secondary;
      }
    } else if (!instant) {
      if (reduced) {
        // A plain short fade: the emphasized page curve would make it a cut.
        opacity = (Curves.easeOut.transform(widget.animation.value) / 0.4)
            .clamp(0.0, 1.0);
      } else {
        final primary = _primary.value;
        final secondary = _secondary.value;
        opacity = (primary / NotionMotion.pageFadeWindow).clamp(0.0, 1.0);
        final logical =
            (1 - primary) * NotionMotion.incomingOffset +
            secondary * NotionMotion.parallaxOffset;
        dx = rtl ? -logical : logical;
        cover = secondary;
      }
    }
    final scrim = Theme.of(context).colorScheme.scrim;
    return FractionalTranslation(
      translation: Offset(dx, 0),
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

/// One predictive back gesture of a navigator, read by its Notion pages.
final class _BackGesture {
  _BackGesture(this.route, this.direction);

  /// The page the finger drags.
  final PageRoute<dynamic> route;

  /// +1 when the page leaves to the right (swipe from the left edge), -1 to
  /// the left (swipe from the right edge).
  final double direction;

  /// The route animation value at release, while the commit runs.
  double? commitFrom;

  /// The visible value of [animation] (the dragged route's animation, or the
  /// secondary animation of the page underneath, which proxies it).
  ///
  /// While the finger is down the framework sets the controller directly,
  /// so the value is used as is. On commit the framework pops the route and
  /// restarts its controller from 1.0 (`reverse(from: upperBound)`); that
  /// restart is remapped to continue from [commitFrom]. Only an animation
  /// that runs in reverse is driven by the commit; a page further down (its
  /// secondary animation completed) and the page underneath's own primary
  /// animation keep their values. Applying the remap to those made the page
  /// underneath jump past its rest and snap back when the pop finished.
  double value(Animation<double> animation) {
    final raw = animation.value;
    final from = commitFrom;
    if (from == null || animation.status != AnimationStatus.reverse) {
      return raw;
    }
    return from * (1 - NotionMotion.gestureCommit.transform(1 - raw));
  }
}

/// Routes Android predictive back gestures to exactly one Notion page route.
///
/// Flutter calls every [WidgetsBindingObserver]; with nested navigators
/// (go_router shells) several routes are "current" at once. This picks the
/// deepest frontmost page, escalates from a first page to the page hosting
/// its navigator, and declines whenever something else (a dialog, sheet,
/// [PopScope] veto or instant route) should receive the back event, in which
/// case the framework falls back to an ordinary pop on release: a sheet or
/// dialog closes with its own motion, a [PopScope] with `canPop: false` gets
/// its callback and nothing moves while the finger is down.
final class _NotionBackGestures with WidgetsBindingObserver {
  _NotionBackGestures._();
  static final instance = _NotionBackGestures._();

  final Set<_NotionPageTransitionState> _clients = {};
  _NotionPageTransitionState? _active;
  final Expando<_BackGesture> _gestures = Expando('Notion back gesture');

  _BackGesture? gestureOf(NavigatorState navigator) => _gestures[navigator];

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
    _gestures[navigator] = _BackGesture(
      target.route,
      backEvent.swipeEdge == SwipeEdge.right ? -1 : 1,
    );
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
    final navigator = target.route.navigator;
    if (navigator != null) _gestures[navigator]?.commitFrom = null;
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
      _gestures[navigator]?.commitFrom = target.route.animation?.value ?? 1;
    }
    target.route.handleCommitBackGesture();
    target.gestureChanged();
  }
}

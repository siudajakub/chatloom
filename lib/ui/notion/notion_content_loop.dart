// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/widgets.dart';

import 'notion_motion.dart';

/// Visibility rules of content loops (animated stickers, GIF images, Lottie,
/// inline GIF videos): DESIGN.md motion rule 4, Telegram's per-cell
/// `setVisibleOnScreen`. A loop plays only while at least [visibleFraction]
/// of it is inside its scroll viewport and the screen.
abstract final class NotionContentLoop {
  /// Share of the frame that must be visible to play.
  static const double visibleFraction = .5;

  /// The share (0–1) of [box] inside the nearest viewport and [screen]
  /// (global coordinates). 0 for a box without size or not attached.
  static double visibleShare(RenderBox box, Size screen) {
    if (!box.attached || !box.hasSize) return 0;
    final bounds = box.localToGlobal(Offset.zero) & box.size;
    if (bounds.width <= 0 || bounds.height <= 0) return 0;
    var viewportBounds = Offset.zero & screen;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is RenderBox) {
      final viewportBox = viewport as RenderBox;
      if (viewportBox.hasSize) {
        viewportBounds = viewportBounds.intersect(
          viewportBox.localToGlobal(Offset.zero) & viewportBox.size,
        );
      }
    }
    final overlap = bounds.intersect(viewportBounds);
    if (overlap.isEmpty || overlap.width <= 0 || overlap.height <= 0) {
      return 0;
    }
    return (overlap.width * overlap.height / (bounds.width * bounds.height))
        .clamp(0.0, 1.0);
  }

  /// Whether [box] is visible enough to play ([visibleFraction]).
  static bool isVisible(
    RenderBox box,
    Size screen, {
    double fraction = visibleFraction,
  }) => visibleShare(box, screen) >= fraction;
}

/// Lets [child]'s animation (an animated `Image`, a `Lottie`, anything
/// driven by tickers) run only while it is on screen.
///
/// It wraps [child] in a [TickerMode] that is on only when
/// - [enabled] (the caller's policy, e.g. the "autoplay" setting),
/// - the ancestors' tickers are on (hidden tabs, offstage routes),
/// - motion is not reduced ([NotionMotion.reduced]: the OS setting, or the
///   app is not in front), and
/// - at least [NotionContentLoop.visibleFraction] of it is visible, checked
///   after layout and after scroll changes of the nearest [Scrollable]
///   (coalesced to one check per frame).
///
/// A multi-frame `Image` stops its frame stream and keeps the last frame; a
/// muted `Lottie` stops on its frame. Both schedule no frames while gated.
/// Nothing is listened to while the loop cannot play anyway, so static
/// grids (tickers off) cost nothing.
///
/// Children must not rely on tickers to become visible (a fade-in would stay
/// at its start while gated): show the first frame directly.
class NotionContentLoopGate extends StatefulWidget {
  const NotionContentLoopGate({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;

  /// The caller allows the loop at all.
  final bool enabled;

  @override
  State<NotionContentLoopGate> createState() => _NotionContentLoopGateState();
}

class _NotionContentLoopGateState extends State<NotionContentLoopGate> {
  bool _visible = false;
  bool _scheduled = false;
  bool _ancestorTickers = true;
  bool _reduced = false;
  Size _screen = Size.zero;
  ScrollPosition? _position;

  bool get _wanted => widget.enabled && _ancestorTickers && !_reduced;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ancestorTickers = TickerMode.valuesOf(context).enabled;
    _reduced = NotionMotion.reduced(context);
    _screen = MediaQuery.sizeOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(NotionContentLoopGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// Listens to the scroll position only while the loop may play.
  void _sync() {
    final position = _wanted ? Scrollable.maybeOf(context)?.position : null;
    if (!identical(position, _position)) {
      _position?.removeListener(_schedule);
      _position = position;
      position?.addListener(_schedule);
    }
    if (_wanted) {
      _schedule();
    } else {
      _visible = false;
    }
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_wanted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox) return;
      final visible = NotionContentLoop.isVisible(box, _screen);
      if (visible != _visible) setState(() => _visible = visible);
    });
  }

  @override
  void dispose() {
    _position?.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TickerMode(enabled: _wanted && _visible, child: widget.child);
}

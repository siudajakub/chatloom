// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/sticker_picker_dialog.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/adaptive_bottom_sheet.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent, kTouchSlop;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// One entry of a message's action menu (reply, copy, forward, delete...).
/// The host decides which apply to a message, exactly as its capability
/// checks allow; the menu only presents them.
@immutable
class ConversationMessageAction {
  const ConversationMessageAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  /// Drawn in the danger colour (delete, report).
  final bool destructive;
}

/// Width of the action card (Telegram/Messenger: one compact column).
const double _cardWidth = 252;

/// Height reserved for the bubble when the card has to scroll.
const double _minBubble = 96;

/// Distance a held finger must travel before it starts choosing an emoji.
const double _hoverSlop = kTouchSlop;

/// Shows the long-press overlay of one message (Telegram/Messenger):
/// a dim scrim, the pressed bubble lifted at its own place (a copy drawn from
/// [press]'s snapshot; the list bubble stays where it is), a pill of
/// [reactions] above it and the [actions] card below. The bubble moves only
/// when the bar or the card would not fit on screen.
///
/// Tapping an emoji calls [onReact]; "+" closes the overlay and calls
/// [onMoreReactions]; an action closes it and runs. A tap on the scrim, Back
/// or any scroll attempt dismisses it. While the finger that opened it is
/// still down, sliding it over the bar highlights the emoji under it and
/// releasing there reacts.
///
/// It is an [OverlayEntry] of the root overlay, not a route: pushing a route
/// makes the navigator cancel every active pointer, which would end the held
/// long-press. Back closes it through a [LocalHistoryEntry] of the
/// conversation's route; leaving or covering that route closes it at once.
///
/// Takes ownership of [press]'s snapshot. Completes once the overlay is gone.
Future<void> showConversationMessageMenu({
  required BuildContext context,
  required ConversationMessagePress press,
  required bool outgoing,
  List<String> reactions = const [],
  Set<String> ownReactions = const {},
  ValueChanged<String>? onReact,
  VoidCallback? onMoreReactions,
  List<ConversationMessageAction> actions = const [],
  String? caption,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final overlayBox = overlay.context.findRenderObject();
  final origin = overlayBox is RenderBox && overlayBox.hasSize
      ? overlayBox.localToGlobal(Offset.zero)
      : Offset.zero;
  final reduced = NotionMotion.reduced(context);
  final barSlots = onReact == null || reactions.isEmpty
      ? 0
      : reactions.length + (onMoreReactions == null ? 0 : 1);
  final entrance = [
    if (barSlots > 0) NotionReactions.barEntrance(barSlots),
    if (actions.isNotEmpty) _cardDelay + NotionReactions.smoothCurve.duration,
    _lift,
  ].reduce((a, b) => a > b ? a : b);
  final route = ModalRoute.of(context);
  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  final done = Completer<void>();
  final menuKey = GlobalKey<_MessageMenuState>();
  var historyRemoved = false;
  late final OverlayEntry entry;
  // Back (and a pop of the conversation's local history) closes the menu.
  final history = LocalHistoryEntry(
    impliesAppBarDismissal: false,
    onRemove: () {
      historyRemoved = true;
      menuKey.currentState?.dismiss();
    },
  );
  void closed() {
    if (done.isCompleted) return;
    if (!historyRemoved) {
      historyRemoved = true;
      if (route != null && route.isActive) {
        route.removeLocalHistoryEntry(history);
      }
    }
    entry.remove();
    entry.dispose();
    press.snapshot?.dispose();
    done.complete();
  }

  entry = OverlayEntry(
    builder: (context) => themes.wrap(
      _MessageMenu(
        key: menuKey,
        route: route,
        enter: reduced ? Duration.zero : entrance,
        exit: reduced ? Duration.zero : NotionMotion.quick,
        total: entrance,
        press: press,
        origin: origin,
        outgoing: outgoing,
        reactions: barSlots == 0 ? const [] : reactions,
        ownReactions: ownReactions,
        onReact: onReact,
        onMoreReactions: onMoreReactions,
        actions: actions,
        caption: caption,
        onClosed: closed,
      ),
    ),
  );
  overlay.insert(entry);
  route?.addLocalHistoryEntry(history);
  return done.future;
}

/// Delay of the card behind the bar.
const Duration _cardDelay = Duration(milliseconds: 30);

/// The lifted copy's pop: from the press-sunk scale over 1.03 back to 1.
const Duration _lift = NotionMotion.long;
const double _liftPeak = 1.03;

class _MessageMenu extends StatefulWidget {
  const _MessageMenu({
    super.key,
    required this.route,
    required this.enter,
    required this.exit,
    required this.total,
    required this.press,
    required this.origin,
    required this.outgoing,
    required this.reactions,
    required this.ownReactions,
    required this.onReact,
    required this.onMoreReactions,
    required this.actions,
    required this.caption,
    required this.onClosed,
  });

  /// The conversation's route: the menu closes when it leaves or is covered.
  final ModalRoute<Object?>? route;
  final Duration enter;
  final Duration exit;
  final Duration total;
  final ConversationMessagePress press;

  /// Global position of the overlay's top left corner.
  final Offset origin;
  final bool outgoing;
  final List<String> reactions;
  final Set<String> ownReactions;
  final ValueChanged<String>? onReact;
  final VoidCallback? onMoreReactions;
  final List<ConversationMessageAction> actions;
  final String? caption;
  final VoidCallback onClosed;

  @override
  State<_MessageMenu> createState() => _MessageMenuState();
}

class _MessageMenuState extends State<_MessageMenu>
    with SingleTickerProviderStateMixin {
  final _barKey = GlobalKey();
  final _geometry = _MenuGeometry();
  int? _hovered;
  int? _chosen;
  bool _closing = false;
  bool _finished = false;
  VoidCallback? _then;
  bool _hoverArmed = false;

  /// Entrance and exit, like a route's animation: forward on open, reverse
  /// on close. Glass blurs only while it rests (see [_settled]).
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: widget.enter,
    reverseDuration: widget.exit,
    // Reduced motion: the same tree, already at rest.
    value: widget.enter == Duration.zero ? 1 : 0,
  );
  late final CurvedAnimation _scrim = CurvedAnimation(
    parent: _animation,
    curve: const Interval(0, .4, curve: NotionMotion.standard),
    reverseCurve: NotionMotion.exitFast,
  );
  bool _settled = false;

  ConversationMenuPointer? get _pointer => widget.press.pointer;

  @override
  void initState() {
    super.initState();
    _pointer?.addListener(_pointerChanged);
    widget.route?.animation?.addStatusListener(_routeChanged);
    widget.route?.secondaryAnimation?.addStatusListener(_routeChanged);
    _settled = _animation.isCompleted;
    _animation.addStatusListener(_status);
    if (!_settled) _animation.forward();
  }

  @override
  void dispose() {
    _pointer?.removeListener(_pointerChanged);
    widget.route?.animation?.removeStatusListener(_routeChanged);
    widget.route?.secondaryAnimation?.removeStatusListener(_routeChanged);
    _scrim.dispose();
    _animation.dispose();
    super.dispose();
  }

  void _status(AnimationStatus status) {
    final settled = status == AnimationStatus.completed;
    if (settled != _settled && mounted) setState(() => _settled = settled);
  }

  /// Runs once the overlay is gone: removes it, then the chosen follow-up
  /// (a dialog, the emoji sheet, the composer), so nothing opens beneath the
  /// fading menu.
  void _finish() {
    if (_finished) return;
    _finished = true;
    widget.onClosed();
    final then = _then;
    _then = null;
    then?.call();
  }

  /// The conversation is leaving, or another page covers it: no exit motion.
  void _routeChanged(AnimationStatus _) {
    final route = widget.route;
    if (route == null) return;
    final leaving =
        route.animation?.status == AnimationStatus.reverse ||
        route.animation?.status == AnimationStatus.dismissed;
    final covered =
        route.secondaryAnimation?.status != AnimationStatus.dismissed;
    if (leaving || covered) {
      _closing = true;
      _then = null;
      _finish();
    }
  }

  /// Closes with the exit motion (Back, scrim, a choice), then runs [then].
  void dismiss({VoidCallback? then}) {
    if (_closing || !mounted) return;
    _closing = true;
    _then = then;
    _pointer?.removeListener(_pointerChanged);
    if (_animation.isDismissed) {
      _finish();
    } else {
      // The future (not a status listener) also completes for a zero exit
      // under reduced motion.
      _animation.reverse().whenCompleteOrCancel(() {
        if (mounted) _finish();
      });
    }
  }

  int get _slots =>
      widget.reactions.length + (widget.onMoreReactions == null ? 0 : 1);

  void _pointerChanged() {
    final pointer = _pointer;
    if (pointer == null || _closing || !mounted) return;
    final position = pointer.position;
    if (!_hoverArmed &&
        position != null &&
        (position - widget.press.position).distance > _hoverSlop) {
      _hoverArmed = true;
    }
    if (pointer.released) {
      final hovered = _hovered;
      if (hovered != null) _chooseSlot(hovered);
      return;
    }
    if (!_hoverArmed || position == null || _slots == 0) return;
    final box = _barKey.currentContext?.findRenderObject();
    int? slot;
    if (box is RenderBox && box.hasSize) {
      slot = NotionReactionBar.slotAt(
        box.globalToLocal(position),
        _slots,
        slot: _geometry.slot,
        slop: NotionSpace.xl,
      );
    }
    if (slot != _hovered) {
      // A tick per emoji the finger slides onto (Signal), none on leaving.
      if (slot != null) NotionHaptics.selection();
      setState(() => _hovered = slot);
    }
  }

  void _chooseSlot(int slot) {
    if (slot < widget.reactions.length) {
      _react(slot);
    } else {
      _more();
    }
  }

  void _close() => dismiss();

  void _react(int index) {
    if (_closing) return;
    setState(() => _chosen = index);
    _close();
    // The reaction goes out at once; the chip pops in as the menu fades.
    widget.onReact?.call(widget.reactions[index]);
  }

  void _more() {
    if (_closing) return;
    dismiss(then: widget.onMoreReactions);
  }

  void _select(ConversationMessageAction action) {
    if (_closing) return;
    dismiss(then: action.onSelected);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colors = context.notion.colors;
    final size = media.size;
    final bubble = widget.press.rect.shift(-widget.origin);
    final start = widget.press.visualRect.shift(-widget.origin);
    const side = NotionSpace.xs;
    final slot = _slots == 0
        ? NotionReactions.barSlot
        : math.min(
            NotionReactions.barSlot,
            (size.width - 2 * side - 2 * NotionReactions.barPadding) / _slots,
          );
    _geometry.slot = slot;
    final Animation<double> animation = _animation;
    final scrim = FadeTransition(
      opacity: _scrim,
      child: ColoredBox(color: colors.scrim),
    );
    final children = <Widget>[
      LayoutId(
        id: _MenuSlot.scrim,
        child: Semantics(
          button: true,
          label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
          onTap: _close,
          child: Listener(
            // A wheel scroll is a scroll attempt too.
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) _close();
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              onPanStart: (_) => _close(),
              child: scrim,
            ),
          ),
        ),
      ),
      LayoutId(
        id: _MenuSlot.bubble,
        child: IgnorePointer(
          child: ExcludeSemantics(
            // A copy: never a second hero for the media inside.
            child: HeroMode(
              enabled: false,
              child: _MenuCopy(
                animation: animation,
                geometry: _geometry,
                natural: bubble,
                start: start,
                total: widget.total,
                image: widget.press.snapshot,
              ),
            ),
          ),
        ),
      ),
      if (widget.reactions.isNotEmpty)
        LayoutId(
          id: _MenuSlot.bar,
          child: NotionReactionBar(
            key: _barKey,
            reactions: widget.reactions,
            selected: widget.ownReactions,
            hovered: _hovered,
            chosen: _chosen,
            slot: slot,
            entrance: animation,
            origin: widget.outgoing
                ? Alignment.bottomRight
                : Alignment.bottomLeft,
            moreLabel: L10n.of(context).customReaction,
            onSelected: (emoji) => _react(widget.reactions.indexOf(emoji)),
            onMore: widget.onMoreReactions == null ? null : _more,
          ),
        ),
      if (widget.actions.isNotEmpty)
        LayoutId(
          id: _MenuSlot.card,
          child: _MenuCardEntrance(
            animation: animation,
            total: widget.total,
            alignment: widget.outgoing ? Alignment.topRight : Alignment.topLeft,
            child: _MenuCard(
              caption: widget.caption,
              actions: widget.actions,
              onSelected: _select,
            ),
          ),
        ),
    ];
    // While anything moves, glass paints its opaque tint (never an animated
    // blur); at rest it follows the surrounding glass mode.
    final glass = NotionGlassScope.modeOf(context);
    return NotionGlassScope(
      mode: _settled ? glass : NotionGlassMode.off,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Message actions',
        child: CustomMultiChildLayout(
          delegate: _MenuLayout(
            bubble: bubble,
            insets: EdgeInsets.only(
              top: media.padding.top,
              bottom: math.max(media.padding.bottom, media.viewInsets.bottom),
            ),
            outgoing: widget.outgoing,
            geometry: _geometry,
          ),
          children: children,
        ),
      ),
    );
  }
}

enum _MenuSlot { scrim, bubble, bar, card }

/// Where layout put the lifted copy; read while painting (the copy's
/// entrance is a paint-time transform, so nothing relayouts per frame).
class _MenuGeometry {
  double slot = NotionReactions.barSlot;
  Rect target = Rect.zero;
}

/// Bar above the bubble, card below, both on the bubble's sender side and
/// inside the safe area; the bubble shifts only as much as needed, and a
/// bubble taller than the room left is clipped (its top stays visible).
class _MenuLayout extends MultiChildLayoutDelegate {
  _MenuLayout({
    required this.bubble,
    required this.insets,
    required this.outgoing,
    required this.geometry,
  });

  final Rect bubble;
  final EdgeInsets insets;
  final bool outgoing;
  final _MenuGeometry geometry;

  @override
  void performLayout(Size size) {
    const side = NotionSpace.xs;
    const gap = NotionSpace.xs;
    layoutChild(_MenuSlot.scrim, BoxConstraints.tight(size));
    positionChild(_MenuSlot.scrim, Offset.zero);
    final top = insets.top + side;
    final bottom = math.max(top, size.height - insets.bottom - side);
    final available = bottom - top;
    final maxWidth = math.max(0.0, size.width - 2 * side);
    final bar = hasChild(_MenuSlot.bar)
        ? layoutChild(
            _MenuSlot.bar,
            BoxConstraints.loose(Size(maxWidth, available)),
          )
        : Size.zero;
    final barGap = hasChild(_MenuSlot.bar) ? gap : 0.0;
    final cardGap = hasChild(_MenuSlot.card) ? gap : 0.0;
    final card = hasChild(_MenuSlot.card)
        ? layoutChild(
            _MenuSlot.card,
            BoxConstraints(
              maxWidth: math.min(_cardWidth, maxWidth),
              maxHeight: math.max(
                0.0,
                available -
                    bar.height -
                    barGap -
                    cardGap -
                    math.min(bubble.height, _minBubble),
              ),
            ),
          )
        : Size.zero;
    final need = bar.height + barGap + bubble.height + cardGap + card.height;
    double y;
    var visible = bubble.height;
    if (need <= available) {
      final minY = top + bar.height + barGap;
      final maxY = bottom - card.height - cardGap - bubble.height;
      y = bubble.top.clamp(minY, math.max(minY, maxY));
    } else {
      y = top + bar.height + barGap;
      visible = math.max(0.0, bottom - card.height - cardGap - y);
    }
    final target = Rect.fromLTWH(bubble.left, y, bubble.width, visible);
    geometry.target = target;
    layoutChild(_MenuSlot.bubble, BoxConstraints.tight(target.size));
    positionChild(_MenuSlot.bubble, target.topLeft);
    double edge(double width) => (outgoing ? bubble.right - width : bubble.left)
        .clamp(side, math.max(side, size.width - side - width));
    if (hasChild(_MenuSlot.bar)) {
      positionChild(
        _MenuSlot.bar,
        Offset(edge(bar.width), y - barGap - bar.height),
      );
    }
    if (hasChild(_MenuSlot.card)) {
      positionChild(
        _MenuSlot.card,
        Offset(edge(card.width), y + visible + cardGap),
      );
    }
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      bubble != oldDelegate.bubble ||
      insets != oldDelegate.insets ||
      outgoing != oldDelegate.outgoing;
}

/// The lifted copy of the pressed bubble: its snapshot at natural size,
/// clipped to the room layout gave it. On entry it starts exactly over the
/// list bubble (still sunk by the press) and pops over [_liftPeak] to rest at
/// identity, travelling to its target when layout had to move it; on exit
/// it returns there and fades. Painted with transforms only.
class _MenuCopy extends SingleChildRenderObjectWidget {
  _MenuCopy({
    required this.animation,
    required this.geometry,
    required this.natural,
    required this.start,
    required this.total,
    required ui.Image? image,
  }) : super(
         child: image == null
             ? const SizedBox.shrink()
             : ClipRect(
                 child: OverflowBox(
                   alignment: Alignment.topLeft,
                   minWidth: natural.width,
                   maxWidth: natural.width,
                   minHeight: natural.height,
                   maxHeight: natural.height,
                   child: RawImage(
                     image: image,
                     width: natural.width,
                     height: natural.height,
                     fit: BoxFit.fill,
                     filterQuality: FilterQuality.medium,
                   ),
                 ),
               ),
       );

  final Animation<double> animation;
  final _MenuGeometry geometry;
  final Rect natural;
  final Rect start;
  final Duration total;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMenuCopy(
    animation: animation,
    geometry: geometry,
    natural: natural,
    start: start,
    total: total,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderMenuCopy renderObject) {
    renderObject
      ..animation = animation
      ..natural = natural
      ..start = start
      ..total = total;
  }
}

class _RenderMenuCopy extends RenderProxyBox {
  _RenderMenuCopy({
    required Animation<double> animation,
    required this.geometry,
    required this.natural,
    required this.start,
    required this.total,
  }) : _animation = animation;

  final _MenuGeometry geometry;
  Rect natural;
  Rect start;
  Duration total;

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  static final _peak = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0,
        end: 1,
      ).chain(CurveTween(curve: NotionMotion.emphasized)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1,
        end: 0,
      ).chain(CurveTween(curve: NotionMotion.standard)),
      weight: 55,
    ),
  ]);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final t = _animation.value.clamp(0.0, 1.0);
    final reverse = _animation.status == AnimationStatus.reverse;
    final target = geometry.target;
    // Natural position relative to where layout placed the copy.
    final shift = natural.topLeft - target.topLeft;
    final sunk = natural.width <= 0 ? 1.0 : start.width / natural.width;
    double travel;
    double scale;
    double opacity;
    if (reverse) {
      travel = 1 - NotionMotion.exitFast.transform(1 - t);
      scale = 1;
      opacity = (t / .5).clamp(0.0, 1.0);
    } else {
      final local = notionInterval(t, total, Duration.zero, _lift);
      travel = NotionMotion.emphasized.transform(local);
      final peak = _peak.transform(local);
      final base = sunk + (1 - sunk) * NotionMotion.emphasized.transform(local);
      scale = base + (_liftPeak - 1) * peak;
      opacity = 1;
    }
    final dx = shift.dx * (1 - travel);
    final dy = shift.dy * (1 - travel);
    // The press sinks the bubble around its sender-side edge; keep that
    // edge (the anchor of the sunk start) fixed while it grows.
    final anchor = Offset(
      start.center.dx >= natural.center.dx ? size.width : 0,
      size.height / 2,
    );
    final matrix = Matrix4.identity()
      ..translateByDouble(dx + anchor.dx, dy + anchor.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-anchor.dx, -anchor.dy, 0, 1);
    void paintChild(PaintingContext context, Offset offset) =>
        context.pushTransform(
          needsCompositing,
          offset,
          matrix,
          (context, offset) => context.paintChild(child, offset),
        );
    if (opacity >= 1) {
      paintChild(context, offset);
    } else if (opacity > 0) {
      context.pushOpacity(offset, (opacity * 255).round(), paintChild);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;
}

class _MenuCardEntrance extends StatelessWidget {
  const _MenuCardEntrance({
    required this.animation,
    required this.total,
    required this.alignment,
    required this.child,
  });

  final Animation<double> animation;
  final Duration total;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      // One tree shape in every phase, so nothing remounts when it settles.
      final t = animation.value;
      var opacity = 1.0;
      var rise = 0.0;
      var scale = 1.0;
      if (animation.status == AnimationStatus.reverse) {
        opacity = t.clamp(0.0, 1.0);
        scale = .96 + .04 * t;
      } else if (t < 1) {
        final local = notionInterval(
          t,
          total,
          _cardDelay,
          NotionReactions.smoothCurve.duration,
        );
        final curve = NotionReactions.smoothCurve.transform(local);
        opacity = (local * 2.5).clamp(0.0, 1.0);
        rise = NotionMotion.riseSheet * (1 - curve);
        scale =
            NotionMotion.popoverFrom + (1 - NotionMotion.popoverFrom) * curve;
      }
      return Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(0, rise),
          child: Transform.scale(
            scale: scale,
            alignment: alignment,
            child: child,
          ),
        ),
      );
    },
  );
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.caption,
    required this.actions,
    required this.onSelected,
  });

  final String? caption;
  final List<ConversationMessageAction> actions;
  final ValueChanged<ConversationMessageAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final caption = this.caption;
    return NotionGlassPanel(
      padding: const EdgeInsets.symmetric(vertical: NotionSpace.xxs),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (caption != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NotionSpace.md,
                  NotionSpace.xxs,
                  NotionSpace.md,
                  NotionSpace.xxs,
                ),
                child: Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: notion.typography.captionMuted,
                ),
              ),
            for (final action in actions)
              NotionGlassMenuRow(
                leading: Icon(
                  action.icon,
                  color: action.destructive ? notion.colors.danger : null,
                ),
                title: action.label,
                style: action.destructive
                    ? NotionType.callout.copyWith(color: notion.colors.danger)
                    : null,
                onTap: () => onSelected(action),
              ),
          ],
        ),
      ),
    );
  }
}

/// The full emoji (and emoticon) picker behind the bar's "+": the custom
/// reaction sheet of the ordinary chat. Resolves to the chosen key.
Future<String?> showConversationReactionPicker(
  BuildContext context,
  Room room,
) {
  final theme = Theme.of(context);
  return showAdaptiveBottomSheet<String>(
    context: context,
    builder: (context) => Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).customReaction),
        leading: CloseButton(onPressed: () => Navigator.of(context).pop(null)),
      ),
      body: SizedBox(
        height: double.infinity,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  Tab(text: L10n.of(context).emojis),
                  Tab(text: L10n.of(context).stickers),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    EmojiPicker(
                      onEmojiSelected: (_, emoji) =>
                          Navigator.of(context).pop(emoji.emoji),
                      config: Config(
                        locale: Localizations.localeOf(context),
                        emojiViewConfig: const EmojiViewConfig(
                          backgroundColor: Colors.transparent,
                        ),
                        bottomActionBarConfig: const BottomActionBarConfig(
                          enabled: false,
                        ),
                        categoryViewConfig: CategoryViewConfig(
                          initCategory: Category.SMILEYS,
                          backspaceColor: theme.colorScheme.primary,
                          iconColor: theme.colorScheme.primary.withAlpha(128),
                          iconColorSelected: theme.colorScheme.primary,
                          indicatorColor: theme.colorScheme.primary,
                          backgroundColor: theme.colorScheme.surface,
                        ),
                        skinToneConfig: SkinToneConfig(
                          dialogBackgroundColor: Color.lerp(
                            theme.colorScheme.surface,
                            theme.colorScheme.primaryContainer,
                            0.75,
                          )!,
                          indicatorColor: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    StickerPickerDialog(
                      room: room,
                      usage: ImagePackUsage.emoticon,
                      onSelected: (sticker) =>
                          Navigator.of(context).pop(sticker.url.toString()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// "Select text": the message body in a sheet, freely selectable, so a part
/// can be copied on touch screens (the timeline's long-press opens the menu).
Future<void> showConversationTextSelection(BuildContext context, String text) =>
    showNotionSheet<void>(
      context: context,
      title: L10n.of(context).select,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .6,
        ),
        child: SingleChildScrollView(
          child: SelectableText(text, style: context.notion.typography.body),
        ),
      ),
    );

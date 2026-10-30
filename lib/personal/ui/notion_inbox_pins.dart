// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/personal/ui/notion_inbox_network_badge.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

/// Size the pinned grid draws [NotionPinnedShortcut.avatar] at; build the
/// avatar for this size so its image stays sharp.
const double notionPinnedAvatarSize = NotionSize.avatarLg;

class NotionPinnedShortcut {
  final String name;

  /// The chat's avatar, drawn at [notionPinnedAvatarSize].
  final Widget avatar;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int order;
  final bool isGroup;

  /// Stable identity (the inbox entity); the name when not given.
  final String? id;

  /// Unread messages: a count badge and an accent ring on the bubble.
  final int unreadCount;

  /// Marked unread by hand: a dot instead of a count.
  final bool unread;

  /// Somebody mentioned the account: the badge stays accent when muted.
  final bool mentioned;

  /// Notifications limited: grey badge and ring.
  final bool muted;

  /// Network marks on the bubble (`notionBadgeNetworks`); empty: none.
  final List<String> networks;

  const NotionPinnedShortcut({
    required this.name,
    required this.avatar,
    required this.onTap,
    required this.order,
    this.onLongPress,
    this.isGroup = false,
    this.id,
    this.unreadCount = 0,
    this.unread = false,
    this.mentioned = false,
    this.muted = false,
    this.networks = const [],
  });

  String get key => id ?? name;
}

/// Moves the pin [from] to the slot of the pin [to] in [keys] (the drop
/// target's place, Telegram's pinned reorder); unchanged when either is
/// missing or they are the same.
List<String> notionMovePin(List<String> keys, String from, String to) {
  final source = keys.indexOf(from);
  final target = keys.indexOf(to);
  if (source < 0 || target < 0 || source == target) return keys;
  return List<String>.of(keys)
    ..removeAt(source)
    ..insert(target, from);
}

/// Narrowest cell of the pinned grid: five bubbles across a 412 dp phone,
/// four on a 360 dp one.
const double _minCell = 72;

/// Ring around the avatar and the gap between them.
const double _ring = 2;
const double _ringGap = 2;
const double _bubble = notionPinnedAvatarSize + 2 * (_ring + _ringGap);

/// The lifted bubble while it is dragged.
const double _liftScale = 1.1;

/// Columns of the pinned grid for [width]: as many cells as fit, at least
/// four while four bubbles fit.
@visibleForTesting
int notionPinnedColumns(double width) {
  final fit = (width / _minCell).floor();
  if (fit >= 4) return fit;
  return (width / _bubble).floor().clamp(1, 4);
}

/// Pinned chats as an even grid of equal round avatar bubbles with the name
/// under each (wave 13: like a delivery app's category bubbles, all the
/// same size). Unread chats get an accent ring and a count badge, muted ones
/// grey; network marks sit on the bubble as in the list. A chat pinned
/// while the grid is on screen pops in.
///
/// With [onReorder] the bubbles reorder by drag: on touch a long press
/// lifts a bubble (released without moving, it opens the chat's long-press
/// menu instead), a mouse drags it directly (a right click keeps the menu).
/// The lifted bubble follows the finger, its neighbours slide out of the
/// way, and the drop settles it into its slot. Alt+←/→ moves a focused
/// bubble; a screen reader gets "Move left" / "Move right" actions.
/// [onReorder] receives the new order of the pin keys
/// ([NotionPinnedShortcut.key]); the grid shows it at once and goes back to
/// [pins]' order when the returned future fails.
///
/// The drag is each bubble's own long-press (touch) or pan (mouse)
/// recognizer, not a `LongPressDraggable`: once the long press is
/// recognised it owns the pointer against the inbox scroll, the bubble
/// moves inside the grid (no overlay, no drop targets), and it keeps its
/// element while the inbox rebuilds under the finger.
class NotionPinnedShortcuts extends StatefulWidget {
  final List<NotionPinnedShortcut> pins;
  final Future<void> Function(List<String> keys)? onReorder;
  const NotionPinnedShortcuts({super.key, required this.pins, this.onReorder});

  @override
  State<NotionPinnedShortcuts> createState() => _NotionPinnedShortcutsState();
}

/// One drag in progress.
class _PinDrag {
  _PinDrag({
    required this.key,
    required this.order,
    required this.origin,
    required this.start,
    required this.touch,
  }) : offset = origin,
       moved = !touch;

  final String key;

  /// The order shown while dragging (neighbours already moved aside).
  List<String> order;

  /// Top-left of the bubble's slot when it was lifted (grid coordinates).
  final Offset origin;

  /// Global pointer position when it was lifted.
  final Offset start;

  /// Lifted by a long press: a release without moving opens the menu.
  final bool touch;

  /// Where the lifted bubble is drawn (grid coordinates).
  Offset offset;

  /// Moved past the touch slop (a mouse drag always has).
  bool moved;
}

class _Grid {
  const _Grid({
    required this.width,
    required this.columns,
    required this.cellHeight,
    required this.count,
    required this.rtl,
  });

  final double width;
  final int columns;
  final double cellHeight;
  final int count;
  final bool rtl;

  double get cellWidth => width / columns;
  int get rows => (count + columns - 1) ~/ columns;
  double get height => rows * cellHeight;

  Offset slot(int index) {
    final column = index % columns;
    final x = rtl ? width - (column + 1) * cellWidth : column * cellWidth;
    return Offset(x, (index ~/ columns) * cellHeight);
  }

  /// The slot under [local] (grid coordinates), clamped to the pins.
  int indexAt(Offset local) {
    var column = (local.dx / cellWidth).floor().clamp(0, columns - 1);
    if (rtl) column = columns - 1 - column;
    final row = (local.dy / cellHeight).floor().clamp(0, rows - 1);
    return (row * columns + column).clamp(0, count - 1);
  }
}

class _NotionPinnedShortcutsState extends State<NotionPinnedShortcuts> {
  /// Keys shown so far; anything else is a new pin.
  Set<String>? _known;

  /// The order the user dropped, shown until [NotionPinnedShortcuts.pins]
  /// catch up (the private store writes in the background) or change set.
  List<String>? _dropped;

  _PinDrag? _drag;
  _Grid? _grid;
  final _gridKey = GlobalKey();

  void _commit(List<String> keys, List<String> next) {
    if (listEquals(keys, next)) return;
    setState(() => _dropped = next);
    widget.onReorder
        ?.call(next)
        .then<void>(
          (_) {},
          onError: (Object _) {
            if (mounted && identical(_dropped, next)) {
              setState(() => _dropped = null);
            }
          },
        );
  }

  /// Screen reader and keyboard: one place towards [delta].
  void _step(List<String> keys, String key, int delta) {
    final index = keys.indexOf(key);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= keys.length) return;
    NotionHaptics.selection();
    _commit(keys, notionMovePin(keys, key, keys[target]));
  }

  void _lift(
    List<String> keys,
    String key,
    Offset global, {
    required bool touch,
  }) {
    final grid = _grid;
    final index = keys.indexOf(key);
    if (grid == null || index < 0 || _drag != null) return;
    if (touch) NotionHaptics.longPress();
    setState(
      () => _drag = _PinDrag(
        key: key,
        order: List.of(keys),
        origin: grid.slot(index),
        start: global,
        touch: touch,
      ),
    );
  }

  void _move(Offset global) {
    final drag = _drag;
    final grid = _grid;
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (drag == null || grid == null || box == null || !box.hasSize) return;
    final delta = global - drag.start;
    if (delta.distance > kTouchSlop) drag.moved = true;
    // The bubble stays over the grid (half a cell of give vertically).
    final raw = drag.origin + delta;
    final offset = Offset(
      raw.dx.clamp(0, math.max(0, grid.width - grid.cellWidth)),
      raw.dy.clamp(-grid.cellHeight / 2, grid.height - grid.cellHeight / 2),
    );
    final target = grid.indexAt(box.globalToLocal(global));
    final current = drag.order.indexOf(drag.key);
    setState(() {
      drag.offset = offset;
      if (drag.moved && target != current) {
        drag.order = List.of(drag.order)
          ..removeAt(current)
          ..insert(target, drag.key);
        NotionHaptics.selection();
      }
    });
  }

  void _release(List<String> keys, NotionPinnedShortcut pin) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = null);
    if (drag.moved) {
      _commit(keys, drag.order);
    } else if (drag.touch) {
      // A long press without moving is the chat's menu, as before.
      pin.onLongPress?.call();
    }
  }

  void _cancel() {
    if (_drag != null) setState(() => _drag = null);
  }

  @override
  Widget build(BuildContext context) {
    final pins = widget.pins;
    if (pins.isEmpty) {
      _drag = null;
      return const SizedBox.shrink();
    }
    var ordered = List<NotionPinnedShortcut>.of(pins)
      ..sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        return byOrder != 0 ? byOrder : a.key.compareTo(b.key);
      });
    final byKey = {for (final pin in ordered) pin.key: pin};
    final dropped = _dropped;
    if (dropped != null) {
      final incoming = [for (final pin in ordered) pin.key];
      if (listEquals(incoming, dropped) ||
          !setEquals(byKey.keys.toSet(), dropped.toSet())) {
        _dropped = null;
      } else {
        ordered = [for (final key in dropped) byKey[key]!];
      }
    }
    final keys = [for (final pin in ordered) pin.key];
    if (_drag case final drag?
        when !setEquals(drag.order.toSet(), byKey.keys.toSet())) {
      // A pin came or went under the finger: the drag ends, nothing moves.
      _drag = null;
    }
    final reorder = widget.onReorder != null && ordered.length > 1;
    final known = _known;
    final fresh = known == null
        ? const <String>{}
        : byKey.keys.toSet().difference(known);
    _known = byKey.keys.toSet();

    final labelStyle = NotionType.caption.copyWith(fontWeight: FontWeight.w500);
    final measure = TextPainter(
      text: TextSpan(text: 'Ag', style: labelStyle),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final cellHeight =
        NotionSpace.xxs + _bubble + NotionSpace.xxs + measure.height;
    measure.dispose();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final reduced = NotionMotion.reduced(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const NotionSectionHeader(title: 'Pinned', padding: EdgeInsets.zero),
        const SizedBox(height: NotionSpace.xs),
        LayoutBuilder(
          builder: (context, constraints) {
            final grid = _grid = _Grid(
              width: constraints.maxWidth,
              columns: notionPinnedColumns(constraints.maxWidth),
              cellHeight: cellHeight,
              count: ordered.length,
              rtl: rtl,
            );
            final active = _drag;
            final shown = active?.order ?? keys;
            Widget slot(NotionPinnedShortcut pin) {
              final dragged = active?.key == pin.key;
              final index = keys.indexOf(pin.key);
              Widget bubble = NotionPop(
                // Same wrapper for every bubble, so none ever remounts.
                playOnMount: fresh.contains(pin.key),
                bounce: false,
                from: NotionMotion.dialogFrom,
                child: _PinnedBubble(
                  pin: pin,
                  lifted: dragged,
                  labelStyle: labelStyle,
                  longPressMenu: !reorder,
                ),
              );
              if (reorder) {
                final earlier = rtl
                    ? LogicalKeyboardKey.arrowRight
                    : LogicalKeyboardKey.arrowLeft;
                final later = rtl
                    ? LogicalKeyboardKey.arrowLeft
                    : LogicalKeyboardKey.arrowRight;
                bubble = _PinGestures(
                  onLift: (global, touch) =>
                      _lift(keys, pin.key, global, touch: touch),
                  onMove: _move,
                  onRelease: () => _release(keys, pin),
                  onCancel: _cancel,
                  child: CallbackShortcuts(
                    bindings: {
                      SingleActivator(earlier, alt: true): () =>
                          _step(keys, pin.key, -1),
                      SingleActivator(later, alt: true): () =>
                          _step(keys, pin.key, 1),
                    },
                    child: Semantics(
                      customSemanticsActions: {
                        if (index > 0)
                          const CustomSemanticsAction(label: 'Move left'): () =>
                              _step(keys, pin.key, -1),
                        if (index < keys.length - 1)
                          const CustomSemanticsAction(
                            label: 'Move right',
                          ): () =>
                              _step(keys, pin.key, 1),
                      },
                      child: bubble,
                    ),
                  ),
                );
              }
              return Positioned(
                key: ValueKey(pin.key),
                left: 0,
                top: 0,
                width: grid.cellWidth,
                height: grid.cellHeight,
                child: _SlotMotion(
                  offset: dragged
                      ? active!.offset
                      : grid.slot(shown.indexOf(pin.key)),
                  // The lifted bubble follows the finger as is; the others
                  // (and the dropped one) glide to their slots.
                  animate: !dragged && !reduced,
                  child: bubble,
                ),
              );
            }

            final lifted = active == null ? null : byKey[active.key];
            return Listener(
              // A cancelled pointer (system gesture, app switch) never
              // leaves a bubble in the air.
              onPointerCancel: (_) => _cancel(),
              child: SizedBox(
                key: _gridKey,
                width: grid.width,
                height: grid.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final pin in ordered)
                      if (pin != lifted) slot(pin),
                    // The lifted bubble paints over its neighbours.
                    if (lifted != null) slot(lifted),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// A long press (touch, stylus) or a mouse drag lifts the bubble. The pan
/// is mouse only, so a touch drag over the grid still scrolls the inbox and
/// a trackpad scroll is never taken for a drag.
class _PinGestures extends StatelessWidget {
  const _PinGestures({
    required this.onLift,
    required this.onMove,
    required this.onRelease,
    required this.onCancel,
    required this.child,
  });

  final void Function(Offset global, bool touch) onLift;
  final ValueChanged<Offset> onMove;
  final VoidCallback onRelease;
  final VoidCallback onCancel;
  final Widget child;

  static const _pressDevices = {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: {
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              debugOwner: this,
              supportedDevices: _pressDevices,
            ),
            (recognizer) => recognizer
              ..onLongPressStart = ((details) =>
                  onLift(details.globalPosition, true))
              ..onLongPressMoveUpdate = ((details) =>
                  onMove(details.globalPosition))
              ..onLongPressEnd = ((_) => onRelease())
              ..onLongPressCancel = onCancel,
          ),
      PanGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(
              debugOwner: this,
              supportedDevices: const {PointerDeviceKind.mouse},
            ),
            (recognizer) => recognizer
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = ((details) => onLift(details.globalPosition, false))
              ..onUpdate = ((details) => onMove(details.globalPosition))
              ..onEnd = ((_) => onRelease())
              ..onCancel = onCancel,
          ),
    },
    child: child,
  );
}

/// Draws [child] moved by [offset] (a translation, no relayout). A new
/// offset glides there from wherever the child is drawn now; [animate]
/// false jumps (the finger, reduced motion). No controller exists until the
/// first glide.
class _SlotMotion extends StatefulWidget {
  const _SlotMotion({
    required this.offset,
    required this.animate,
    required this.child,
  });

  final Offset offset;
  final bool animate;
  final Widget child;

  @override
  State<_SlotMotion> createState() => _SlotMotionState();
}

class _SlotMotionState extends State<_SlotMotion>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<Offset>? _glide;
  late Offset _rest = widget.offset;

  Offset get _shown => _glide?.value ?? _rest;

  @override
  void didUpdateWidget(_SlotMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.offset == _rest && (widget.animate || _glide == null)) return;
    final from = _shown;
    _rest = widget.offset;
    if (!widget.animate || from == widget.offset) {
      _controller?.stop();
      _glide = null;
      return;
    }
    final controller = _controller ??= AnimationController(
      vsync: this,
      duration: NotionMotion.medium,
    );
    _glide = Tween(begin: from, end: widget.offset).animate(
      CurvedAnimation(parent: controller, curve: NotionMotion.emphasized),
    );
    controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// One tree shape before and after the first glide: switching from a
  /// bare transform to an animated one would remount the bubble (focus,
  /// avatar image).
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller ?? kAlwaysCompleteAnimation,
    builder: (context, child) =>
        Transform.translate(offset: _shown, child: child),
    child: widget.child,
  );
}

class _PinnedBubble extends StatelessWidget {
  const _PinnedBubble({
    required this.pin,
    required this.lifted,
    required this.labelStyle,
    required this.longPressMenu,
  });

  final NotionPinnedShortcut pin;
  final bool lifted;
  final TextStyle labelStyle;

  /// A long press opens the menu directly (the grid does not reorder).
  final bool longPressMenu;

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final colors = notion.colors;
    final palette = notion.palette;
    final hasUnread = pin.unreadCount > 0 || pin.unread;
    final ring = hasUnread && !pin.muted
        ? palette.accentFill
        : hasUnread
        ? colors.textTertiary
        : colors.border;
    // A mention stays accent in a muted chat (Telegram), as in the list.
    final accent = !pin.muted || pin.mentioned;
    final badgeColor = accent ? palette.accentFill : colors.selected;
    final badgeInk = accent ? palette.onAccentFill : colors.textSecondary;
    final announcement = [
      'Pinned chat, ${pin.name}',
      if (pin.mentioned) 'You were mentioned',
      if (pin.unreadCount > 0)
        '${pin.unreadCount} unread messages'
      else if (pin.unread)
        'Unread',
      if (pin.muted) 'Notifications limited',
      ?notionNetworksAnnouncement(pin.networks),
    ].join(', ');
    final badge = pin.unreadCount > 0 || pin.mentioned
        ? _PinBadge(
            key: ValueKey(('count', pin.unreadCount > 0, pin.mentioned)),
            count: pin.unreadCount > 0 ? pin.unreadCount : null,
            color: badgeColor,
            ink: badgeInk,
          )
        : pin.unread
        ? Container(
            key: const ValueKey('notion_pinned_unread_dot'),
            width: NotionSpace.md,
            height: NotionSpace.md,
            decoration: BoxDecoration(
              color: badgeColor,
              shape: BoxShape.circle,
              border: Border.all(color: colors.background, width: _ring),
            ),
          )
        : const SizedBox.shrink(key: ValueKey('read'));
    return Semantics(
      button: true,
      label: announcement,
      onTap: pin.onTap,
      onLongPress: pin.onLongPress,
      child: NotionPressable(
        scale: NotionMotion.pressButton,
        // The lifted bubble is not pressed in under the finger.
        enabled: !lifted,
        child: Material(
          type: MaterialType.transparency,
          shape: NotionShapes.md,
          child: InkWell(
            onTap: pin.onTap,
            onLongPress: longPressMenu ? pin.onLongPress : null,
            onSecondaryTap: pin.onLongPress,
            customBorder: NotionShapes.md,
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: NotionSpace.xxs),
                  AnimatedScale(
                    scale: lifted ? _liftScale : 1,
                    duration: NotionMotion.of(context, NotionMotion.quick),
                    curve: NotionMotion.standard,
                    child: SizedBox.square(
                      dimension: _bubble,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: ring, width: _ring),
                              ),
                            ),
                          ),
                          Center(
                            child: SizedBox.square(
                              dimension: notionPinnedAvatarSize,
                              child: pin.avatar,
                            ),
                          ),
                          if (pin.networks.isNotEmpty)
                            PositionedDirectional(
                              end: 0,
                              bottom: 0,
                              child: NotionInboxNetworkBadge(
                                networks: pin.networks,
                              ),
                            ),
                          PositionedDirectional(
                            top: 0,
                            end: 0,
                            child: NotionLazySwitcher(
                              style: NotionLazySwitch.morph,
                              bounce: true,
                              alignment: AlignmentDirectional.topEnd,
                              child: badge,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: NotionSpace.xxs),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NotionSpace.xxs,
                    ),
                    child: Text(
                      pin.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: labelStyle.copyWith(
                        color: pin.muted ? colors.textSecondary : colors.text,
                        fontWeight: hasUnread ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The unread count (or "@" for a mention without one) on a bubble, ringed
/// in the page colour so it reads over any avatar.
class _PinBadge extends StatelessWidget {
  const _PinBadge({
    super.key,
    required this.count,
    required this.color,
    required this.ink,
  });

  final int? count;
  final Color color;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final style = NotionType.micro.copyWith(
      color: ink,
      fontWeight: FontWeight.w700,
    );
    final count = this.count;
    return Container(
      key: const ValueKey('notion_pinned_badge'),
      constraints: const BoxConstraints(
        minWidth: NotionSize.iconSm + 2 * _ring,
        minHeight: NotionSize.iconSm + 2 * _ring,
      ),
      padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xxs),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: NotionRadius.pillAll,
        border: Border.all(
          color: context.notion.colors.background,
          width: _ring,
        ),
      ),
      child: count == null
          ? Text('@', style: style)
          : NotionAnimatedCount(
              count: count,
              style: style,
              format: (n) => n > 99 ? '99+' : '$n',
            ),
    );
  }
}

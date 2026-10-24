// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

class NotionPinnedShortcut {
  final String name;
  final Widget avatar;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int order;
  final bool isGroup;

  /// Stable identity (the inbox entity); the name when not given.
  final String? id;
  const NotionPinnedShortcut({
    required this.name,
    required this.avatar,
    required this.onTap,
    required this.order,
    this.onLongPress,
    this.isGroup = false,
    this.id,
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

/// Pinned chats as a two-up carousel. A chat pinned while the carousel is
/// on screen pops its card in and the carousel slides to it; cards that were
/// there before (or are built by swiping) appear as they are.
///
/// With [onReorder] the cards can be dragged onto each other's place (FX-17):
/// a long press lifts a card on touch screens (released without moving, it
/// opens the card's long-press menu instead), a mouse drags it directly
/// (the right click keeps the menu). Dragging to the carousel's edge turns
/// the page. A screen reader gets "Move left" / "Move right" actions.
/// [onReorder] receives the new order of the pin keys
/// ([NotionPinnedShortcut.key]); the carousel shows it at once and goes
/// back to [pins]' order when the returned future fails.
class NotionPinnedShortcuts extends StatefulWidget {
  final List<NotionPinnedShortcut> pins;
  final Future<void> Function(List<String> keys)? onReorder;
  const NotionPinnedShortcuts({super.key, required this.pins, this.onReorder});

  @override
  State<NotionPinnedShortcuts> createState() => _NotionPinnedShortcutsState();
}

class _NotionPinnedShortcutsState extends State<NotionPinnedShortcuts> {
  final PageController _pages = PageController();

  /// Names shown so far; anything else is a new pin.
  Set<String>? _known;

  /// The order the user dropped, shown until [NotionPinnedShortcuts.pins]
  /// catch up (the private store writes in the background) or change set.
  List<String>? _dropped;

  /// A drag at the edge is turning the page.
  bool _paging = false;

  /// The pin being dragged moved past the touch slop (else a release opens
  /// its long-press menu).
  bool _dragMoved = false;
  Offset? _dragOrigin;
  final _carousel = GlobalKey();

  static bool get _mouseDrag => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    _ => false,
  };

  void _drop(List<String> keys, String from, String to) {
    final next = notionMovePin(keys, from, to);
    if (identical(next, keys)) return;
    NotionHaptics.selection();
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

  /// Turns the page while a dragged card is held at the carousel's edge.
  void _edgePage(Offset global, int pages) {
    if (_paging || !_pages.hasClients) return;
    final box = _carousel.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final x = box.globalToLocal(global).dx;
    final page = (_pages.page ?? 0).round();
    const edge = NotionSize.touchTarget / 2;
    final next = x < edge
        ? page - 1
        : x > box.size.width - edge
        ? page + 1
        : page;
    if (next == page || next < 0 || next >= pages) return;
    if (NotionMotion.reduced(context)) {
      _pages.jumpToPage(next);
      return;
    }
    _paging = true;
    _pages
        .animateToPage(
          next,
          duration: NotionMotion.long,
          curve: NotionMotion.emphasized,
        )
        .whenComplete(() => _paging = false);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Brings the page holding [index] into view after this frame.
  void _reveal(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pages.hasClients) return;
      final page = index ~/ 2;
      if ((_pages.page ?? 0).round() == page) return;
      if (NotionMotion.reduced(context)) {
        _pages.jumpToPage(page);
      } else {
        _pages.animateToPage(
          page,
          duration: NotionMotion.long,
          curve: NotionMotion.emphasized,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pins = widget.pins;
    if (pins.isEmpty) return const SizedBox.shrink();
    var ordered = List<NotionPinnedShortcut>.of(pins)
      ..sort((a, b) => a.order.compareTo(b.order));
    final dropped = _dropped;
    if (dropped != null) {
      final byKey = {for (final pin in ordered) pin.key: pin};
      final incoming = [for (final pin in ordered) pin.key];
      if (listEquals(incoming, dropped) ||
          !setEquals(byKey.keys.toSet(), dropped.toSet())) {
        _dropped = null;
      } else {
        ordered = [for (final key in dropped) byKey[key]!];
      }
    }
    final keys = [for (final pin in ordered) pin.key];
    final reorder = widget.onReorder != null && ordered.length > 1;
    final names = {for (final pin in ordered) pin.name};
    final known = _known;
    final fresh = known == null ? const <String>{} : names.difference(known);
    _known = names;
    if (fresh.isNotEmpty) {
      _reveal(ordered.indexWhere((pin) => fresh.contains(pin.name)));
    }
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final height = 58.0 + math.max(44.0, 28 * scale + 16);
    final pageCount = (ordered.length + 1) ~/ 2;
    Widget card(NotionPinnedShortcut pin, double width) {
      final index = keys.indexOf(pin.key);
      Widget body = NotionPop(
        key: ValueKey(pin.name),
        // Same wrapper for every card, so a card never remounts.
        playOnMount: fresh.contains(pin.name),
        bounce: false,
        from: NotionMotion.dialogFrom,
        child: _PinnedCard(
          pin: pin,
          // Touch: the long press lifts the card; the menu opens on a
          // release without movement (below).
          longPressMenu: !reorder || _mouseDrag,
        ),
      );
      if (!reorder) return body;
      body = Semantics(
        customSemanticsActions: {
          if (index > 0)
            const CustomSemanticsAction(label: 'Move left'): () =>
                _drop(keys, pin.key, keys[index - 1]),
          if (index < keys.length - 1)
            const CustomSemanticsAction(label: 'Move right'): () =>
                _drop(keys, pin.key, keys[index + 1]),
        },
        child: body,
      );
      final feedback = Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: width,
          height: height,
          child: Transform.scale(
            scale: 1.03,
            child: _PinnedCard(pin: pin, longPressMenu: false),
          ),
        ),
      );
      final ghost = Opacity(opacity: 0.35, child: body);
      void started() {
        _dragMoved = false;
        _dragOrigin = null;
        NotionHaptics.longPress();
      }

      void update(DragUpdateDetails details) {
        final origin = _dragOrigin ??= details.globalPosition;
        if ((details.globalPosition - origin).distance > kTouchSlop) {
          _dragMoved = true;
        }
        if (_dragMoved) _edgePage(details.globalPosition, pageCount);
      }

      void ended(DraggableDetails details) {
        if (!details.wasAccepted && !_dragMoved && !_mouseDrag) {
          pin.onLongPress?.call();
        }
      }

      final draggable = _mouseDrag
          ? Draggable<String>(
              data: pin.key,
              feedback: feedback,
              childWhenDragging: ghost,
              onDragStarted: started,
              onDragUpdate: update,
              onDragEnd: ended,
              child: body,
            )
          : LongPressDraggable<String>(
              data: pin.key,
              feedback: feedback,
              childWhenDragging: ghost,
              hapticFeedbackOnStart: false,
              onDragStarted: started,
              onDragUpdate: update,
              onDragEnd: ended,
              child: body,
            );
      return DragTarget<String>(
        onWillAcceptWithDetails: (details) => details.data != pin.key,
        onAcceptWithDetails: (details) => _drop(keys, details.data, pin.key),
        builder: (context, candidates, _) => AnimatedScale(
          // The slot a card would land in leans back a little.
          scale: candidates.isEmpty ? 1 : NotionMotion.pressButton,
          duration: NotionMotion.of(context, NotionMotion.quick),
          curve: NotionMotion.standard,
          child: draggable,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const NotionSectionHeader(title: 'Pinned', padding: EdgeInsets.zero),
        const SizedBox(height: NotionSpace.xs),
        SizedBox(
          key: _carousel,
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = (constraints.maxWidth - NotionSpace.sm) / 2;
              return PageView.builder(
                controller: _pages,
                itemCount: pageCount,
                itemBuilder: (context, page) => Row(
                  children: [
                    SizedBox(
                      width: cardWidth,
                      child: card(ordered[page * 2], cardWidth),
                    ),
                    const SizedBox(width: NotionSpace.sm),
                    if (page * 2 + 1 < ordered.length)
                      SizedBox(
                        width: cardWidth,
                        child: card(ordered[page * 2 + 1], cardWidth),
                      )
                    else
                      SizedBox(width: cardWidth),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PinnedCard extends StatelessWidget {
  final NotionPinnedShortcut pin;
  final bool longPressMenu;
  const _PinnedCard({required this.pin, this.longPressMenu = true});
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Pinned chat, ${pin.name}',
    child: NotionPressable(
      scale: NotionMotion.pressButton,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: NotionRadius.lgAll,
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: pin.onTap,
          onLongPress: longPressMenu ? pin.onLongPress : null,
          onSecondaryTap: pin.onLongPress,
          child: Column(
            children: [
              Container(
                height: 58,
                width: double.infinity,
                // The theme's cover band (UI-14): paper in light mode.
                color: context.notion.colors.cover,
                child: Center(
                  child: SvgPicture.asset(
                    pin.isGroup
                        ? 'assets/notion/pinned/desk.svg'
                        : 'assets/notion/pinned/coffee.svg',
                    height: 48,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      ExcludeSemantics(
                        child: SizedBox.square(
                          dimension: 28,
                          child: pin.avatar,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          pin.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NotionType.callout.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

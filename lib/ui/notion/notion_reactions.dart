// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_glass.dart';
import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

/// Reaction tokens: chips under bubbles, the long-press reaction bar and the
/// double-tap burst (DESIGN.md "Reactions").
abstract final class NotionReactions {
  /// Messenger's order with the heart first. Networks that declare
  /// `allowed_reactions` keep the allowed ones in this order.
  static const List<String> defaults = ['❤️', '😂', '😮', '😢', '😡', '👍'];

  /// Visible height of a chip, including its [chipRing].
  static const double chipHeight = 28;

  /// Ring of the chat background around a chip, so a chip that overlaps a
  /// bubble reads as cut out of it.
  static const double chipRing = 2;

  /// Chip glyph size.
  static const double chipEmoji = 15;

  /// How far chips overlap the bottom edge of their bubble.
  static const double overlap = 8;

  /// One emoji cell of the bar (a 44 pt circle; the bar is 52 pt high).
  static const double barSlot = 44;
  static const double barPadding = NotionSpace.xxs;
  static const double barHeight = barSlot + 2 * barPadding;
  static const double barEmoji = 28;

  /// A hovered emoji (slide to react) grows and rises out of the bar.
  static const double hoverScale = 1.45;
  static const double hoverLift = 12;

  /// Start scale of the bar, which springs out of the bubble's corner.
  static const double barFrom = .4;

  /// Start scale of every emoji, which pops in after the bar.
  static const double emojiFrom = .2;

  /// Delay before the first emoji pops.
  static const Duration emojiDelay = Duration(milliseconds: 40);

  /// Double-tap burst: the emoji pops at the finger and floats up.
  static const double burstEmoji = 44;
  static const double burstRise = 28;
  static const Duration burst = Duration(milliseconds: 720);

  /// Springs as curves with a visible-motion tolerance, so overlay routes
  /// settle (and their glass blurs) as soon as nothing moves visibly.
  static final NotionSpringCurve bouncyCurve = NotionSpringCurve(
    NotionMotion.bouncy,
    tolerance: .01,
  );
  static final NotionSpringCurve smoothCurve = NotionSpringCurve(
    NotionMotion.smooth,
    tolerance: .01,
  );

  /// Start of emoji [index]'s pop on the entrance timeline.
  static Duration emojiStart(int index) =>
      emojiDelay + NotionMotion.staggerFor(index);

  /// Length of the whole bar entrance for [slots] cells.
  static Duration barEntrance(int slots) {
    final emojis = emojiStart(math.max(0, slots - 1)) + bouncyCurve.duration;
    final bar = bouncyCurve.duration;
    return emojis > bar ? emojis : bar;
  }

  /// Bar width for [slots] cells.
  static double barWidth(int slots) => slots * barSlot + 2 * barPadding;

  /// Compares reaction keys without the emoji presentation selector, so a
  /// network's `❤` matches the picker's `❤️`.
  static String normalize(String key) => key.replaceAll('️', '');
}

/// Timeline helper: the part of [t] (0–1 over [total]) between [start] and
/// [start] + [length], mapped to 0–1.
double notionInterval(
  double t,
  Duration total,
  Duration start,
  Duration length,
) {
  if (total <= Duration.zero) return 1;
  final from = start.inMicroseconds / total.inMicroseconds;
  final span = length.inMicroseconds / total.inMicroseconds;
  if (span <= 0) return t >= from ? 1 : 0;
  return ((t - from) / span).clamp(0.0, 1.0);
}

/// A reaction under a bubble: a compact pill with the emoji and, from two
/// reactions on, a rolling count. Own reactions get a subtle tint and
/// hairline; nothing is square. Pops in when [popIn], pulses when the count
/// or own state changes, presses with a bounce.
class NotionReactionChip extends StatelessWidget {
  const NotionReactionChip({
    super.key,
    required this.emoji,
    required this.semanticLabel,
    this.count = 1,
    this.own = false,
    this.pending = false,
    this.ring,
    this.popIn = false,
    this.onTap,
    this.onLongPress,
  });

  /// The glyph (a `Text` emoji or a custom emoticon image).
  final Widget emoji;
  final String semanticLabel;
  final int count;
  final bool own;

  /// Waiting for the source network: drawn dimmed.
  final bool pending;

  /// Colour of the ring around the pill (the chat background), or none.
  final Color? ring;
  final bool popIn;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final fill = own
        ? Color.alphaBlend(colors.accent.withValues(alpha: .16), colors.surface)
        : colors.surface;
    final shape = StadiumBorder(
      side: own
          ? BorderSide(
              color: colors.accent.withValues(alpha: .4),
              width: NotionSize.border,
            )
          : BorderSide.none,
    );
    final ring = this.ring;
    Widget pill = Material(
      color: fill,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight:
                NotionReactions.chipHeight - 2 * NotionReactions.chipRing,
            minWidth: NotionReactions.chipHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs - 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: NotionSpace.xxs,
              children: [
                emoji,
                if (count > 1)
                  NotionAnimatedCount(
                    count: count,
                    style: NotionType.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color: own ? colors.text : colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ring != null) {
      pill = DecoratedBox(
        decoration: BoxDecoration(
          color: ring,
          borderRadius: NotionRadius.pillAll,
        ),
        child: Padding(
          padding: const EdgeInsets.all(NotionReactions.chipRing),
          child: pill,
        ),
      );
    }
    return Semantics(
      button: onTap != null,
      selected: own,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      // A new chip springs in; a changed count or own toggle pulses it.
      child: NotionPop(
        playOnMount: popIn,
        trigger: (count, own),
        child: NotionPressable(
          scale: NotionMotion.pressIcon,
          bounce: true,
          child: AnimatedOpacity(
            opacity: pending ? .55 : 1,
            duration: NotionMotion.of(context, NotionMotion.short),
            curve: NotionMotion.standard,
            child: pill,
          ),
        ),
      ),
    );
  }
}

/// The pill of quick reactions above a long-pressed bubble (Messenger,
/// Telegram): a glass pill with one 44 pt cell per emoji and an optional
/// "+" cell. Own reactions sit on a soft circle. [hovered] (a finger
/// sliding over the bar) grows and lifts that emoji; [chosen] pops while the
/// overlay leaves.
///
/// [entrance] is the overlay route's animation: forward, the pill springs
/// out of [origin] ([NotionReactions.barFrom] → 1, bouncy) and the emoji
/// pop in staggered; in reverse everything fades quickly. Null means at rest.
/// Pass a route animation, so the glass blurs only once it has settled.
class NotionReactionBar extends StatelessWidget {
  const NotionReactionBar({
    super.key,
    required this.reactions,
    required this.onSelected,
    this.selected = const {},
    this.hovered,
    this.chosen,
    this.onMore,
    this.moreLabel = 'More reactions',
    this.entrance,
    this.origin = Alignment.bottomCenter,
    this.slot = NotionReactions.barSlot,
  });

  final List<String> reactions;
  final ValueChanged<String> onSelected;

  /// Reactions this account already gave (normalized keys are compared).
  final Set<String> selected;

  /// Index of the cell under the finger ([reactions].length is "+").
  final int? hovered;
  final int? chosen;
  final VoidCallback? onMore;
  final String moreLabel;
  final Animation<double>? entrance;

  /// Scale origin of the spring-out (the corner nearest the bubble/touch).
  final Alignment origin;

  /// Cell size; narrower than [NotionReactions.barSlot] only when the bar
  /// would not fit the screen.
  final double slot;

  int get slots => reactions.length + (onMore == null ? 0 : 1);

  /// Index of the cell at [local] (bar coordinates), or null. [slop]
  /// extends the bar vertically, so a finger above or below still chooses.
  static int? slotAt(
    Offset local,
    int slots, {
    double slot = NotionReactions.barSlot,
    double slop = 0,
  }) {
    final height = slot + 2 * NotionReactions.barPadding;
    if (local.dy < -slop || local.dy > height + slop) return null;
    final x = local.dx - NotionReactions.barPadding;
    if (x < 0 || x >= slots * slot) return null;
    return (x / slot).floor();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedSelected = {
      for (final key in selected) NotionReactions.normalize(key),
    };
    final total = NotionReactions.barEntrance(slots);
    final cells = <Widget>[
      for (final (index, emoji) in reactions.indexed)
        _ReactionCell(
          key: ValueKey('reaction-$emoji'),
          index: index,
          total: total,
          slot: slot,
          entrance: entrance,
          hovered: hovered == index,
          chosen: chosen == index,
          own: normalizedSelected.contains(NotionReactions.normalize(emoji)),
          label: 'React $emoji',
          onTap: () => onSelected(emoji),
          child: Text(
            emoji,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize:
                  NotionReactions.barEmoji * slot / NotionReactions.barSlot,
              height: 1.15,
            ),
          ),
        ),
      if (onMore != null)
        _ReactionCell(
          key: const ValueKey('reaction-more'),
          index: reactions.length,
          total: total,
          slot: slot,
          entrance: entrance,
          hovered: hovered == reactions.length,
          chosen: false,
          own: false,
          more: true,
          label: moreLabel,
          onTap: onMore!,
          child: Icon(
            Icons.add_rounded,
            size: NotionSize.iconLg,
            color: context.notion.colors.textSecondary,
          ),
        ),
    ];
    final bar = SizedBox(
      height: slot + 2 * NotionReactions.barPadding,
      width: slots * slot + 2 * NotionReactions.barPadding,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned.fill(
            child: NotionGlassPanel(
              borderRadius: NotionRadius.pillAll,
              child: SizedBox.expand(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(NotionReactions.barPadding),
            child: Row(mainAxisSize: MainAxisSize.min, children: cells),
          ),
        ],
      ),
    );
    final animation = entrance;
    if (animation == null) return bar;
    return _BarEntrance(
      animation: animation,
      origin: origin,
      total: total,
      child: bar,
    );
  }
}

class _BarEntrance extends StatelessWidget {
  const _BarEntrance({
    required this.animation,
    required this.origin,
    required this.total,
    required this.child,
  });

  final Animation<double> animation;
  final Alignment origin;
  final Duration total;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      // One tree shape in every phase, so nothing remounts when it settles.
      final t = animation.value;
      double opacity;
      double scale;
      if (animation.status == AnimationStatus.reverse) {
        // Leaving: a quick fade with a small shrink.
        opacity = t;
        scale = .9 + .1 * t;
      } else if (t >= 1) {
        opacity = 1;
        scale = 1;
      } else {
        final local = notionInterval(
          t,
          total,
          Duration.zero,
          NotionReactions.bouncyCurve.duration,
        );
        final spring = NotionReactions.bouncyCurve.transform(local);
        opacity = local * 3;
        scale =
            NotionReactions.barFrom + (1 - NotionReactions.barFrom) * spring;
      }
      return Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(scale: scale, alignment: origin, child: child),
      );
    },
  );
}

class _ReactionCell extends StatelessWidget {
  const _ReactionCell({
    super.key,
    required this.index,
    required this.total,
    required this.slot,
    required this.entrance,
    required this.hovered,
    required this.chosen,
    required this.own,
    required this.label,
    required this.onTap,
    required this.child,
    this.more = false,
  });

  final int index;
  final Duration total;
  final double slot;
  final Animation<double>? entrance;
  final bool hovered;
  final bool chosen;
  final bool own;
  final bool more;
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final reduced = NotionMotion.reduced(context);
    final emphasis = hovered || chosen;
    // The hovered emoji grows and rises out of the bar (Messenger).
    final glyph = TweenAnimationBuilder<double>(
      tween: Tween(end: emphasis && !more ? 1 : 0),
      duration: reduced ? Duration.zero : NotionReactions.bouncyCurve.duration,
      curve: NotionReactions.bouncyCurve,
      child: child,
      builder: (context, v, child) => Transform.translate(
        offset: Offset(0, -NotionReactions.hoverLift * v),
        child: Transform.scale(
          scale: 1 + (NotionReactions.hoverScale - 1) * v,
          child: child,
        ),
      ),
    );
    Widget cell = SizedBox.square(
      dimension: slot,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (own || more)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: own
                      ? colors.accent.withValues(alpha: .18)
                      : colors.selected,
                ),
              ),
            ),
          glyph,
        ],
      ),
    );
    cell = Semantics(
      button: true,
      selected: own,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: NotionPressable(
          scale: NotionMotion.pressIcon,
          bounce: true,
          child: cell,
        ),
      ),
    );
    final entrance = this.entrance;
    if (entrance == null) return cell;
    return AnimatedBuilder(
      animation: entrance,
      child: cell,
      builder: (context, child) {
        // One tree shape in every phase, so nothing remounts when it settles.
        final t = entrance.value;
        var opacity = 1.0;
        var scale = 1.0;
        if (entrance.status == AnimationStatus.reverse) {
          // The chosen emoji pops away from the bar; the others just fade
          // with it.
          if (chosen) scale = 1 + .6 * (1 - t);
        } else if (t < 1) {
          final local = notionInterval(
            t,
            total,
            NotionReactions.emojiStart(index),
            NotionReactions.bouncyCurve.duration,
          );
          final spring = NotionReactions.bouncyCurve.transform(local);
          opacity = (local * 4).clamp(0.0, 1.0);
          scale =
              NotionReactions.emojiFrom +
              (1 - NotionReactions.emojiFrom) * spring;
        }
        return Opacity(
          opacity: opacity,
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}

/// The double-tap reward: [child] (an emoji) pops at the finger with a
/// bounce, floats up [NotionReactions.burstRise] and fades. Driven by
/// [animation] (0 → 1 over [NotionReactions.burst]); invisible at both ends,
/// so the owner removes it once the animation completes.
class NotionReactionBurst extends StatelessWidget {
  const NotionReactionBurst({
    super.key,
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  static const double _pop = .55;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            final t = animation.value.clamp(0.0, 1.0);
            final pop = NotionReactions.bouncyCurve.transform(
              (t / _pop).clamp(0.0, 1.0),
            );
            final fade = t < .6 ? (t / .12).clamp(0.0, 1.0) : (1 - t) / .4;
            return Transform.translate(
              offset: Offset(
                0,
                -NotionReactions.burstRise *
                    NotionMotion.emphasized.transform(t),
              ),
              child: Transform.scale(
                scale: .4 + .6 * pop,
                child: Opacity(opacity: fade.clamp(0.0, 1.0), child: child),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Places [child] (a row of reaction chips) so that it overlaps the bottom
/// edge of whatever sits above it by [overlap] (Messenger): it reports
/// [overlap] less height, paints and hit-tests [overlap] higher. Taps on the
/// chips win over the bubble beneath; the gaps between chips fall through.
class NotionReactionOverlap extends SingleChildRenderObjectWidget {
  const NotionReactionOverlap({
    super.key,
    this.overlap = NotionReactions.overlap,
    super.child,
  });

  final double overlap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderNotionReactionOverlap(overlap);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNotionReactionOverlap renderObject,
  ) => renderObject.overlap = overlap;
}

/// Render object of [NotionReactionOverlap].
class RenderNotionReactionOverlap extends RenderProxyBox {
  RenderNotionReactionOverlap(this._overlap);

  double _overlap;
  set overlap(double value) {
    if (value == _overlap) return;
    _overlap = value;
    markNeedsLayout();
  }

  Offset get _shift => Offset(0, -_overlap);

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, math.max(0, child.size.height - _overlap)),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final size = child.getDryLayout(constraints);
    return constraints.constrain(
      Size(size.width, math.max(0, size.height - _overlap)),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(0, super.computeMinIntrinsicHeight(width) - _overlap);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(0, super.computeMaxIntrinsicHeight(width) - _overlap);

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset + _shift);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.translateByDouble(0, -_overlap, 0, 1);

  // The chips extend above this box, so the own-size check of the default
  // hit test would drop taps on their upper part.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }
}

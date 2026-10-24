// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'conversation_grouping.dart';
import 'conversation_motion.dart';

/// Conversation-specific roles. The theme fills the outgoing side from the
/// user's accent and intensity (`NotionPalette`); incoming messages never
/// depend on that accent for identity.
@immutable
class ConversationBubbleColors
    extends ThemeExtension<ConversationBubbleColors> {
  final Color incoming;
  final Color outgoing;
  final Color text;
  final Color metadata;
  final Color? _outgoingText;

  /// Vivid own bubbles: a gradient instead of the solid [outgoing] fill.
  /// [outgoing] stays the solid stand-in for quotes and placeholders.
  final List<Color>? outgoingGradient;

  const ConversationBubbleColors({
    required this.incoming,
    required this.outgoing,
    required this.text,
    required this.metadata,
    Color? outgoingText,
    this.outgoingGradient,
  }) : _outgoingText = outgoingText;

  /// Text in own bubbles (white on a coloured fill); [text] by default.
  Color get outgoingText => _outgoingText ?? text;

  static const dark = ConversationBubbleColors(
    incoming: Color(0xFF2B2B2B),
    outgoing: Color(0xFF414141),
    text: Color(0xFFEEEEEC),
    metadata: Color(0xFFACACA8),
  );

  factory ConversationBubbleColors.light(ColorScheme scheme) =>
      ConversationBubbleColors(
        incoming: scheme.surfaceContainerLow,
        outgoing: scheme.surfaceContainerHighest,
        text: scheme.onSurface,
        metadata: scheme.onSurfaceVariant,
      );

  /// This side with its own bubble taken from [palette].
  ConversationBubbleColors withPalette(NotionPalette palette) =>
      ConversationBubbleColors(
        incoming: incoming,
        outgoing: palette.bubble,
        text: text,
        metadata: metadata,
        outgoingText: palette.onBubble,
        outgoingGradient: palette.bubbleGradient,
      );

  /// Registered by `NotionTheme`; the fallback keeps isolated fixtures working.
  static ConversationBubbleColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ConversationBubbleColors>() ??
        (theme.brightness == Brightness.dark
            ? dark
            : ConversationBubbleColors.light(theme.colorScheme));
  }

  @override
  ConversationBubbleColors copyWith({
    Color? incoming,
    Color? outgoing,
    Color? text,
    Color? metadata,
    Color? outgoingText,
  }) => ConversationBubbleColors(
    incoming: incoming ?? this.incoming,
    outgoing: outgoing ?? this.outgoing,
    text: text ?? this.text,
    metadata: metadata ?? this.metadata,
    outgoingText: outgoingText ?? _outgoingText,
    outgoingGradient: outgoingGradient,
  );

  @override
  ConversationBubbleColors lerp(
    covariant ConversationBubbleColors? other,
    double t,
  ) {
    if (other == null) return this;
    final a = outgoingGradient;
    final b = other.outgoingGradient;
    return ConversationBubbleColors(
      incoming: Color.lerp(incoming, other.incoming, t)!,
      outgoing: Color.lerp(outgoing, other.outgoing, t)!,
      text: Color.lerp(text, other.text, t)!,
      metadata: Color.lerp(metadata, other.metadata, t)!,
      outgoingText: Color.lerp(outgoingText, other.outgoingText, t),
      outgoingGradient: a != null && b != null && a.length == b.length
          ? [for (var i = 0; i < a.length; i++) Color.lerp(a[i], b[i], t)!]
          : (t < .5 ? a : b),
    );
  }
}

/// Presentation only: SDK content, selection, gestures and media remain owned
/// by the caller. No intrinsic sizing or extra recognizer surrounds the body.
class ConversationBubble extends StatelessWidget {
  final Widget body;
  final bool outgoing;
  final ConversationGroupPosition groupPosition;
  final Widget? avatar;
  final Widget? heading;
  final Widget? footer;
  final Widget? reactions;

  /// Quoted message of a reply, drawn above the fill. The bubble covers its
  /// bottom [NotionBubble.quoteOverlap] (Messenger style); build it with
  /// [ConversationReplyQuote], whose padding leaves room for that overlap.
  /// It moves with [surfaceBuilder] transforms, and its visible part keeps
  /// its own taps.
  final Widget? quote;

  /// Optional interaction wrapper around the completed, clipped fill. Its
  /// transforms move the fill and content together without moving the avatar,
  /// heading or metadata, and are not clipped by the stationary bubble bounds.
  final Widget Function(Widget surface)? surfaceBuilder;
  final bool media;
  final bool selected;

  /// The message a jump landed on: its fill flashes once (see
  /// [ConversationFlash]) instead of keeping an outline.
  final bool flash;
  final Color? backgroundColor;
  final double maxWidthFraction;

  /// Renders [body] without fill, clip or padding (round videos). Selection
  /// is published through [ConversationSelectionScope]; the body draws it as
  /// a circular ring with [ConversationSelectionRing].
  final bool chromeless;

  /// Shared Instagram posts and reels use a compact media frame.
  final bool compactMedia;

  const ConversationBubble({
    super.key,
    required this.body,
    required this.outgoing,
    this.groupPosition = ConversationGroupPosition.single,
    this.avatar,
    this.heading,
    this.footer,
    this.reactions,
    this.quote,
    this.surfaceBuilder,
    this.media = false,
    this.selected = false,
    this.flash = false,
    this.backgroundColor,
    this.maxWidthFraction = NotionBubble.maxWidthFraction,
    this.chromeless = false,
    this.compactMedia = false,
  }) : assert(maxWidthFraction > 0 && maxWidthFraction <= 1);

  /// Peak strength of the jump flash: the bubble's own text colour over its
  /// fill, so it reads on solid, gradient and private-palette bubbles.
  static const double flashOpacity = .22;

  bool get _startsGroup =>
      groupPosition == ConversationGroupPosition.single ||
      groupPosition == ConversationGroupPosition.first;

  bool get _endsGroup =>
      groupPosition == ConversationGroupPosition.single ||
      groupPosition == ConversationGroupPosition.last;

  BorderRadiusDirectional get _radius =>
      radiusFor(outgoing: outgoing, position: groupPosition);

  /// Grouped corners: the sender-side corners shrink where the bubble joins
  /// a neighbour. Media inside the fill uses the same shape.
  static BorderRadiusDirectional radiusFor({
    required bool outgoing,
    required ConversationGroupPosition position,
  }) {
    const outer = Radius.circular(NotionBubble.outer);
    const joined = Radius.circular(NotionBubble.joined);
    final starts =
        position == ConversationGroupPosition.single ||
        position == ConversationGroupPosition.first;
    final ends =
        position == ConversationGroupPosition.single ||
        position == ConversationGroupPosition.last;
    return BorderRadiusDirectional.only(
      topStart: !outgoing && !starts ? joined : outer,
      bottomStart: !outgoing && !ends ? joined : outer,
      topEnd: outgoing && !starts ? joined : outer,
      bottomEnd: outgoing && !ends ? joined : outer,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ConversationBubbleColors.of(context);
    final direction = Directionality.of(context);
    final crossAxis = outgoing
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    final radius = _radius.resolve(direction);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        // Large text and media get more room, retaining a visible direction gap.
        final largeText = MediaQuery.textScalerOf(context).scale(17) > 22;
        final fraction = largeText || media
            ? math.max(maxWidthFraction, .88)
            : maxWidthFraction;
        const avatarSlot = NotionBubble.avatarSlot;
        // Own bubbles take the accent fill (a gradient in Vivid) and its
        // text colour; a private chat palette overrides both.
        final ownFill = outgoing && backgroundColor == null;
        final gradient = ownFill ? colors.outgoingGradient : null;
        final ink = ownFill ? colors.outgoingText : colors.text;
        final maxWidth = math.max(
          0.0,
          math.min(
            width *
                fraction *
                (compactMedia ? NotionBubble.shareWidthFraction : 1),
            math.min(
              width - (outgoing ? 0 : avatarSlot),
              compactMedia
                  ? NotionBubble.mediaMaxWidth * NotionBubble.shareWidthFraction
                  : double.infinity,
            ),
          ),
        );
        final surface = chromeless
            // A round shows the jump flash as its selection ring.
            ? ConversationFlash(
                active: flash,
                builder: (context, f, child) => ConversationSelectionScope(
                  selected: selected || f > 0,
                  color: colors.text.withAlpha(140),
                  child: child!,
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: colors.text),
                  child: body,
                ),
              )
            : ClipRRect(
                borderRadius: radius,
                // The jump flash and the selection outline fade in and out
                // instead of snapping. The foreground decoration is always
                // there (empty at rest), so neither ever remounts the body.
                child: ConversationFlash(
                  active: flash,
                  builder: (context, f, child) => ConversationLazyTween(
                    value: selected ? 1 : 0,
                    builder: (context, t, child) => Container(
                      decoration: BoxDecoration(
                        color: gradient != null
                            ? null
                            : backgroundColor ??
                                  (outgoing
                                      ? colors.outgoing
                                      : colors.incoming),
                        gradient: gradient == null
                            ? null
                            : LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: gradient,
                              ),
                        borderRadius: radius,
                      ),
                      foregroundDecoration: BoxDecoration(
                        borderRadius: radius,
                        color: f <= 0
                            ? null
                            : ink.withValues(
                                alpha: flashOpacity * f.clamp(0.0, 1.0),
                              ),
                        border: t <= 0
                            ? null
                            : Border.all(
                                color: ink.withAlpha(
                                  (140 * t.clamp(0.0, 1.0)).round(),
                                ),
                                width: 2,
                              ),
                      ),
                      child: child,
                    ),
                    child: child,
                  ),
                  child: Padding(
                    padding: media ? EdgeInsets.zero : NotionBubble.padding,
                    // Wrapped text sizes to its longest line, so the fill
                    // shrink-wraps the text instead of keeping the ragged
                    // gap at line ends (Telegram, Messenger, WhatsApp).
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: ink),
                      textWidthBasis: TextWidthBasis.longestLine,
                      child: body,
                    ),
                  ),
                ),
              );
        final quote = this.quote;
        // The fill is painted after the quote, so it covers the overlap and
        // wins hit tests there; the visible quote above stays tappable.
        final quoted = quote == null
            ? surface
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: crossAxis,
                children: [
                  _OverlapBottom(
                    overlap: NotionBubble.quoteOverlap,
                    child: quote,
                  ),
                  surface,
                ],
              );
        final content = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAxis,
            children: [
              if (heading != null && _startsGroup)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 2,
                    end: 2,
                    bottom: 4,
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: colors.metadata),
                    child: heading!,
                  ),
                ),
              surfaceBuilder?.call(quoted) ?? quoted,
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.only(
            top: _startsGroup
                ? NotionBubble.seriesGap
                : (chromeless ? NotionBubble.roundGap : NotionBubble.groupGap),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAxis,
            children: [
              Row(
                mainAxisAlignment: outgoing
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!outgoing)
                    SizedBox(
                      width: avatarSlot,
                      child: Align(
                        alignment: AlignmentDirectional.bottomStart,
                        child: _endsGroup && avatar != null
                            ? SizedBox.square(
                                dimension: NotionBubble.avatar,
                                child: avatar,
                              )
                            : const SizedBox.square(
                                dimension: NotionBubble.avatar,
                              ),
                      ),
                    ),
                  Flexible(child: content),
                ],
              ),
              // Reaction chips overlap the bubble's bottom edge on the
              // sender side (Messenger), slightly inset from its corner.
              if (reactions != null)
                NotionReactionOverlap(
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: outgoing ? 0 : avatarSlot + NotionSpace.xs,
                      end: outgoing ? NotionSpace.xs : 0,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(0.0, maxWidth - NotionSpace.xs),
                      ),
                      child: reactions,
                    ),
                  ),
                ),
              if (footer != null)
                Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: outgoing ? 0 : avatarSlot,
                    top: 4,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: colors.metadata),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: crossAxis,
                        children: [footer!],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Selection state of a [ConversationBubble.chromeless] surface.
class ConversationSelectionScope extends InheritedWidget {
  final bool selected;
  final Color color;
  const ConversationSelectionScope({
    super.key,
    required this.selected,
    required this.color,
    required super.child,
  });

  static ConversationSelectionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConversationSelectionScope>();

  @override
  bool updateShouldNotify(ConversationSelectionScope oldWidget) =>
      selected != oldWidget.selected || color != oldWidget.color;
}

/// Circular 2 px selection ring for chromeless bubble content.
class ConversationSelectionRing extends StatelessWidget {
  final Widget child;
  const ConversationSelectionRing({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final scope = ConversationSelectionScope.maybeOf(context);
    if (scope == null || !scope.selected) return child;
    return DecoratedBox(
      key: const ValueKey('conversation-selection-ring'),
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: CircleBorder(side: BorderSide(color: scope.color, width: 2)),
      ),
      child: child,
    );
  }
}

/// Lays out [child] but reports it [overlap] shorter, so the next sibling in
/// a column starts over its bottom. Paints the whole child, unclipped; hit
/// tests only reach the reported (visible) part.
class _OverlapBottom extends SingleChildRenderObjectWidget {
  final double overlap;
  const _OverlapBottom({required this.overlap, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderOverlapBottom(overlap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderOverlapBottom renderObject,
  ) => renderObject.overlap = overlap;
}

class _RenderOverlapBottom extends RenderProxyBox {
  _RenderOverlapBottom(this._overlap);

  double _overlap;
  set overlap(double value) {
    if (value == _overlap) return;
    _overlap = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    final height = child.size.height - _overlap;
    size = constraints.constrain(
      Size(child.size.width, height < 0 ? 0 : height),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    final height = super.computeMinIntrinsicHeight(width) - _overlap;
    return height < 0 ? 0 : height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    final height = super.computeMaxIntrinsicHeight(width) - _overlap;
    return height < 0 ? 0 : height;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final size = child.getDryLayout(constraints.loosen());
    final height = size.height - _overlap;
    return constraints.constrain(Size(size.width, height < 0 ? 0 : height));
  }
}

/// Quoted original above a reply bubble: a muted pill of at most
/// [NotionBubble.quoteMaxLines] lines, with an optional [caption] above it
/// ("Anna replied to you") and an optional [leading] media thumbnail.
/// Presentation only; the caller resolves the original and its colours.
class ConversationReplyQuote extends StatelessWidget {
  final String text;
  final Widget? caption;
  final Widget? leading;
  final Color fill;
  final Color textColor;
  final bool outgoing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  const ConversationReplyQuote({
    super.key,
    required this.text,
    required this.fill,
    required this.textColor,
    required this.outgoing,
    this.caption,
    this.leading,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
  });

  /// Opaque quote colours for an original whose bubble is [side] on a chat
  /// background [page]: the fill is halfway to the page (so the reply
  /// bubble above it stands out), the text is [muted] or the closest
  /// readable blend.
  static ({Color fill, Color text}) colorsFor({
    required Color side,
    required Color page,
    required Color muted,
  }) {
    // A mid-tone blend (a light palette on a dark page) leaves no readable
    // text colour, so the fill moves back towards the bubble until one fits.
    for (var t = .5; t > 0; t -= .1) {
      final fill = Color.lerp(side, page, t)!.withValues(alpha: 1);
      final text = NotionContrast.readable(fill, muted);
      if (NotionContrast.ratio(text, fill) >= NotionContrast.minimum) {
        return (fill: fill, text: text);
      }
    }
    final fill = side.withValues(alpha: 1);
    return (fill: fill, text: NotionContrast.readable(fill, muted));
  }

  @override
  Widget build(BuildContext context) {
    final leading = this.leading;
    final caption = this.caption;
    final pill = Semantics(
      button: onTap != null,
      hint: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: const BorderRadius.all(
              Radius.circular(NotionBubble.outer),
            ),
          ),
          child: Padding(
            padding: leading == null
                ? NotionBubble.quotePadding
                : NotionBubble.quotePadding.copyWith(
                    left: NotionSpace.xxs + 2,
                    top: NotionSpace.xxs + 2,
                  ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[
                  ClipRRect(
                    borderRadius: const BorderRadius.all(
                      Radius.circular(NotionBubble.quoteThumbnailRadius),
                    ),
                    child: SizedBox.square(
                      dimension: NotionBubble.quoteThumbnail,
                      child: leading,
                    ),
                  ),
                  const SizedBox(width: NotionSpace.xs),
                ],
                Flexible(
                  child: Text(
                    text,
                    maxLines: NotionBubble.quoteMaxLines,
                    overflow: TextOverflow.ellipsis,
                    textWidthBasis: TextWidthBasis.longestLine,
                    style: NotionType.callout.copyWith(color: textColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (caption == null) return pill;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: outgoing
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Padding(padding: NotionBubble.captionPadding, child: caption),
        pill,
      ],
    );
  }
}

/// Reply caption: a small reply arrow and who replied to whom.
class ConversationReplyCaption extends StatelessWidget {
  final String label;
  final Color color;
  final Color? backdrop;
  const ConversationReplyCaption({
    super.key,
    required this.label,
    required this.color,
    this.backdrop,
  });

  @override
  Widget build(BuildContext context) => ConversationMetaChip(
    backdrop: backdrop,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: NotionSpace.xxs,
      children: [
        Icon(Icons.reply, size: NotionType.caption.fontSize, color: color),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NotionType.caption.copyWith(color: color),
          ),
        ),
      ],
    ),
  );
}

/// Metadata (time, reply caption) that sits on the chat background. Over a
/// wallpaper it gets a [backdrop] chip so it stays readable; otherwise it is
/// drawn as is.
class ConversationMetaChip extends StatelessWidget {
  final Widget child;
  final Color? backdrop;
  const ConversationMetaChip({super.key, required this.child, this.backdrop});

  @override
  Widget build(BuildContext context) {
    final backdrop = this.backdrop;
    if (backdrop == null) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backdrop.withValues(alpha: NotionBubble.metaChipOpacity),
        borderRadius: NotionRadius.pillAll,
      ),
      child: Padding(padding: NotionBubble.metaChipPadding, child: child),
    );
  }
}

/// The one size rule for media inside a bubble (images, videos, Instagram
/// reels shared through the Meta bridge, which arrive as `m.video`): the
/// frame fills the bubble's width up to [NotionBubble.mediaMaxWidth] and
/// keeps the media's aspect ratio between [NotionBubble.mediaMinAspect] and
/// [NotionBubble.mediaMaxAspect]; whatever lies beyond is cropped
/// (`BoxFit.cover`), like Messenger. Unknown dimensions give a square.
/// Pure arithmetic: nothing is measured or laid out twice.
abstract final class ConversationMedia {
  static Size frame({
    required double maxWidth,
    num? width,
    num? height,
    double maxHeight = double.infinity,
  }) {
    final frameWidth = math.max(
      0.0,
      math.min(maxWidth, NotionBubble.mediaMaxWidth),
    );
    final aspect = width != null && height != null && width > 0 && height > 0
        ? (height / width).clamp(
            NotionBubble.mediaMinAspect,
            NotionBubble.mediaMaxAspect,
          )
        : 1.0;
    final frameHeight = math.min(frameWidth * aspect, maxHeight);
    return Size(frameWidth, math.max(0.0, frameHeight));
  }

  /// Smallest long side of a sticker (small phones, the old fixed size).
  static const double stickerMinSide = 128;

  /// Largest long side on a phone (Telegram: about 205 dp on a Pixel 8).
  static const double stickerMaxSide = 200;

  /// Largest long side on a desktop or a tablet-sized window, where half
  /// the short side would be huge next to the text.
  static const double stickerWideSide = 180;

  /// Share of the screen's short side a sticker takes (Telegram
  /// `ChatMessageCell`: `min(width, height) * 0.5` on phones).
  static const double stickerScreenShare = .5;

  /// The short side (logical px) from which a window counts as wide.
  static const double stickerWideBreakpoint = 600;

  /// Short side of the shortest sticker edge (a very wide sticker).
  static const double stickerMinEdge = 32;

  /// The long side of a sticker (image, Lottie or video) on [screen]:
  /// half the short side, between [stickerMinSide] and [stickerMaxSide]
  /// (phones) or [stickerWideSide] ([desktop] or a wide window).
  static double stickerSideFor(Size screen, {required bool desktop}) {
    final wide = desktop || screen.shortestSide >= stickerWideBreakpoint;
    final share = screen.shortestSide * stickerScreenShare;
    return share.clamp(stickerMinSide, wide ? stickerWideSide : stickerMaxSide);
  }

  /// [stickerSideFor] the current screen.
  static double stickerSide(BuildContext context, {required bool desktop}) =>
      stickerSideFor(MediaQuery.sizeOf(context), desktop: desktop);

  /// A sticker's box: [side] on the long edge, aspect kept, the short edge
  /// at least [stickerMinEdge]; square without dimensions.
  static Size stickerFrame(double side, {num? width, num? height}) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return Size.square(side);
    }
    if (width > height) {
      return Size(side, (side * height / width).clamp(stickerMinEdge, side));
    }
    return Size((side * width / height).clamp(stickerMinEdge, side), side);
  }

  /// Height limit of a frame: a share of the viewport, and the incoming
  /// [constraints] (grid tiles).
  static double maxHeightOf(BuildContext context, BoxConstraints constraints) =>
      math.min(
        MediaQuery.sizeOf(context).height *
            NotionBubble.mediaMaxViewportFraction,
        constraints.maxHeight,
      );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'conversation_grouping.dart';

/// Conversation-specific roles. Themes may override these for a personal
/// accent without making an incoming message depend on that accent for identity.
@immutable
class ConversationBubbleColors
    extends ThemeExtension<ConversationBubbleColors> {
  final Color incoming;
  final Color outgoing;
  final Color text;
  final Color metadata;

  const ConversationBubbleColors({
    required this.incoming,
    required this.outgoing,
    required this.text,
    required this.metadata,
  });

  static ConversationBubbleColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ConversationBubbleColors>() ??
        (theme.brightness == Brightness.dark
            ? const ConversationBubbleColors(
                incoming: Color(0xFF2B2B2B),
                outgoing: Color(0xFF414141),
                text: Color(0xFFEEEEEC),
                metadata: Color(0xFFACACA8),
              )
            : ConversationBubbleColors(
                incoming: theme.colorScheme.surfaceContainerLow,
                outgoing: theme.colorScheme.surfaceContainerHighest,
                text: theme.colorScheme.onSurface,
                metadata: theme.colorScheme.onSurfaceVariant,
              ));
  }

  @override
  ConversationBubbleColors copyWith({
    Color? incoming,
    Color? outgoing,
    Color? text,
    Color? metadata,
  }) => ConversationBubbleColors(
    incoming: incoming ?? this.incoming,
    outgoing: outgoing ?? this.outgoing,
    text: text ?? this.text,
    metadata: metadata ?? this.metadata,
  );

  @override
  ConversationBubbleColors lerp(
    covariant ConversationBubbleColors? other,
    double t,
  ) {
    if (other == null) return this;
    return ConversationBubbleColors(
      incoming: Color.lerp(incoming, other.incoming, t)!,
      outgoing: Color.lerp(outgoing, other.outgoing, t)!,
      text: Color.lerp(text, other.text, t)!,
      metadata: Color.lerp(metadata, other.metadata, t)!,
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

  /// Optional interaction wrapper around the completed, clipped fill. Its
  /// transforms move the fill and content together without moving the avatar,
  /// heading or metadata, and are not clipped by the stationary bubble bounds.
  final Widget Function(Widget surface)? surfaceBuilder;
  final bool media;
  final bool selected;
  final Color? backgroundColor;
  final double maxWidthFraction;

  const ConversationBubble({
    super.key,
    required this.body,
    required this.outgoing,
    this.groupPosition = ConversationGroupPosition.single,
    this.avatar,
    this.heading,
    this.footer,
    this.reactions,
    this.surfaceBuilder,
    this.media = false,
    this.selected = false,
    this.backgroundColor,
    this.maxWidthFraction = .78,
  }) : assert(maxWidthFraction > 0 && maxWidthFraction <= 1);

  bool get _startsGroup =>
      groupPosition == ConversationGroupPosition.single ||
      groupPosition == ConversationGroupPosition.first;

  bool get _endsGroup =>
      groupPosition == ConversationGroupPosition.single ||
      groupPosition == ConversationGroupPosition.last;

  BorderRadiusDirectional get _radius {
    const outer = Radius.circular(20);
    const joined = Radius.circular(5);
    return BorderRadiusDirectional.only(
      topStart: !outgoing && !_startsGroup ? joined : outer,
      bottomStart: !outgoing && !_endsGroup ? joined : outer,
      topEnd: outgoing && !_startsGroup ? joined : outer,
      bottomEnd: outgoing && !_endsGroup ? joined : outer,
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
        const avatarSlot = 36.0;
        final maxWidth = math.max(
          0.0,
          math.min(width * fraction, width - (outgoing ? 0 : avatarSlot)),
        );
        final surface = ClipRRect(
          borderRadius: radius,
          child: Container(
            decoration: BoxDecoration(
              color:
                  backgroundColor ??
                  (outgoing ? colors.outgoing : colors.incoming),
              borderRadius: radius,
            ),
            foregroundDecoration: selected
                ? BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: colors.text.withAlpha(140),
                      width: 2,
                    ),
                  )
                : null,
            child: Padding(
              padding: media
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: colors.text),
                child: body,
              ),
            ),
          ),
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
              surfaceBuilder?.call(surface) ?? surface,
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.only(top: _startsGroup ? 15 : 3),
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
                            ? SizedBox.square(dimension: 28, child: avatar)
                            : const SizedBox.square(dimension: 28),
                      ),
                    ),
                  Flexible(child: content),
                ],
              ),
              if (reactions != null || footer != null)
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
                        children: [
                          if (reactions != null) reactions!,
                          if (footer != null)
                            Padding(
                              padding: EdgeInsets.only(
                                top: reactions == null ? 0 : 3,
                              ),
                              child: footer!,
                            ),
                        ],
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

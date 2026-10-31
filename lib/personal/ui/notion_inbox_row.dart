// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_inbox_network_badge.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Diameter of the manual-unread dot.
const double _unreadDot = 10;

/// Diameter of a typing dot in the preview line (the dots are 4.5× as wide).
const double _typingDot = 4;

/// The actual inbox row presenter, also used by account-free visual captures.
class NotionInboxRow extends StatelessWidget {
  final Widget avatar;
  final String name;
  final String preview;
  final String? time;
  final int unreadCount;
  final bool unread;

  /// Somebody mentioned the account (`highlightCount`): an accent "@" badge
  /// beside the count, also in muted chats (Telegram).
  final bool mentioned;

  /// The last own message was not sent: a danger mark before the preview
  /// (Telegram, Messenger).
  final bool failed;

  /// Ticks of the last message when it is own (Telegram's dialog list):
  /// drawn before the time; null for none.
  final NotionDeliveryState? delivery;
  final bool selected;
  final bool muted;
  final String? notificationLabel;
  final bool draft;
  final bool redacted;

  /// Someone is typing: [preview] holds the typing text, shown in the accent
  /// colour after three animated dots (Telegram).
  final bool typing;

  /// Pinned chat: a pin glyph pops into the badge slot while nothing is
  /// unread.
  final bool pinned;
  final Widget? previewLeading;
  final Widget? action;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// A value that changes when this conversation receives something new
  /// (and usually moves to the top): the row flashes a soft highlight once.
  /// Null on first build and for own messages, so nothing flashes on scroll.
  final Object? highlight;

  /// Flash once on first build too (a row a merge or unmerge just created).
  final bool highlightOnMount;

  /// Networks marked on the avatar (UX-17, FT-12): set only while the inbox
  /// shows all networks; two stacked marks for a merged person. Empty: none.
  final List<String> networks;

  /// A short tag before the preview, e.g. "Request" for a message request
  /// not accepted yet (FX-02). Null: none.
  final String? tag;
  const NotionInboxRow({
    super.key,
    required this.avatar,
    required this.name,
    required this.preview,
    required this.onTap,
    this.time,
    this.unreadCount = 0,
    this.unread = false,
    this.mentioned = false,
    this.failed = false,
    this.delivery,
    this.selected = false,
    this.muted = false,
    this.notificationLabel,
    this.draft = false,
    this.redacted = false,
    this.typing = false,
    this.pinned = false,
    this.previewLeading,
    this.action,
    this.onLongPress,
    this.highlight,
    this.highlightOnMount = false,
    this.networks = const [],
    this.tag,
  });

  @override
  Widget build(BuildContext context) {
    final display = NotionDisplayPreferences.of(context);
    final scale = display.inboxScale;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final colors = context.notion.colors;
    final hasUnread = unreadCount > 0 || unread;
    // Unread: tinted row, bold name, brighter preview, accent badge; muted chats keep a
    // grey badge so they do not compete with chats that notify.
    final palette = context.notion.palette;
    final rowColor = selected
        ? colors.selected
        : hasUnread && !muted && display.inboxUnreadHighlight
        ? palette.accentTint
        : colors.background;
    final unreadInk = NotionContrast.readable(rowColor, colors.accent);
    final badgeColor = muted ? colors.selected : palette.accentFill;
    final badgeText = muted ? colors.textSecondary : palette.onAccentFill;
    final announcement = [
      name,
      preview,
      ?time,
      if (failed) 'Last message not sent',
      if (delivery case final state?)
        'Last message ${NotionDeliveryTick.labelOf(state).toLowerCase()}',
      if (mentioned) 'You were mentioned',
      if (unreadCount > 0)
        '$unreadCount unread messages'
      else if (unread)
        'Unread',
      if (muted) notificationLabel ?? 'Notifications limited',
      if (pinned) 'Pinned',
      ?tag,
      ?notionNetworksAnnouncement(networks),
    ];
    final previewColor = typing
        ? colors.accent
        : hasUnread && !muted && !draft && !redacted
        ? colors.text
        : secondary;
    return Semantics(
      button: true,
      selected: selected,
      label: announcement.join(', '),
      onTap: onTap,
      onLongPress: onLongPress,
      child: NotionRowHighlight(
        trigger: highlight,
        playOnMount: highlightOnMount,
        borderRadius: NotionRadius.rowAll,
        child: NotionPressable(
          scale: NotionMotion.pressRow,
          // The selected background follows the open conversation; an
          // unread row rests on the accent tint.
          child: _SelectedBackground(
            selected: selected,
            color: colors.selected,
            restColor:
                hasUnread && !muted && !selected && display.inboxUnreadHighlight
                ? palette.accentTint
                : null,
            child: Material(
              type: MaterialType.transparency,
              borderRadius: NotionRadius.rowAll,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                onSecondaryTap: onLongPress,
                borderRadius: NotionRadius.rowAll,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: NotionSpace.xs,
                    vertical: NotionSpace.lg * scale,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight:
                          NotionSize.touchTarget - 2 * NotionSpace.lg * scale,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (display.inboxAvatars)
                          ExcludeSemantics(
                            child: SizedBox.square(
                              dimension: NotionSize.avatarLg * scale,
                              // One shape with or without the badge, so the
                              // avatar keeps its element when the network
                              // filter changes (no image reload).
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(child: avatar),
                                  if (networks.isNotEmpty &&
                                      display.inboxNetworkBadges)
                                    PositionedDirectional(
                                      end: -NotionSpace.xxs,
                                      bottom: -NotionSpace.xxs,
                                      child: NotionInboxNetworkBadge(
                                        networks: networks,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (display.inboxAvatars)
                          SizedBox(width: NotionSpace.sm * scale),
                        Expanded(
                          child: ExcludeSemantics(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        name,
                                        maxLines: large ? 2 : 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: NotionType.headline
                                            .apply(
                                              fontSizeFactor: (1 + scale) / 2,
                                            )
                                            .copyWith(
                                              height: 1.25,
                                              color: hasUnread && !muted
                                                  ? unreadInk
                                                  : colors.text,
                                              fontWeight: hasUnread
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                      ),
                                    ),
                                    // Muting pops the bell in and out; the first
                                    // build shows it as is.
                                    NotionLazySwitcher(
                                      style: NotionLazySwitch.morph,
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: muted
                                          ? Padding(
                                              key: const ValueKey('muted'),
                                              padding:
                                                  const EdgeInsetsDirectional.only(
                                                    start: NotionSpace.xxs,
                                                  ),
                                              child: Icon(
                                                Icons
                                                    .notifications_off_outlined,
                                                size: NotionType
                                                    .footnote
                                                    .fontSize,
                                                color: secondary,
                                              ),
                                            )
                                          : const SizedBox.shrink(
                                              key: ValueKey('not-muted'),
                                            ),
                                    ),
                                  ],
                                ),
                                if (display.inboxPreviews || typing) ...[
                                  SizedBox(height: NotionSpace.xs * scale),
                                  Row(
                                    children: [
                                      if (tag != null) ...[
                                        _InboxTag(label: tag!),
                                        const SizedBox(width: NotionSpace.xxs),
                                      ],
                                      if (failed) ...[
                                        Icon(
                                          Icons.error_outline,
                                          key: const ValueKey(
                                            'notion_inbox_failed',
                                          ),
                                          size: NotionType.footnote.fontSize,
                                          color: colors.danger,
                                        ),
                                        const SizedBox(width: NotionSpace.xxs),
                                      ] else if (previewLeading != null) ...[
                                        previewLeading!,
                                        const SizedBox(width: 4),
                                      ],
                                      // Typing dots grow in before the text and
                                      // shrink away when the message arrives.
                                      NotionSizeReveal(
                                        visible: typing,
                                        axis: Axis.horizontal,
                                        alignment:
                                            AlignmentDirectional.centerStart,
                                        duration: NotionMotion.short,
                                        child: Padding(
                                          padding:
                                              const EdgeInsetsDirectional.only(
                                                end: NotionSpace.xxs,
                                              ),
                                          child: NotionTypingDots(
                                            size: _typingDot,
                                            color: colors.accent,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: NotionLazySwitcher(
                                          child: Text(
                                            preview,
                                            key: ValueKey((preview, typing)),
                                            maxLines: large
                                                ? 2
                                                : display.inboxPreviewLines,
                                            overflow: TextOverflow.ellipsis,
                                            style: NotionType.callout
                                                .apply(
                                                  fontSizeFactor:
                                                      (1 + scale) / 2,
                                                )
                                                .copyWith(
                                                  height: 1.3,
                                                  color: previewColor,
                                                  // A draft, or the muted
                                                  // words of a deleted
                                                  // message (as its bubble).
                                                  fontStyle: draft || redacted
                                                      ? FontStyle.italic
                                                      : null,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (time != null && display.inboxTimestamps)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (delivery case final state?) ...[
                                      NotionDeliveryTick(
                                        key: const ValueKey(
                                          'notion_inbox_delivery',
                                        ),
                                        state: state,
                                        color: secondary,
                                        size:
                                            NotionDeliveryTick.defaultSize + 2,
                                      ),
                                      const SizedBox(width: 2),
                                    ],
                                    NotionLazySwitcher(
                                      alignment: AlignmentDirectional.topEnd,
                                      child: Text(
                                        time!,
                                        key: ValueKey(time),
                                        style: NotionType.footnote.copyWith(
                                          color: hasUnread && !muted
                                              ? unreadInk
                                              : secondary,
                                          fontWeight: hasUnread
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              // The badge pops in when the first unread arrives,
                              // pulses and rolls its number on every new one, and
                              // shrinks away once read. Rows built by scrolling
                              // show it as is (a switcher never animates its first
                              // child).
                              NotionLazySwitcher(
                                style: NotionLazySwitch.morph,
                                bounce: true,
                                alignment: AlignmentDirectional.topEnd,
                                child: unreadCount > 0
                                    ? Padding(
                                        key: ValueKey(('count', mentioned)),
                                        padding: const EdgeInsets.only(
                                          top: NotionSpace.xxs,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (mentioned) ...[
                                              _MentionBadge(
                                                color: palette.accentFill,
                                                text: palette.onAccentFill,
                                              ),
                                              const SizedBox(
                                                width: NotionSpace.xxs,
                                              ),
                                            ],
                                            NotionPop(
                                              trigger: unreadCount,
                                              playOnMount: false,
                                              child: Container(
                                                constraints:
                                                    const BoxConstraints(
                                                      minWidth: 20,
                                                      minHeight: 20,
                                                    ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 1,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: badgeColor,
                                                  borderRadius:
                                                      NotionRadius.pillAll,
                                                ),
                                                alignment: Alignment.center,
                                                child: NotionAnimatedCount(
                                                  count: unreadCount,
                                                  style: NotionType.caption
                                                      .copyWith(
                                                        color: badgeText,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : mentioned
                                    ? Padding(
                                        key: const ValueKey('mention'),
                                        padding: const EdgeInsets.only(
                                          top: NotionSpace.xxs,
                                        ),
                                        child: _MentionBadge(
                                          color: palette.accentFill,
                                          text: palette.onAccentFill,
                                        ),
                                      )
                                    : unread
                                    // Marked unread by hand: a plain dot, no count.
                                    ? Padding(
                                        key: const ValueKey('dot'),
                                        padding: const EdgeInsets.only(
                                          top: NotionSpace.xs,
                                        ),
                                        child: Container(
                                          key: const ValueKey(
                                            'notion_inbox_unread_dot',
                                          ),
                                          width: _unreadDot,
                                          height: _unreadDot,
                                          decoration: BoxDecoration(
                                            color: badgeColor,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      )
                                    : pinned
                                    // Pinned and read: the pin takes the slot
                                    // (Telegram); it pops in on pinning.
                                    ? Padding(
                                        key: const ValueKey('pinned'),
                                        padding: const EdgeInsets.only(
                                          top: NotionSpace.xxs,
                                        ),
                                        child: Icon(
                                          Icons.push_pin_outlined,
                                          key: const ValueKey(
                                            'notion_inbox_pin',
                                          ),
                                          size: NotionType.body.fontSize,
                                          color: secondary,
                                        ),
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey('read'),
                                      ),
                              ),
                            ],
                          ),
                        ),
                        ?action,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "@": somebody mentioned the account. Accent even in muted chats, so a
/// mention never drowns among grey badges (Telegram's `drawMention`).
/// A quiet pill before the preview ("Request"): opaque, it scrolls.
class _InboxTag extends StatelessWidget {
  final String label;
  const _InboxTag({required this.label});

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    return DecoratedBox(
      key: const ValueKey('notion_inbox_tag'),
      decoration: BoxDecoration(
        color: notion.colors.selected,
        borderRadius: NotionRadius.pillAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
        child: Text(
          label,
          maxLines: 1,
          style: notion.typography.captionMuted.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _MentionBadge extends StatelessWidget {
  const _MentionBadge({required this.color, required this.text});

  final Color color;
  final Color text;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('notion_inbox_mention'),
    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, borderRadius: NotionRadius.pillAll),
    child: Text(
      '@',
      style: NotionType.caption.copyWith(
        color: text,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// The selected row background, tweened when the open conversation changes.
/// No controller exists until [selected] first changes (rows built while
/// scrolling cost no ticker; an `AnimatedContainer` creates one per mount).
class _SelectedBackground extends StatefulWidget {
  const _SelectedBackground({
    required this.selected,
    required this.color,
    required this.child,
    this.restColor,
  });

  final bool selected;
  final Color color;

  /// The resting background under the selection (the unread tint).
  final Color? restColor;
  final Widget child;

  @override
  State<_SelectedBackground> createState() => _SelectedBackgroundState();
}

class _SelectedBackgroundState extends State<_SelectedBackground>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didUpdateWidget(_SelectedBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected) return;
    final target = widget.selected ? 1.0 : 0.0;
    if (NotionMotion.reduced(context)) {
      // Without a controller, build paints [selected] as it is.
      _controller?.value = target;
      return;
    }
    final controller = _controller ??= AnimationController(
      vsync: this,
      value: 1 - target,
      duration: NotionMotion.quick,
    );
    controller.animateTo(target, curve: NotionMotion.standard);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return DecoratedBox(
      key: const ValueKey('notion_inbox_row_tint'),
      decoration: BoxDecoration(
        color: widget.restColor ?? Colors.transparent,
        borderRadius: NotionRadius.rowAll,
      ),
      child: CustomPaint(
        painter: _SelectionPainter(
          animation:
              controller ??
              (widget.selected
                  ? kAlwaysCompleteAnimation
                  : kAlwaysDismissedAnimation),
          color: widget.color,
        ),
        child: widget.child,
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter({required this.animation, required this.color})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    if (t <= 0) return;
    canvas.drawRRect(
      NotionRadius.rowAll.toRRect(Offset.zero & size),
      Paint()..color = color.withValues(alpha: color.a * t),
    );
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.color != color || !identical(old.animation, animation);
}

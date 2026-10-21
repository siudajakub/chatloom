// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'composer_action_tray.dart';
import 'conversation_motion.dart';

export 'composer_action_tray.dart' show ComposerAction, ComposerAnchorBuilder;

/// Presentation only: the caller retains the editor, controller, focus and IME.
///
/// Only the source changes slots at the compact breakpoint, and the inline
/// action tray only changes its own width. In particular the editor's
/// ancestors and child index stay identical through a resize, while the tray
/// opens or closes and while an [inputOverlay] covers the field.
class CompactComposer extends StatefulWidget {
  final Widget input;
  final Widget source;

  /// Legacy custom "+" control. Ignored when [actions] is provided.
  final Widget? addAction;
  final Widget primaryAction;

  /// A second action beside [primaryAction] on its start side, for example
  /// the round video button next to the voice mic. Null hides it: the slot
  /// shrinks and fades out (and grows back) while the primary action morphs,
  /// so the editor gains the room smoothly. Its slot is always in the row.
  final Widget? secondaryAction;
  final double sourceWidth;
  final Widget? contextPreview;

  /// Inline actions revealed by the composer's own "+" button.
  final List<ComposerAction>? actions;

  /// Disables the "+" button (and collapses an open tray) when false.
  final bool actionsEnabled;

  /// The tray collapses on the first non-empty text of this controller.
  final TextEditingController? collapseOnText;
  final ValueChanged<bool>? onExpandedChanged;

  /// Any change (reply/edit, room, source, recording) collapses the tray.
  final Object? collapseToken;

  /// Covers the field (source and editor) without replacing the editor, for
  /// example while a voice message is being held.
  final Widget? inputOverlay;

  const CompactComposer({
    super.key,
    required this.input,
    required this.source,
    this.addAction,
    required this.primaryAction,
    this.secondaryAction,
    this.sourceWidth = 0,
    this.contextPreview,
    this.actions,
    this.actionsEnabled = true,
    this.collapseOnText,
    this.onExpandedChanged,
    this.collapseToken,
    this.inputOverlay,
  }) : assert(sourceWidth >= 0),
       assert(addAction != null || actions != null);

  @override
  State<CompactComposer> createState() => _CompactComposerState();
}

class _CompactComposerState extends State<CompactComposer>
    with SingleTickerProviderStateMixin {
  // Insets + both 48dp actions + gaps (16 + 48 + 4 + 4 + 48).
  static const double _rowChrome = 120;
  // Divider + editor padding inside the field.
  static const double _fieldChrome = 13;
  // Collapsed editor minimum that decides whether the source stays inline.
  static const double _editorMin = 120;

  late final AnimationController _tray = AnimationController(
    vsync: this,
    duration: ComposerTrayLayout.duration,
  );
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: _tray,
    curve: ComposerTrayLayout.curve,
    reverseCurve: NotionMotion.exitFast,
  );
  bool _expanded = false;
  String _lastText = '';

  /// The last [CompactComposer.secondaryAction], kept while its slot closes.
  Widget? _secondary;

  bool get _hasActions =>
      widget.actions != null &&
      widget.actions!.isNotEmpty &&
      widget.actionsEnabled;

  @override
  void initState() {
    super.initState();
    _lastText = widget.collapseOnText?.text ?? '';
    widget.collapseOnText?.addListener(_textChanged);
    _secondary = widget.secondaryAction;
  }

  @override
  void didUpdateWidget(CompactComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _secondary = widget.secondaryAction ?? _secondary;
    if (!identical(oldWidget.collapseOnText, widget.collapseOnText)) {
      oldWidget.collapseOnText?.removeListener(_textChanged);
      _lastText = widget.collapseOnText?.text ?? '';
      widget.collapseOnText?.addListener(_textChanged);
    }
    if (_expanded &&
        (oldWidget.collapseToken != widget.collapseToken ||
            !identical(oldWidget.collapseOnText, widget.collapseOnText) ||
            !_hasActions)) {
      // Already rebuilding: change state directly, notify after the frame.
      _apply(false);
    }
  }

  @override
  void dispose() {
    widget.collapseOnText?.removeListener(_textChanged);
    _progress.dispose();
    _tray.dispose();
    super.dispose();
  }

  void _textChanged() {
    final text = widget.collapseOnText?.text ?? '';
    if (text == _lastText) return;
    _lastText = text;
    if (_expanded && text.trim().isNotEmpty) _setExpanded(false);
  }

  void _setExpanded(bool value) {
    if (_expanded == value || !mounted) return;
    setState(() => _apply(value));
  }

  void _apply(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    if (ConversationMotion.reduced(context)) {
      _tray.value = value ? 1 : 0;
    } else if (value) {
      _tray.forward();
    } else {
      _tray.reverse();
    }
    final notify = widget.onExpandedChanged;
    if (notify != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expanded == value) notify(value);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  Widget _addButton(BuildContext context) {
    final legacy = widget.addAction;
    if (widget.actions == null && legacy != null) return legacy;
    final reduced = ConversationMotion.reduced(context);
    return MergeSemantics(
      child: Semantics(
        expanded: _expanded,
        child: IconButton(
          tooltip: _expanded ? 'Hide message actions' : 'More message actions',
          onPressed: _hasActions ? () => _setExpanded(!_expanded) : null,
          icon: AnimatedRotation(
            turns: _expanded ? 0.125 : 0,
            duration: reduced ? Duration.zero : ComposerTrayLayout.duration,
            curve: ComposerTrayLayout.curve,
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final chip = widget.source;
      final measuredSourceWidth = math.max(
        widget.sourceWidth,
        chip is ConversationSourceChip ? chip.preferredWidth(context) : 0.0,
      );
      final inline =
          constraints.maxWidth >=
          measuredSourceWidth + _rowChrome + _fieldChrome + _editorMin;
      final actions = widget.actions ?? const <ComposerAction>[];
      // The secondary action only takes room from the editor. It never moves
      // the source out of line: the composer would change height as the
      // first letter hides it. It shows only while the editor is empty.
      final secondaryWidth = widget.secondaryAction == null
          ? 0.0
          : NotionSize.touchTarget;
      double roomBeside(double source) => math.max(
        0.0,
        constraints.maxWidth -
            _rowChrome -
            secondaryWidth -
            source -
            _fieldChrome,
      );
      int slotsIn(double room) => math.max(
        0,
        ((room - ComposerTrayLayout.expandedEditorMin) /
                ComposerTrayLayout.slot)
            .floor(),
      );
      int shownSlots(int slots) => ComposerTrayLayout.slotsFor(
        actions.length,
        math.max(slots, math.min(actions.length, 2)),
      );
      // Inline source plus its divider.
      final sourceFixed = inline ? measuredSourceWidth + 1 : 0.0;
      final roomWithSource = roomBeside(sourceFixed);
      // At narrow widths the open tray would squeeze the editor to a sliver:
      // the inline source then yields its width to the tray while it is open.
      final yieldSource =
          inline &&
          actions.isNotEmpty &&
          roomWithSource -
                  shownSlots(slotsIn(roomWithSource)) *
                      ComposerTrayLayout.slot <
              _editorMin;
      final trayRoom = yieldSource ? roomBeside(0) : roomWithSource;
      final slots = slotsIn(trayRoom);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Keep both slots present, including when there is no preview.
            widget.contextPreview ?? const SizedBox.shrink(),
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: 52,
                end: 52,
                bottom: inline ? 0 : NotionSpace.xxs,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: inline ? const SizedBox.shrink() : widget.source,
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox.square(
                  dimension: NotionSize.touchTarget,
                  child: _addButton(context),
                ),
                // Always present so the editor keeps its index in this row.
                ComposerActionTray(
                  actions: actions,
                  progress: _progress,
                  slots: math.max(slots, math.min(actions.length, 2)),
                  maxWidth: trayRoom,
                  interactive: _expanded && _hasActions,
                  reduceMotion: ConversationMotion.reduced(context),
                  onUsed: (_) => _setExpanded(false),
                ),
                const SizedBox(width: NotionSpace.xxs),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: NotionRadius.fieldAll,
                    ),
                    // A new line grows the field smoothly (the caret line
                    // stays in view) instead of snapping the composer taller.
                    child: AnimatedSize(
                      duration: ConversationMotion.sizeDuration(
                        context,
                        NotionMotion.quick,
                      ),
                      curve: NotionMotion.standard,
                      alignment: Alignment.bottomCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 50),
                        child: Stack(
                          fit: StackFit.passthrough,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _InlineSource(
                                  progress: _progress,
                                  width: inline ? measuredSourceWidth : 0,
                                  yields: yieldSource,
                                  hidden: yieldSource && _expanded,
                                  child: inline
                                      ? widget.source
                                      : const SizedBox.shrink(),
                                ),
                                _InlineSource(
                                  progress: _progress,
                                  width: inline ? NotionSize.border : 0,
                                  yields: yieldSource,
                                  hidden: yieldSource && _expanded,
                                  child: SizedBox(
                                    height: NotionSize.iconLg,
                                    child: ColoredBox(
                                      color: colors.outlineVariant,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    child: widget.input,
                                  ),
                                ),
                              ],
                            ),
                            Positioned.fill(
                              child:
                                  widget.inputOverlay ??
                                  const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: NotionSpace.xxs),
                // Always present so the editor keeps its index in this row.
                _SecondaryAction(
                  visible: widget.secondaryAction != null,
                  child: _secondary,
                ),
                // Mic ↔ send and disabled → enabled morph with a small
                // spring (key each state's widget).
                SizedBox.square(
                  dimension: NotionSize.touchTarget,
                  child: NotionMorphSwitcher(
                    bounce: true,
                    child: widget.primaryAction,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// The [CompactComposer.secondaryAction] slot: a 48 dp target that grows in
/// and out horizontally (size + fade, reduced motion aware). While it closes
/// it ignores touches and screen readers.
class _SecondaryAction extends StatelessWidget {
  final bool visible;
  final Widget? child;

  const _SecondaryAction({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) => NotionSizeReveal(
    visible: visible && child != null,
    axis: Axis.horizontal,
    alignment: AlignmentDirectional.centerEnd,
    duration: NotionMotion.short,
    child: IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: SizedBox.square(
          dimension: NotionSize.touchTarget,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

/// The inline source (or its divider) inside the field. When it [yields], its
/// width shrinks while the tray opens, in step with the tray's animation, so
/// the editor keeps its width; the child itself is never re-laid out narrower.
class _InlineSource extends StatelessWidget {
  final Animation<double> progress;
  final double width;
  final bool yields;
  final bool hidden;
  final Widget child;

  const _InlineSource({
    required this.progress,
    required this.width,
    required this.yields,
    required this.hidden,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: hidden,
    child: IgnorePointer(
      ignoring: hidden,
      child: AnimatedBuilder(
        animation: progress,
        child: child,
        builder: (context, child) {
          final t = yields ? progress.value.clamp(0.0, 1.0) : 0.0;
          return ClipRect(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1 - t,
              heightFactor: 1,
              child: SizedBox(
                width: width,
                child: Opacity(opacity: 1 - t, child: child),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Explains why the source needs attention without adding text to the chip.
enum ConversationSourceHint { none, choose, unavailable }

/// A persistent sending-source label. It never owns or changes a send target.
///
/// The compact form shows only the monochrome network glyph and a lock or
/// chooser chevron; the full description stays in the tooltip and semantics.
class ConversationSourceChip extends StatelessWidget {
  final String network;
  final String? label;
  final bool locked;
  final VoidCallback? onPressed;
  final bool available;
  final bool compact;
  final ConversationSourceHint hint;

  const ConversationSourceChip({
    super.key,
    required this.network,
    this.label,
    this.locked = false,
    this.onPressed,
    this.available = true,
    this.compact = true,
    this.hint = ConversationSourceHint.none,
  });

  String get _name => label ?? notionNetworkLabel(network);
  bool get _selectable => available && !locked && onPressed != null;
  bool get _muted => !available || hint == ConversationSourceHint.unavailable;
  TextStyle get _style =>
      NotionType.footnote.copyWith(fontWeight: FontWeight.w500);

  /// The tooltip and semantics text of the chip.
  String get description => locked
      ? 'Replying via $_name'
      : !available
      ? '$_name, source unavailable'
      : _selectable
      ? '$_name, choose sending source'
      : 'Sending via $_name';

  /// Includes the actual label and system text scaling, rather than guessing
  /// from the network identifier or clipping the name to an icon.
  double preferredWidth(BuildContext context) {
    final trailing = locked || _selectable
        ? NotionSpace.xxs + NotionSize.iconSm
        : 0.0;
    if (compact) {
      return math.max(
        NotionSize.touchTarget,
        NotionSpace.xs * 2 + NotionSize.icon + trailing,
      );
    }
    final painter = TextPainter(
      text: TextSpan(
        text: _name,
        style: DefaultTextStyle.of(context).style.merge(_style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width =
        painter.width + 16 + 20 + 6 + (locked || _selectable ? 22 : 0);
    painter.dispose();
    return width.ceilToDouble();
  }

  Widget _glyph(BuildContext context) {
    if (hint != ConversationSourceHint.choose) {
      return NotionNetworkGlyph(
        network: network.toLowerCase(),
        size: NotionSize.icon,
      );
    }
    return SizedBox.square(
      dimension: NotionSize.icon,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.hub_outlined, size: NotionSize.icon),
          PositionedDirectional(
            top: -1,
            end: -1,
            child: SizedBox.square(
              dimension: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // A pending choice, not an error.
                  color: context.notion.colors.warning,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = _muted
        ? theme.disabledColor
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: description,
      button: onPressed != null && !locked,
      enabled: onPressed != null && !locked ? available : null,
      onTap: _selectable ? onPressed : null,
      excludeSemantics: true,
      child: Tooltip(
        message: description,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: _selectable ? onPressed : null,
            borderRadius: NotionRadius.pillAll,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: NotionSize.touchTarget,
                minWidth: NotionSize.touchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // A new source morphs in (scale + fade), like the
                      // composer's other glyph swaps.
                      NotionMorphSwitcher(
                        rotate: false,
                        child: KeyedSubtree(
                          key: ValueKey((network.toLowerCase(), hint)),
                          child: _glyph(context),
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _name,
                            style: _style.copyWith(
                              color: _muted
                                  ? theme.disabledColor
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                      if (locked || _selectable) ...[
                        SizedBox(width: compact ? NotionSpace.xxs : 6),
                        Icon(
                          locked ? Icons.lock_outline : Icons.expand_more,
                          size: NotionSize.iconSm,
                        ),
                      ],
                    ],
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

/// Leave room for the header, source and reply while the keyboard is visible.
int conversationComposerMaxLines(
  BuildContext context, {
  bool hasContext = false,
}) {
  final media = MediaQuery.of(context);
  final available =
      media.size.height -
      media.viewInsets.bottom -
      media.padding.vertical -
      56 -
      (hasContext ? 150 : 90);
  return (available / media.textScaler.scale(24)).floor().clamp(1, 4);
}

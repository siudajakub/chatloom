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

  /// A third recording choice, for example voice-to-text. Like the second
  /// action it yields its horizontal room when the composer has text.
  final Widget? tertiaryAction;

  /// Keep the composer one row on phones with three recording actions: the
  /// recording actions fold behind a small chevron at the end of the row
  /// and slide out (towards the editor) when it is tapped. With text the
  /// send button takes the chevron's place. The decision depends only on
  /// available width, so typing never moves the Send button.
  final bool useCompactActionToolbar;

  /// Whether [primaryAction] is a recording control (the voice mic) rather
  /// than send. On a phone row it then folds behind the chevron with the
  /// [secondaryAction] and [tertiaryAction].
  final bool primaryIsRecord;
  final double sourceWidth;
  final Widget? contextPreview;

  /// Inline actions revealed by the composer's own "+" button.
  final List<ComposerAction>? actions;

  /// Actions that always sit between the "+" ([addAction]) and the editor,
  /// for example the emoji toggle when "+" opens the attach menu directly.
  final List<ComposerAction> inlineActions;

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
    this.tertiaryAction,
    this.useCompactActionToolbar = false,
    this.primaryIsRecord = false,
    this.sourceWidth = 0,
    this.contextPreview,
    this.actions,
    this.inlineActions = const [],
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
    with TickerProviderStateMixin {
  // Insets + both 48dp actions + gaps (16 + 48 + 4 + 4 + 48).
  static const double _rowChrome = 120;
  // Divider + editor padding inside the field.
  static const double _fieldChrome = 13;
  // Collapsed editor minimum that decides whether the source stays inline.
  static const double _editorMin = 120;
  // The same on the one-row phone composer (its trailing slot is one 48dp
  // chevron, not three recording actions).
  static const double _foldedEditorMin = 72;

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

  /// The folded recording actions of the one-row phone composer.
  late final AnimationController _record = AnimationController(
    vsync: this,
    duration: NotionMotion.medium,
    reverseDuration: NotionMotion.short,
  );
  late final CurvedAnimation _recordProgress = CurvedAnimation(
    parent: _record,
    curve: NotionMotion.emphasized,
    reverseCurve: NotionMotion.exitFast,
  );
  bool _recordOpen = false;

  /// The last [CompactComposer.secondaryAction], kept while its slot closes.
  Widget? _secondary;
  Widget? _tertiary;
  final _primaryKey = GlobalKey();

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
    _tertiary = widget.tertiaryAction;
  }

  @override
  void didUpdateWidget(CompactComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _secondary = widget.secondaryAction ?? _secondary;
    _tertiary = widget.tertiaryAction ?? _tertiary;
    if (!identical(oldWidget.collapseOnText, widget.collapseOnText)) {
      oldWidget.collapseOnText?.removeListener(_textChanged);
      _lastText = widget.collapseOnText?.text ?? '';
      widget.collapseOnText?.addListener(_textChanged);
    }
    if (_recordOpen && !widget.primaryIsRecord) _applyRecord(false);
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
    _recordProgress.dispose();
    _record.dispose();
    super.dispose();
  }

  void _textChanged() {
    final text = widget.collapseOnText?.text ?? '';
    if (text == _lastText) return;
    _lastText = text;
    if (_expanded && text.trim().isNotEmpty) _setExpanded(false);
    if (_recordOpen && text.trim().isNotEmpty && mounted) {
      setState(() => _applyRecord(false));
    }
  }

  void _applyRecord(bool value) {
    if (_recordOpen == value) return;
    _recordOpen = value;
    if (ConversationMotion.reduced(context)) {
      _record.value = value ? 1 : 0;
    } else if (value) {
      _record.forward();
    } else {
      _record.reverse();
    }
  }

  void _toggleRecord() {
    NotionHaptics.light();
    setState(() => _applyRecord(!_recordOpen));
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
      final rowChrome =
          _rowChrome + widget.inlineActions.length * NotionSize.touchTarget;
      final folded =
          widget.useCompactActionToolbar &&
          constraints.maxWidth <
              rowChrome +
                  NotionSize.touchTarget * 2 +
                  _fieldChrome +
                  _editorMin;
      // The one-row phone composer keeps the source inside the field down
      // to a narrower editor: a separate source row would make it two rows.
      final inline =
          constraints.maxWidth >=
          measuredSourceWidth +
              rowChrome +
              _fieldChrome +
              (folded ? _foldedEditorMin : _editorMin);
      final actions = widget.actions ?? const <ComposerAction>[];
      // The secondary action only takes room from the editor. It never moves
      // the source out of line: the composer would change height as the
      // first letter hides it. It shows only while the editor is empty.
      final secondaryWidth = folded
          ? 0.0
          : (widget.secondaryAction == null ? 0.0 : NotionSize.touchTarget) +
                (widget.tertiaryAction == null ? 0.0 : NotionSize.touchTarget);
      double roomBeside(double source) => math.max(
        0.0,
        constraints.maxWidth -
            rowChrome -
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
                for (final action in widget.inlineActions)
                  SizedBox.square(
                    dimension: NotionSize.touchTarget,
                    child: NotionIconButton(
                      icon: action.icon,
                      label: action.label,
                      selected: action.selected,
                      onPressed: widget.actionsEnabled
                          ? action.onPressed
                          : null,
                    ),
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
                  // Always a Stack so the editor keeps its ancestors when
                  // the composer folds or unfolds on a resize.
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      DecoratedBox(
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
                      // Folded recording actions slide out over the end
                      // of the field (the editor keeps its width).
                      PositionedDirectional(
                        end: 0,
                        bottom: 0,
                        child: folded
                            ? _FoldedRecordActions(
                                progress: _recordProgress,
                                open: _recordOpen && widget.primaryIsRecord,
                                children: [
                                  _extraAction(tertiary: true),
                                  _extraAction(),
                                  if (widget.primaryIsRecord) _primaryAction(),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: NotionSpace.xxs),
                // Always present so the editor keeps its index in this row.
                // Folded: one cluster (dictation, round, mic) slides out
                // from behind the chevron; the primary slot shows the
                // chevron, or send once there is text.
                if (!folded) ...[_extraAction(tertiary: true), _extraAction()],
                // Mic ↔ send and disabled → enabled morph with a small
                // spring (key each state's widget).
                if (!folded) _primaryAction(),
                if (folded) _foldedPrimary(),
              ],
            ),
          ],
        ),
      );
    },
  );

  Widget _extraAction({bool tertiary = false}) => _SecondaryAction(
    visible: tertiary
        ? widget.tertiaryAction != null
        : widget.secondaryAction != null,
    child: tertiary ? _tertiary : _secondary,
  );

  /// The end of the one-row phone composer: the chevron that folds the
  /// recording actions, or [CompactComposer.primaryAction] (send).
  Widget _foldedPrimary() {
    final Widget child;
    if (widget.primaryIsRecord) {
      final reduced = ConversationMotion.reduced(context);
      child = MergeSemantics(
        key: const ValueKey('composer-record-toggle'),
        child: Semantics(
          expanded: _recordOpen,
          child: IconButton(
            tooltip: _recordOpen
                ? 'Hide recording options'
                : 'Show recording options',
            onPressed: _toggleRecord,
            icon: AnimatedRotation(
              turns: _recordOpen ? 0.5 : 0,
              duration: reduced ? Duration.zero : NotionMotion.medium,
              curve: NotionMotion.emphasized,
              child: const Icon(Icons.chevron_left),
            ),
          ),
        ),
      );
    } else {
      // Not [_primaryKey]: while this cross-fades back to the chevron, the
      // keyed mic is already in the cluster.
      child = KeyedSubtree(
        key: const ValueKey('composer-folded-primary'),
        child: NotionMorphSwitcher(bounce: true, child: widget.primaryAction),
      );
    }
    return SizedBox.square(
      dimension: NotionSize.touchTarget,
      child: NotionMorphSwitcher(bounce: true, child: child),
    );
  }

  Widget _primaryAction() => KeyedSubtree(
    key: _primaryKey,
    child: SizedBox.square(
      dimension: NotionSize.touchTarget,
      child: NotionMorphSwitcher(bounce: true, child: widget.primaryAction),
    ),
  );
}

/// The recording actions of the one-row phone composer. They stay mounted
/// (a held mic and the round gesture keep their state) and are revealed from
/// the chevron's side: the width grows towards the editor while the actions
/// slide in and fade. Closed, they ignore touches and screen readers.
class _FoldedRecordActions extends StatelessWidget {
  final Animation<double> progress;
  final bool open;
  final List<Widget> children;

  const _FoldedRecordActions({
    required this.progress,
    required this.open,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !open,
    child: ExcludeSemantics(
      excluding: !open,
      child: AnimatedBuilder(
        animation: progress,
        child: DecoratedBox(
          // The field's own fill and hairline, so the actions read as a
          // pill that slid out of the chevron over the editor.
          decoration: ShapeDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            shape: StadiumBorder(
              side: BorderSide(color: context.notion.glass.border),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(1),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
        builder: (context, row) {
          final t = progress.value.clamp(0.0, 1.0);
          final rtl = Directionality.of(context) == TextDirection.rtl;
          return ClipRect(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              widthFactor: t,
              child: Opacity(
                opacity: t,
                child: FractionalTranslation(
                  translation: Offset((1 - t) * (rtl ? -0.35 : 0.35), 0),
                  child: row,
                ),
              ),
            ),
          );
        },
      ),
    ),
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

  /// The compact glyph's start inset: where a lone glyph sits centred in its
  /// 48dp target. A chip with a lock or chooser chevron keeps the same inset,
  /// so the glyph never moves towards the field's edge in a merged chat.
  static const double glyphInset =
      (NotionSize.touchTarget - NotionSize.icon) / 2;

  bool get _trailing => locked || _selectable;

  EdgeInsetsGeometry get _padding => compact
      ? EdgeInsetsDirectional.only(
          start: glyphInset,
          end: _trailing ? NotionSpace.xxs : glyphInset,
        )
      : const EdgeInsets.symmetric(horizontal: NotionSpace.xs);

  /// Includes the actual label and system text scaling, rather than guessing
  /// from the network identifier or clipping the name to an icon.
  double preferredWidth(BuildContext context) {
    final trailing = _trailing ? NotionSpace.xxs + NotionSize.iconSm : 0.0;
    if (compact) {
      return math.max(
        NotionSize.touchTarget,
        _padding.horizontal + NotionSize.icon + trailing,
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
    final width = painter.width + 16 + 20 + 6 + (_trailing ? 22 : 0);
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
                padding: _padding,
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
                      if (_trailing) ...[
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

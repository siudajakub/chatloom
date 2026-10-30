// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'notion.dart';

/// Chrome of the photo and video editor (send preview → Edit). The stage is
/// the dark media viewer in both themes; the chrome floats on it in the
/// dock's language: glass pills on top, one glass dock of tools at the
/// bottom, panels of options above the dock. Data and callbacks only: the
/// editor engine (`lib/personal/media/editor/`) owns every state.

/// One tool of [NotionEditorDock].
@immutable
class NotionEditorTool {
  final String id;
  final IconData icon;
  final String label;

  const NotionEditorTool({
    required this.id,
    required this.icon,
    required this.label,
  });
}

/// The editor's top bar: close (or back from a tool), a title that fades
/// through when the tool changes, optional undo/redo and the primary "Done".
///
/// Undo and redo share one glass pill; a disabled one is dimmed, so a tap
/// that cannot do anything does not look like it failed. The title keeps at
/// least [NotionSpace.sm] from every pill: centred on the bar when it fits
/// there, otherwise centred between the pills, ellipsized when even that is
/// too narrow and left out below [_minTitleWidth] (the tool is still named
/// by the dock and the panel).
class NotionEditorTopBar extends StatelessWidget {
  final String title;
  final VoidCallback? onClose;
  final String closeLabel;
  final IconData closeIcon;

  /// Hidden when null; disabled while [canUndo]/[canRedo] are false.
  final VoidCallback? onUndo, onRedo;
  final bool canUndo, canRedo;

  final VoidCallback? onDone;
  final String doneLabel;
  final bool busy;

  const NotionEditorTopBar({
    super.key,
    required this.title,
    required this.onClose,
    this.closeLabel = 'Cancel',
    this.closeIcon = Icons.close_rounded,
    this.onUndo,
    this.onRedo,
    this.canUndo = false,
    this.canRedo = false,
    required this.onDone,
    this.doneLabel = 'Done',
    this.busy = false,
  });

  /// The bar's height without the status bar.
  static const double height = NotionSize.headerHeight + NotionSpace.xs;

  /// Narrower than this the title is left out rather than cut to "…".
  static const double _minTitleWidth = NotionSpace.xxl + NotionSpace.xs;

  @override
  Widget build(BuildContext context) {
    final onUndo = this.onUndo, onRedo = this.onRedo;
    final hasHistory = onUndo != null || onRedo != null;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
        child: CustomMultiChildLayout(
          delegate: _TopBarLayout(
            gap: NotionSpace.sm,
            minTitleWidth: _minTitleWidth,
          ),
          children: [
            LayoutId(
              id: _TopBarSlot.leading,
              child: NotionGlassPill(
                icon: closeIcon,
                tooltip: closeLabel,
                onPressed: busy ? null : onClose,
              ),
            ),
            LayoutId(
              id: _TopBarSlot.title,
              child: NotionFadeThrough(
                alignment: AlignmentDirectional.center,
                child: Text(
                  title,
                  key: ValueKey(title),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NotionType.headline.copyWith(
                    color: NotionMediaColors.onScrim,
                  ),
                ),
              ),
            ),
            LayoutId(
              id: _TopBarSlot.trailing,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasHistory) ...[
                    _HistoryPill(
                      cells: [
                        if (onUndo != null)
                          _HistoryCell(
                            icon: Icons.undo_rounded,
                            label: 'Undo',
                            onPressed: canUndo && !busy ? onUndo : null,
                          ),
                        if (onRedo != null)
                          _HistoryCell(
                            icon: Icons.redo_rounded,
                            label: 'Redo',
                            onPressed: canRedo && !busy ? onRedo : null,
                          ),
                      ],
                    ),
                    const SizedBox(width: NotionSpace.xs),
                  ],
                  NotionButton.primary(
                    label: doneLabel,
                    icon: Icons.check_rounded,
                    busy: busy,
                    onPressed: busy ? null : onDone,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TopBarSlot { leading, title, trailing }

/// Places the close pill on the left, the actions on the right (both at
/// their own size, centred vertically) and the title between them.
class _TopBarLayout extends MultiChildLayoutDelegate {
  final double gap;
  final double minTitleWidth;

  _TopBarLayout({required this.gap, required this.minTitleWidth});

  @override
  void performLayout(Size size) {
    // Pills keep their touch-target height inside the taller bar.
    final loose = BoxConstraints.loose(
      Size(size.width, math.min(size.height, NotionSize.touchTarget)),
    );
    final leading = layoutChild(_TopBarSlot.leading, loose);
    final trailing = layoutChild(
      _TopBarSlot.trailing,
      loose.copyWith(maxWidth: math.max(0, size.width - leading.width)),
    );
    positionChild(
      _TopBarSlot.leading,
      Offset(0, (size.height - leading.height) / 2),
    );
    positionChild(
      _TopBarSlot.trailing,
      Offset(size.width - trailing.width, (size.height - trailing.height) / 2),
    );
    final start = leading.width + gap;
    final end = size.width - trailing.width - gap;
    final room = end - start;
    if (room < minTitleWidth) {
      layoutChild(_TopBarSlot.title, BoxConstraints.tight(Size.zero));
      positionChild(_TopBarSlot.title, Offset(start, size.height / 2));
      return;
    }
    final title = layoutChild(
      _TopBarSlot.title,
      BoxConstraints(maxWidth: room, maxHeight: size.height),
    );
    final centred = (size.width - title.width) / 2;
    final x = centred >= start && centred + title.width <= end
        ? centred
        : start + (room - title.width) / 2;
    positionChild(
      _TopBarSlot.title,
      Offset(x, (size.height - title.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_TopBarLayout oldDelegate) =>
      oldDelegate.gap != gap || oldDelegate.minTitleWidth != minTitleWidth;
}

/// Undo and redo as two cells of one glass pill.
class _HistoryPill extends StatelessWidget {
  final List<Widget> cells;

  const _HistoryPill({required this.cells});

  @override
  Widget build(BuildContext context) => NotionGlassScope(
    mode: NotionGlassMode.off,
    child: NotionGlassSurface(
      dock: true,
      borderRadius: NotionGlass.dockRadius,
      border: Border.all(color: context.notion.glass.border),
      child: Material(
        type: MaterialType.transparency,
        child: Row(mainAxisSize: MainAxisSize.min, children: cells),
      ),
    ),
  );
}

/// One history action; dimmed while [onPressed] is null.
class _HistoryCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _HistoryCell({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// Narrower than a lone pill: the two cells read as one control.
  static const double _width = NotionSize.touchTarget - NotionSpace.xxs;

  @override
  Widget build(BuildContext context) {
    final onPressed = this.onPressed;
    final colors = context.notion.colors;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onPressed,
          customBorder: NotionShapes.pill,
          child: NotionPressable(
            enabled: onPressed != null,
            scale: NotionMotion.pressIcon,
            child: SizedBox(
              width: _width,
              height: NotionSize.touchTarget,
              child: Icon(
                icon,
                size: NotionSize.iconLg,
                color: onPressed == null ? colors.textTertiary : colors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tool dock: one glass pill of icon + label cells, the selected cell on
/// an `accentTint` pill. Cells rise in one after another the first time the
/// dock appears.
class NotionEditorDock extends StatelessWidget {
  final List<NotionEditorTool> tools;
  final String? selected;
  final ValueChanged<NotionEditorTool>? onSelected;

  const NotionEditorDock({
    super.key,
    required this.tools,
    this.selected,
    required this.onSelected,
  });

  /// The dock's own padding and border around its cells.
  static const double _frame = 2 * NotionSpace.xxs + 2 * NotionSize.border;

  /// Whether every cell fits [maxWidth] with its label.
  bool _labelsFit(BuildContext context, double maxWidth) {
    if (!maxWidth.isFinite) return true;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    var width = _frame;
    for (final tool in tools) {
      painter.text = TextSpan(text: tool.label, style: NotionType.micro);
      painter.layout();
      width += _DockCell.labelledWidth(painter.width);
    }
    painter.dispose();
    return width <= maxWidth;
  }

  @override
  Widget build(BuildContext context) {
    final onSelected = this.onSelected;
    // `heightFactor: 1`: in the editor's bottom-bar slot the constraints are
    // loose up to the full height, and a plain Center would take all of it,
    // leaving the photo's stage zero pixels tall. A screen too narrow for
    // the labels (or large text) gets icon cells, which keep their touch
    // size; only a dock too narrow even for those is scaled down.
    return Center(
      heightFactor: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
        child: LayoutBuilder(
          builder: (context, constraints) => FittedBox(
            fit: BoxFit.scaleDown,
            child: _dock(
              context,
              onSelected,
              iconsOnly: !_labelsFit(context, constraints.maxWidth),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dock(
    BuildContext context,
    ValueChanged<NotionEditorTool>? onSelected, {
    required bool iconsOnly,
  }) => NotionGlassSurface(
    dock: true,
    borderRadius: NotionGlass.dockRadius,
    border: Border.all(color: context.notion.glass.border),
    child: Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.all(NotionSpace.xxs),
        child: NotionEntranceScope(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, tool) in tools.indexed)
                NotionEntrance(
                  index: i,
                  child: _DockCell(
                    tool: tool,
                    selected: tool.id == selected,
                    iconOnly: iconsOnly,
                    onTap: onSelected == null ? null : () => onSelected(tool),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _DockCell extends StatelessWidget {
  final NotionEditorTool tool;
  final bool selected;

  /// Only the icon, the label in its tooltip (semantics keep it either way).
  final bool iconOnly;
  final VoidCallback? onTap;

  const _DockCell({
    required this.tool,
    required this.selected,
    this.iconOnly = false,
    this.onTap,
  });

  static const double _minWidth = NotionSize.touchTarget + NotionSpace.md;
  static const double _padding = NotionSpace.xs;

  /// The cell's width with a label of [labelWidth].
  static double labelledWidth(double labelWidth) =>
      math.max(_minWidth, 2 * _padding + labelWidth);

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final foreground = selected ? tokens.colors.accent : tokens.colors.text;
    // One node per tool: its label and the tap, not the icon and text.
    Widget cell = Semantics(
      button: true,
      selected: selected,
      label: tool.label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: NotionShapes.pill,
        child: NotionPressable(
          enabled: onTap != null,
          scale: NotionMotion.pressIcon,
          child: AnimatedContainer(
            duration: NotionMotion.of(context, NotionMotion.quick),
            curve: NotionMotion.standard,
            constraints: BoxConstraints(
              minWidth: iconOnly ? NotionSize.touchTarget : _minWidth,
              minHeight: NotionSize.touchTarget + NotionSpace.xs,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: _padding,
              vertical: NotionSpace.xxs,
            ),
            decoration: ShapeDecoration(
              shape: NotionShapes.pill,
              color: selected ? tokens.palette.accentTint : Colors.transparent,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(tool.icon, size: NotionSize.iconMd, color: foreground),
                if (!iconOnly) ...[
                  const SizedBox(height: 2),
                  Text(
                    tool.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NotionType.micro.copyWith(color: foreground),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (iconOnly) cell = Tooltip(message: tool.label, child: cell);
    return cell;
  }
}

/// A panel of options above the dock (crop ratios, brush colours, a
/// slider): glass, `lg` corners, its content rises in when the tool opens.
class NotionEditorPanel extends StatelessWidget {
  final List<Widget> children;

  const NotionEditorPanel({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: NotionSize.contentMaxWidth),
      child: NotionGlassSurface(
        dock: true,
        borderRadius: NotionRadius.xlAll,
        border: Border.all(color: context.notion.glass.border),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
            child: NotionStaggeredColumn(children: children),
          ),
        ),
      ),
    ),
  );
}

/// A row of single-choice chips (aspect ratios, brush tools, adjustments).
/// When the labelled chips do not fit and every option has an icon, the
/// chips that are not selected show only their icon (the label stays their
/// tooltip and semantics), so every tool is in view on a narrow phone;
/// otherwise the row scrolls sideways. The selected chip is on the
/// `accentTint` pill.
class NotionEditorChoices<T> extends StatelessWidget {
  final List<NotionEditorChoice<T>> options;
  final T? selected;
  final ValueChanged<T> onSelected;

  const NotionEditorChoices({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  static const double _rowPadding = NotionSpace.xs;

  /// Whether the labelled chips are wider than [maxWidth].
  bool _overflows(BuildContext context, double maxWidth) {
    if (!maxWidth.isFinite) return false;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    var width = 2 * _rowPadding;
    for (final option in options) {
      painter.text = TextSpan(text: option.label, style: NotionType.callout);
      painter.layout();
      width += _ChoiceChip.labelledWidth(painter.width, icon: option.icon);
    }
    painter.dispose();
    return width > maxWidth;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          options.every((option) => option.icon != null) &&
          _overflows(context, constraints.maxWidth);
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _rowPadding),
        child: Row(
          children: [
            for (final option in options)
              _ChoiceChip(
                option: option,
                selected: option.value == selected,
                iconOnly: compact && option.value != selected,
                onTap: () => onSelected(option.value),
              ),
          ],
        ),
      );
    },
  );
}

@immutable
class NotionEditorChoice<T> {
  final T value;
  final String label;
  final IconData? icon;

  const NotionEditorChoice({
    required this.value,
    required this.label,
    this.icon,
  });
}

class _ChoiceChip<T> extends StatelessWidget {
  final NotionEditorChoice<T> option;
  final bool selected;

  /// Only the icon; the label becomes the tooltip.
  final bool iconOnly;
  final VoidCallback onTap;

  const _ChoiceChip({
    required this.option,
    required this.selected,
    required this.onTap,
    this.iconOnly = false,
  });

  static const double _padding = NotionSpace.sm;
  static const double _iconGap = NotionSpace.xxs + 2;

  /// The width of the chip with its label of [labelWidth].
  static double labelledWidth(double labelWidth, {IconData? icon}) =>
      2 * _padding +
      (icon == null ? 0 : NotionSize.icon + _iconGap) +
      labelWidth;

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final foreground = selected
        ? tokens.colors.accent
        : tokens.colors.textSecondary;
    final icon = option.icon;
    final iconOnly = this.iconOnly && icon != null;
    Widget chip = Semantics(
      button: true,
      selected: selected,
      label: iconOnly ? option.label : null,
      child: InkWell(
        onTap: onTap,
        customBorder: NotionShapes.pill,
        child: NotionPressable(
          scale: NotionMotion.pressButton,
          child: AnimatedContainer(
            duration: NotionMotion.of(context, NotionMotion.quick),
            curve: NotionMotion.standard,
            constraints: const BoxConstraints(
              minHeight: NotionSize.touchTarget - NotionSpace.xs,
            ),
            padding: const EdgeInsets.symmetric(horizontal: _padding),
            decoration: ShapeDecoration(
              shape: NotionShapes.pill,
              color: selected ? tokens.palette.accentTint : Colors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null)
                  Icon(icon, size: NotionSize.icon, color: foreground),
                if (!iconOnly) ...[
                  if (icon != null) const SizedBox(width: _iconGap),
                  Text(
                    option.label,
                    style: NotionType.callout.copyWith(color: foreground),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (iconOnly) chip = Tooltip(message: option.label, child: chip);
    return chip;
  }
}

/// Brush colours: circles with a ring around the chosen one, which springs a
/// little larger.
class NotionEditorSwatches extends StatelessWidget {
  final List<Color> colors;
  final Color? selected;
  final ValueChanged<Color> onSelected;

  const NotionEditorSwatches({
    super.key,
    this.colors = drawing,
    required this.selected,
    required this.onSelected,
  });

  /// The drawing palette: content colours (they end up in the photo), so
  /// they do not follow the theme or the accent.
  static const List<Color> drawing = [
    Color(0xFFFFFFFF),
    Color(0xFF191919),
    Color(0xFFFF453A),
    Color(0xFFFF9F0A),
    Color(0xFFFFD60A),
    Color(0xFF30D158),
    Color(0xFF0A84FF),
    Color(0xFFBF5AF2),
    Color(0xFFFF6FB5),
  ];

  static const _names = [
    'White',
    'Black',
    'Red',
    'Orange',
    'Yellow',
    'Green',
    'Blue',
    'Violet',
    'Pink',
  ];

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
    child: Row(
      children: [
        for (final (i, color) in colors.indexed)
          _Swatch(
            color: color,
            name: identical(colors, drawing) ? _names[i] : 'Colour ${i + 1}',
            selected: color == selected,
            onTap: () => onSelected(color),
          ),
      ],
    ),
  );
}

class _Swatch extends StatelessWidget {
  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  static const double _dot = 26;

  @override
  Widget build(BuildContext context) {
    final ring = context.notion.colors.text;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: NotionSize.touchTarget - NotionSpace.xxs,
          child: Center(
            child: AnimatedScale(
              scale: selected ? 1.15 : 1,
              duration: NotionMotion.of(
                context,
                NotionMotion.snappyCurve.duration,
              ),
              curve: NotionMotion.snappyCurve,
              child: AnimatedContainer(
                duration: NotionMotion.of(context, NotionMotion.quick),
                width: _dot,
                height: _dot,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? ring : ring.withValues(alpha: 0.28),
                    width: selected ? 2.5 : 1,
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

/// A labelled slider (brush size, blur strength, brightness…): the label on
/// the left, the current value on the right, rolling as it changes.
class NotionEditorSlider extends StatelessWidget {
  final String label;
  final double value, min, max;
  final int? divisions;

  /// Shown on the right; null hides it.
  final String? valueLabel;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart, onChangeEnd;

  const NotionEditorSlider({
    super.key,
    required this.label,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.valueLabel,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final typography = context.notion.typography;
    final valueLabel = this.valueLabel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NotionSpace.md),
      child: Row(
        children: [
          Text(label, style: typography.footnote),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              semanticFormatterCallback: valueLabel == null
                  ? null
                  : (_) => valueLabel,
              onChanged: onChanged,
              onChangeStart: onChangeStart,
              onChangeEnd: onChangeEnd,
            ),
          ),
          if (valueLabel != null)
            SizedBox(
              width: NotionSpace.xxl + NotionSpace.xs,
              child: Text(
                valueLabel,
                textAlign: TextAlign.end,
                style: typography.footnote.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small read-only pill on the stage (trim length, "Muted"): text on the
/// media scrim, changes fade through.
class NotionEditorBadge extends StatelessWidget {
  final String text;
  final IconData? icon;

  const NotionEditorBadge({super.key, required this.text, this.icon});

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return DecoratedBox(
      decoration: const ShapeDecoration(
        shape: NotionShapes.pill,
        color: NotionMediaColors.scrim,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NotionSpace.sm,
          vertical: NotionSpace.xxs + 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: NotionSize.iconSm,
                color: NotionMediaColors.onScrim,
              ),
              const SizedBox(width: NotionSpace.xxs),
            ],
            NotionFadeThrough(
              child: Text(
                text,
                key: ValueKey(text),
                style: NotionType.footnote.copyWith(
                  color: NotionMediaColors.onScrim,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The export panel of a long edit (a video render): what is happening, a
/// bar that follows [progress] (0…1, null while unknown) and Cancel.
class NotionEditorProgress extends StatelessWidget {
  final String label;
  final double? progress;
  final VoidCallback? onCancel;

  const NotionEditorProgress({
    super.key,
    required this.label,
    required this.progress,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final progress = this.progress;
    final percent = progress == null ? null : (progress * 100).round();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: NotionSize.dialogMaxWidth),
      child: NotionGlassPanel(
        borderRadius: NotionRadius.xlAll,
        padding: const EdgeInsets.fromLTRB(
          NotionSpace.lg,
          NotionSpace.lg,
          NotionSpace.lg,
          NotionSpace.sm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: tokens.typography.bodyStrong),
                ),
                if (percent != null)
                  NotionAnimatedCount(
                    count: percent,
                    format: (value) => '$value %',
                    style: tokens.typography.footnote,
                  ),
              ],
            ),
            const SizedBox(height: NotionSpace.sm),
            ClipRRect(
              borderRadius: NotionRadius.pillAll,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: progress ?? 0),
                duration: NotionMotion.of(context, NotionMotion.short),
                curve: NotionMotion.standard,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: progress == null ? null : value,
                  minHeight: 6,
                  color: tokens.palette.accentFill,
                  backgroundColor: tokens.colors.selected,
                ),
              ),
            ),
            const SizedBox(height: NotionSpace.xs),
            if (onCancel != null)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: NotionButton.ghost(label: 'Cancel', onPressed: onCancel),
              )
            else
              const SizedBox(height: NotionSpace.xs),
          ],
        ),
      ),
    );
  }
}

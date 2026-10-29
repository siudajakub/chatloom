// SPDX-License-Identifier: AGPL-3.0-or-later
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

  @override
  Widget build(BuildContext context) {
    final onUndo = this.onUndo, onRedo = this.onRedo;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
        // Pills keep their touch-target height inside the taller bar.
        child: Center(
          child: SizedBox(
            height: NotionSize.touchTarget,
            child: Row(
          children: [
            NotionGlassPill(
              icon: closeIcon,
              tooltip: closeLabel,
              onPressed: busy ? null : onClose,
            ),
            Expanded(
              child: NotionFadeThrough(
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
            if (onUndo != null) ...[
              NotionGlassPill(
                icon: Icons.undo_rounded,
                tooltip: 'Undo',
                onPressed: canUndo && !busy ? onUndo : null,
              ),
              const SizedBox(width: NotionSpace.xxs),
            ],
            if (onRedo != null) ...[
              NotionGlassPill(
                icon: Icons.redo_rounded,
                tooltip: 'Redo',
                onPressed: canRedo && !busy ? onRedo : null,
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

  @override
  Widget build(BuildContext context) {
    final onSelected = this.onSelected;
    return Center(
      child: NotionGlassSurface(
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
                        onTap: onSelected == null
                            ? null
                            : () => onSelected(tool),
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

class _DockCell extends StatelessWidget {
  final NotionEditorTool tool;
  final bool selected;
  final VoidCallback? onTap;

  const _DockCell({required this.tool, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final foreground = selected ? tokens.colors.accent : tokens.colors.text;
    // One node per tool: its label and the tap, not the icon and text.
    return Semantics(
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
            constraints: const BoxConstraints(
              minWidth: NotionSize.touchTarget + NotionSpace.md,
              minHeight: NotionSize.touchTarget + NotionSpace.xs,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: NotionSpace.xs,
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
                const SizedBox(height: 2),
                Text(
                  tool.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NotionType.micro.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
/// Scrolls sideways when it does not fit; the selected chip is on the
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

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
    child: Row(
      children: [
        for (final option in options)
          _ChoiceChip(
            option: option,
            selected: option.value == selected,
            onTap: () => onSelected(option.value),
          ),
      ],
    ),
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
  final VoidCallback onTap;

  const _ChoiceChip({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final foreground = selected
        ? tokens.colors.accent
        : tokens.colors.textSecondary;
    final icon = option.icon;
    return Semantics(
      button: true,
      selected: selected,
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
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
            decoration: ShapeDecoration(
              shape: NotionShapes.pill,
              color: selected ? tokens.palette.accentTint : Colors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: NotionSize.icon, color: foreground),
                  const SizedBox(width: NotionSpace.xxs + 2),
                ],
                Text(
                  option.label,
                  style: NotionType.callout.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
              Icon(icon, size: NotionSize.iconSm, color: NotionMediaColors.onScrim),
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

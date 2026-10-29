// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pro_image_editor/features/tune_editor/utils/tune_presets.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// The Notion skin of `pro_image_editor`: every bar and panel of the
/// package is replaced by the primitives of `notion_media_editor.dart`; the
/// package keeps the engine (gestures, crop maths, painting, filters, the
/// video trim bar) and the output. Shared by the photo and video editors.
abstract final class MediaEditorSkin {
  /// Brush tools of the Draw panel.
  static const drawTools = [
    NotionEditorChoice(
      value: PaintMode.freeStyle,
      label: 'Pen',
      icon: Icons.edit_rounded,
    ),
    NotionEditorChoice(
      value: PaintMode.arrow,
      label: 'Arrow',
      icon: Icons.arrow_outward_rounded,
    ),
    NotionEditorChoice(
      value: PaintMode.rect,
      label: 'Box',
      icon: Icons.crop_square_rounded,
    ),
    NotionEditorChoice(
      value: PaintMode.circle,
      label: 'Circle',
      icon: Icons.circle_outlined,
    ),
    NotionEditorChoice(
      value: PaintMode.eraser,
      label: 'Eraser',
      icon: Icons.auto_fix_normal_rounded,
    ),
  ];

  /// Censor tools of the Blur panel: an area dragged over the photo.
  static const censorTools = [
    NotionEditorChoice(
      value: PaintMode.blur,
      label: 'Blur',
      icon: Icons.blur_on_rounded,
    ),
    NotionEditorChoice(
      value: PaintMode.pixelate,
      label: 'Pixelate',
      icon: Icons.grid_on_rounded,
    ),
    NotionEditorChoice(
      value: PaintMode.eraser,
      label: 'Eraser',
      icon: Icons.auto_fix_normal_rounded,
    ),
  ];

  /// The package's "free" ratio (`CropAspectRatios.custom`); 0 is the
  /// photo's own ratio.
  static const double _free = -1;

  static const _ratios = [
    NotionEditorChoice(value: _free, label: 'Free'),
    NotionEditorChoice(value: 0.0, label: 'Original'),
    NotionEditorChoice(value: 1.0, label: 'Square'),
    NotionEditorChoice(value: 4 / 5, label: '4:5'),
    NotionEditorChoice(value: 3 / 4, label: '3:4'),
    NotionEditorChoice(value: 9 / 16, label: '9:16'),
    NotionEditorChoice(value: 16 / 9, label: '16:9'),
  ];

  /// The adjustments of the Adjust tool, in this order.
  static const _tuneIds = [
    'brightness',
    'contrast',
    'saturation',
    'exposure',
    'temperature',
  ];

  static const _tuneLabels = {
    'brightness': 'Brightness',
    'contrast': 'Contrast',
    'saturation': 'Saturation',
    'exposure': 'Exposure',
    'temperature': 'Warmth',
  };

  static const _tuneIcons = {
    'brightness': Icons.light_mode_outlined,
    'contrast': Icons.contrast_rounded,
    'saturation': Icons.water_drop_outlined,
    'exposure': Icons.exposure_rounded,
    'temperature': Icons.thermostat_rounded,
  };

  /// The top bar inside the editor's app-bar slot.
  static ReactiveAppbar topBar({
    required Stream<void> stream,
    required NotionEditorTopBar Function() builder,
  }) => ReactiveAppbar(
    stream: stream,
    appbarSize: const Size.fromHeight(NotionEditorTopBar.height),
    builder: (context) => PreferredSize(
      preferredSize: const Size.fromHeight(NotionEditorTopBar.height),
      child: builder(),
    ),
  );

  /// Shared configuration: the Notion theme on the media stage, the skinned
  /// sub-editors and the export overlay. [mainEditor], [paintEditor] and the
  /// rest are filled in by the photo and video editors.
  static ProImageEditorConfigs configs(
    BuildContext context, {
    required String heroTag,
    required MainEditorConfigs mainEditor,
    PaintEditorConfigs paintEditor = const PaintEditorConfigs(),
    ImageGenerationConfigs imageGeneration = const ImageGenerationConfigs(),
    VideoEditorConfigs videoEditor = const VideoEditorConfigs(),
    ValueListenable<bool> censoring = const _Never(),
    required Widget Function(String message) loading,
  }) {
    final theme = Theme.of(context);
    final reduced = NotionMotion.reduced(context);
    const overlay = SystemUiOverlayStyle.light;
    const stage = NotionMediaColors.viewer;
    const clear = Colors.transparent;
    return ProImageEditorConfigs(
      theme: theme,
      heroTag: heroTag,
      designMode: ImageEditorDesignMode.material,
      mainEditor: mainEditor.copyWith(
        style: const MainEditorStyle(
          background: stage,
          appBarBackground: clear,
          bottomBarBackground: clear,
          uiOverlayStyle: overlay,
        ),
      ),
      paintEditor: paintEditor.copyWith(
        style: PaintEditorStyle(
          background: stage,
          appBarBackground: clear,
          bottomBarBackground: clear,
          initialColor: NotionEditorSwatches.drawing[2],
          initialStrokeWidth: 6,
          uiOverlayStyle: overlay,
        ),
        censorConfigs: const CensorConfigs(
          enableRoundArea: true,
          blurSigmaX: 18,
          blurSigmaY: 18,
          pixelBlockSize: 18,
        ),
        widgets: PaintEditorWidgets(
          appBar: (paint, stream) => topBar(
            stream: stream,
            builder: () => NotionEditorTopBar(
              title: censoring.value ? 'Blur' : 'Draw',
              closeIcon: Icons.arrow_back_rounded,
              closeLabel: 'Back',
              onClose: paint.close,
              onUndo: paint.undoAction,
              onRedo: paint.redoAction,
              canUndo: paint.canUndo,
              canRedo: paint.canRedo,
              onDone: paint.done,
            ),
          ),
          bottomBar: (paint, stream) => ReactiveWidget(
            stream: stream,
            builder: (_) =>
                _PaintPanel(paint: paint, censor: censoring.value),
          ),
          colorPicker: (paint, stream, color, setColor) => null,
        ),
      ),
      cropRotateEditor: CropRotateEditorConfigs(
        tools: const [CropRotateTool.rotate, CropRotateTool.flip],
        rotateAnimationCurve: NotionMotion.emphasized,
        flipAnimationCurve: NotionMotion.standard,
        scaleAnimationCurve: NotionMotion.standard,
        cropDragAnimationCurve: NotionMotion.standard,
        animationDuration: reduced ? Duration.zero : NotionMotion.long,
        cropDragAnimationDuration: reduced ? Duration.zero : NotionMotion.short,
        enableDoubleTap: true,
        style: CropRotateEditorStyle(
          background: stage,
          appBarBackground: clear,
          bottomBarBackground: clear,
          cropCornerColor: NotionMediaColors.onScrim,
          helperLineColor: NotionMediaColors.onScrim.withValues(alpha: 0.45),
          cropOverlayColor: stage,
          uiOverlayStyle: overlay,
        ),
        widgets: CropRotateEditorWidgets(
          appBar: (crop, stream) => topBar(
            stream: stream,
            builder: () => NotionEditorTopBar(
              title: 'Crop',
              closeIcon: Icons.arrow_back_rounded,
              closeLabel: 'Back',
              onClose: crop.close,
              onUndo: crop.undoAction,
              onRedo: crop.redoAction,
              canUndo: crop.canUndo,
              canRedo: crop.canRedo,
              onDone: crop.done,
            ),
          ),
          bottomBar: (crop, stream) => ReactiveWidget(
            stream: stream,
            builder: (_) => _CropPanel(crop: crop),
          ),
        ),
      ),
      filterEditor: FilterEditorConfigs(
        style: FilterEditorStyle(
          background: stage,
          appBarBackground: clear,
          previewTextColor: context.notion.colors.textSecondary,
          previewSelectedTextColor: context.notion.colors.accent,
          filterListMargin: const EdgeInsets.fromLTRB(
            NotionSpace.xs,
            NotionSpace.xs,
            NotionSpace.xs,
            NotionSpace.md,
          ),
          uiOverlayStyle: overlay,
        ),
        widgets: FilterEditorWidgets(
          appBar: (filter, stream) => topBar(
            stream: stream,
            builder: () => NotionEditorTopBar(
              title: 'Filters',
              closeIcon: Icons.arrow_back_rounded,
              closeLabel: 'Back',
              onClose: filter.close,
              onDone: filter.done,
            ),
          ),
          slider: (filter, stream, value, onChanged, onChangeEnd) =>
              ReactiveWidget(
                stream: stream,
                builder: (_) => NotionEditorSlider(
                  label: 'Strength',
                  value: value,
                  valueLabel: '${(value * 100).round()}',
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ),
        ),
      ),
      tuneEditor: TuneEditorConfigs(
        tuneAdjustmentOptions: _tuneOptions(),
        style: const TuneEditorStyle(
          background: stage,
          appBarBackground: clear,
          bottomBarBackground: clear,
          uiOverlayStyle: overlay,
        ),
        widgets: TuneEditorWidgets(
          appBar: (tune, stream) => topBar(
            stream: stream,
            builder: () => NotionEditorTopBar(
              title: 'Adjust',
              closeIcon: Icons.arrow_back_rounded,
              closeLabel: 'Back',
              onClose: tune.close,
              onUndo: tune.undo,
              onRedo: tune.redo,
              canUndo: tune.canUndo,
              canRedo: tune.canRedo,
              onDone: tune.done,
            ),
          ),
          bottomBar: (tune, stream) => ReactiveWidget(
            stream: stream,
            builder: (_) => _TunePanel(tune: tune),
          ),
        ),
      ),
      imageGeneration: imageGeneration,
      videoEditor: videoEditor,
      dialogConfigs: DialogConfigs(
        widgets: DialogWidgets(
          loadingDialog: (message, configs) => loading(message),
        ),
      ),
    );
  }

  static List<TuneAdjustmentItem> _tuneOptions() {
    final presets = {
      for (final item in tunePresets(
        icons: const TuneEditorIcons(),
        i18n: const I18nTuneEditor(),
      ))
        item.id: item,
    };
    return [
      for (final id in _tuneIds)
        if (presets[id] case final item?)
          TuneAdjustmentItem(
            id: item.id,
            label: _tuneLabels[id]!,
            icon: _tuneIcons[id]!,
            min: item.min,
            max: item.max,
            divisions: item.divisions,
            labelMultiplier: item.labelMultiplier,
            toMatrix: item.toMatrix,
          ),
    ];
  }
}

class _Never implements ValueListenable<bool> {
  const _Never();

  @override
  bool get value => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// The panel and dock sit at the bottom of the stage with the safe area
/// below them; they fade out while a stroke is drawn so the photo is free.
class _BottomChrome extends StatelessWidget {
  final bool hidden;
  final Widget child;

  const _BottomChrome({required this.child, this.hidden = false});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: hidden,
    child: AnimatedOpacity(
      opacity: hidden ? 0 : 1,
      duration: NotionMotion.of(context, NotionMotion.short),
      curve: NotionMotion.standard,
      child: Padding(
        padding: const EdgeInsets.only(
          top: NotionSpace.xs,
          bottom: NotionSpace.xs,
        ),
        child: child,
      ),
    ),
  );
}

class _CropPanel extends StatefulWidget {
  final CropRotateEditorState crop;

  const _CropPanel({required this.crop});

  @override
  State<_CropPanel> createState() => _CropPanelState();
}

/// Holds the chosen ratio itself: the crop editor keeps its own private.
class _CropPanelState extends State<_CropPanel> {
  double _ratio = MediaEditorSkin._free;

  CropRotateEditorState get crop => widget.crop;

  @override
  Widget build(BuildContext context) => _BottomChrome(
    child: NotionEditorPanel(
      children: [
        NotionEditorChoices<double>(
          options: MediaEditorSkin._ratios,
          selected: _ratio,
          onSelected: (ratio) {
            NotionHaptics.selection();
            setState(() => _ratio = ratio);
            crop.updateAspectRatio(ratio);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              NotionGlassPill(
                icon: Icons.rotate_90_degrees_ccw_rounded,
                label: 'Rotate',
                onPressed: crop.rotate,
              ),
              const SizedBox(width: NotionSpace.xs),
              NotionGlassPill(
                icon: Icons.flip_rounded,
                label: 'Flip',
                onPressed: crop.flip,
              ),
              const SizedBox(width: NotionSpace.xs),
              NotionGlassPill(
                icon: Icons.restart_alt_rounded,
                label: 'Reset',
                onPressed: crop.canUndo
                    ? () {
                        setState(() => _ratio = MediaEditorSkin._free);
                        crop.reset();
                      }
                    : null,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _PaintPanel extends StatefulWidget {
  final PaintEditorState paint;

  /// Opened from Blur: censor tools instead of brushes.
  final bool censor;

  const _PaintPanel({required this.paint, required this.censor});

  @override
  State<_PaintPanel> createState() => _PaintPanelState();
}

/// Rebuilds itself after a choice: the paint editor redraws its canvas, not
/// its bottom bar.
class _PaintPanelState extends State<_PaintPanel> {
  PaintEditorState get paint => widget.paint;

  @override
  Widget build(BuildContext context) {
    final censor = widget.censor;
    final mode = paint.paintMode;
    final drawsShape = mode != PaintMode.eraser;
    return _BottomChrome(
      hidden: paint.isActive,
      child: NotionEditorPanel(
        children: [
          NotionEditorChoices<PaintMode>(
            options: censor
                ? MediaEditorSkin.censorTools
                : MediaEditorSkin.drawTools,
            selected: mode,
            onSelected: (mode) {
              NotionHaptics.selection();
              setState(() => paint.setMode(mode));
            },
          ),
          if (censor)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NotionSpace.md,
                vertical: NotionSpace.xs,
              ),
              child: Text(
                mode == PaintMode.eraser
                    ? 'Tap a blurred area to remove it.'
                    : 'Drag over what you want to hide.',
                textAlign: TextAlign.center,
                style: context.notion.typography.footnote.copyWith(
                  color: context.notion.colors.textSecondary,
                ),
              ),
            )
          else ...[
            NotionEditorSwatches(
              selected: drawsShape ? paint.paintCtrl.color : null,
              onSelected: (color) {
                setState(() {
                  paint.paintCtrl.setColor(color);
                  if (!drawsShape) paint.setMode(PaintMode.freeStyle);
                });
                paint.uiPickerStream.add(null);
              },
            ),
            NotionEditorSlider(
              label: 'Size',
              value: paint.strokeWidth,
              min: 2,
              max: 24,
              valueLabel: '${paint.strokeWidth.round()}',
              onChanged: (value) =>
                  setState(() => paint.setStrokeWidth(value)),
            ),
          ],
        ],
      ),
    );
  }
}

class _TunePanel extends StatefulWidget {
  final TuneEditorState tune;

  const _TunePanel({required this.tune});

  @override
  State<_TunePanel> createState() => _TunePanelState();
}

class _TunePanelState extends State<_TunePanel> {
  TuneEditorState get tune => widget.tune;

  @override
  Widget build(BuildContext context) => _BottomChrome(
    child: NotionEditorPanel(
      children: [
        StreamBuilder<void>(
          stream: tune.uiStream.stream,
          builder: (context, _) {
            final item = tune.tuneAdjustmentList[tune.selectedIndex];
            final matrix = tune.tuneAdjustmentMatrix[tune.selectedIndex];
            return NotionEditorSlider(
              label: item.label,
              value: matrix.value,
              min: item.min,
              max: item.max,
              valueLabel: '${(matrix.value * item.labelMultiplier).round()}',
              onChangeStart: tune.onChangedStart,
              onChanged: tune.onChanged,
              onChangeEnd: tune.onChangedEnd,
            );
          },
        ),
        NotionEditorChoices<int>(
          options: [
            for (final (i, item) in tune.tuneAdjustmentList.indexed)
              NotionEditorChoice(value: i, label: item.label, icon: item.icon),
          ],
          selected: tune.selectedIndex,
          onSelected: (i) {
            NotionHaptics.selection();
            setState(() => tune.selectedIndex = i);
            tune.uiStream.add(null);
          },
        ),
      ],
    ),
  );
}

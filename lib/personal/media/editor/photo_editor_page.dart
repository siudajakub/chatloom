// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/editor/media_editor_skin.dart';
import 'package:chatloom/personal/media/editor/paint_session.dart';
import 'package:chatloom/personal/media/editor/photo_editor_source.dart';
import 'package:chatloom/personal/media/photo_encoder.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// An edited photo: its new bytes and what they are.
@immutable
class EditedPhoto {
  final Uint8List bytes;
  final EditedPhotoFormat format;

  const EditedPhoto(this.bytes, this.format);
}

/// Opens the photo editor over the send preview: the photo flies in from
/// the preview ([heroTag] on its `Hero`), the tools are Crop, Draw, Blur,
/// Filters and Adjust. Returns the edited photo, or null when the user
/// closed the editor or changed nothing (the picked file is then kept).
///
/// The output is a fresh encode without the source's metadata (location,
/// camera), as JPEG q92 or, with transparency, PNG ([EditedPhotoFormat]).
///
/// A photo already within the output size is decoded into the image cache
/// before the route opens (a short wait), so it is there when it flies in:
/// the package's hero shows the editor's own image, which would otherwise
/// still be decoding. A larger photo opens at once on a spinner and is
/// scaled down inside the route ([preparePhotoForEditing]); it appears
/// without the flight. The editor's decode leaves the cache when it closes.
/// A second call while one is opening returns null.
Future<EditedPhoto?> showPhotoEditor(
  BuildContext context, {
  required Uint8List bytes,
  required String heroTag,
}) async {
  if (_opening) return null;
  final format = EditedPhotoFormat.of(hasAlpha: photoHasAlpha(bytes));
  final ready = photoFitsEditing(bytes);
  try {
    if (ready) {
      _opening = true;
      try {
        await precacheImage(MemoryImage(bytes), context, onError: (_, _) {});
      } finally {
        _opening = false;
      }
      if (!context.mounted) return null;
    }
    return await Navigator.of(context).push<EditedPhoto>(
      NotionMediaRoute(
        builder: (_) => PhotoEditorPage(
          bytes: bytes,
          heroTag: heroTag,
          format: format,
          prepare: !ready,
        ),
      ),
    );
  } finally {
    if (ready) PaintingBinding.instance.imageCache.evict(MemoryImage(bytes));
  }
}

bool _opening = false;

class PhotoEditorPage extends StatefulWidget {
  final Uint8List bytes;
  final String heroTag;

  /// The output format; null reads it from [bytes].
  final EditedPhotoFormat? format;

  /// Scale [bytes] down to the output size first ([preparePhotoForEditing]),
  /// on a spinner.
  final bool prepare;

  const PhotoEditorPage({
    super.key,
    required this.bytes,
    required this.heroTag,
    this.format,
    this.prepare = false,
  });

  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  static const _tools = [
    NotionEditorTool(id: 'crop', icon: Icons.crop_rounded, label: 'Crop'),
    NotionEditorTool(id: 'draw', icon: Icons.brush_rounded, label: 'Draw'),
    NotionEditorTool(id: 'blur', icon: Icons.blur_on_rounded, label: 'Blur'),
    NotionEditorTool(
      id: 'filter',
      icon: Icons.auto_awesome_rounded,
      label: 'Filters',
    ),
    NotionEditorTool(id: 'tune', icon: Icons.tune_rounded, label: 'Adjust'),
  ];

  final _editor = GlobalKey<ProImageEditorState>();
  final _paint = PhotoPaintSession();
  late final EditedPhotoFormat _format =
      widget.format ??
      EditedPhotoFormat.of(hasAlpha: photoHasAlpha(widget.bytes));
  EditedPhoto? _result;
  bool _closed = false;

  /// What the editor works on: [PhotoEditorPage.bytes], or their scaled
  /// copy once it is ready.
  Uint8List? _source;

  @override
  void initState() {
    super.initState();
    if (!widget.prepare) {
      _source = widget.bytes;
      return;
    }
    unawaited(
      preparePhotoForEditing(widget.bytes).then((source) {
        if (mounted) setState(() => _source = source);
      }),
    );
  }

  @override
  void dispose() {
    _paint.dispose();
    // The editor's full-size decode would otherwise stay in the app's
    // image cache (a 4096-px photo is 50 MB of it).
    final source = _source;
    if (source != null) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(source));
    }
    super.dispose();
  }

  void _open(NotionEditorTool tool) {
    final editor = _editor.currentState;
    if (editor == null) return;
    switch (tool.id) {
      case 'crop':
        editor.openCropRotateEditor();
      case 'draw' || 'blur':
        _paint.censor = tool.id == 'blur';
        editor.openPaintEditor();
      case 'filter':
        editor.openFilterEditor();
      case 'tune':
        editor.openTuneEditor();
    }
  }

  /// The paint editor has its first frame: Blur starts on the blur area,
  /// Draw on the pen, each with the session's strength for censor areas.
  void _paintReady() {
    final paint = _editor.currentState?.paintEditor.currentState;
    if (paint == null || !paint.mounted) return;
    final mode = _paint.censor ? PaintMode.blur : PaintMode.freeStyle;
    if (paint.paintMode != mode) paint.setMode(mode);
    paint.paintCtrl.setCensorStrength(
      CensorStrength.of(
        mode,
        _paint.strength,
        MediaQuery.devicePixelRatioOf(context),
      ),
    );
  }

  /// A stroke or area was drawn. The package reports it just before it adds
  /// the layer, so the shape is applied once that is done (a microtask runs
  /// before the frame that shows it).
  void _drawingDone() => scheduleMicrotask(() {
    final paint = _editor.currentState?.paintEditor.currentState;
    if (paint != null) _paint.shapeNewArea(paint);
  });

  Future<void> _complete(Uint8List bytes) async {
    _result = EditedPhoto(bytes, _format);
  }

  /// The editor or one of its tools closes. With this callback set, a
  /// tool's Back (`close()` of the package's sub-editors) only calls it with
  /// the tool's mode and leaves the closing to us: the tool's route is the
  /// top one, so it is popped (doing nothing here left Back dead in every
  /// tool). The main mode closes the editor with its result.
  void _close(EditorMode mode) {
    if (!mounted) return;
    if (mode != EditorMode.main) {
      Navigator.of(context).pop();
      return;
    }
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop(_result);
  }

  Future<bool> _confirmDiscard(ProImageEditorState editor) async {
    if (!mounted) return false;
    return showNotionConfirmDialog(
      context: context,
      title: 'Discard changes?',
      message: 'Your edits to this photo will be lost.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep editing',
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    if (source == null) {
      return _Preparing(onClose: () => Navigator.pop(context));
    }
    final configs = MediaEditorSkin.configs(
      context,
      heroTag: widget.heroTag,
      paintSession: _paint,
      loading: (_) => const _Saving(),
      mainEditor: MainEditorConfigs(
        tools: const [
          SubEditorMode.cropRotate,
          SubEditorMode.paint,
          SubEditorMode.filter,
          SubEditorMode.tune,
        ],
        widgets: MainEditorWidgets(
          closeWarningDialog: _confirmDiscard,
          appBar: (editor, stream) => MediaEditorSkin.topBar(
            stream: stream,
            builder: () => NotionEditorTopBar(
              title: 'Edit photo',
              onClose: editor.closeEditor,
              onUndo: editor.undoAction,
              onRedo: editor.redoAction,
              canUndo: editor.canUndo,
              canRedo: editor.canRedo,
              onDone: editor.doneEditing,
            ),
          ),
          bottomBar: (editor, stream, key) => ReactiveWidget(
            stream: stream,
            builder: (_) => Padding(
              key: key,
              padding: const EdgeInsets.only(
                top: NotionSpace.xs,
                bottom: NotionSpace.sm,
              ),
              child: NotionEditorDock(tools: _tools, onSelected: _open),
            ),
          ),
        ),
      ),
      paintEditor: const PaintEditorConfigs(
        tools: [
          PaintMode.freeStyle,
          PaintMode.arrow,
          PaintMode.rect,
          PaintMode.circle,
          PaintMode.blur,
          PaintMode.pixelate,
          PaintMode.eraser,
        ],
        showLayers: true,
        enableZoomWhileDrawing: false,
      ),
      imageGeneration: ImageGenerationConfigs(
        outputFormat: _format == EditedPhotoFormat.png
            ? OutputFormat.png
            : OutputFormat.jpg,
        jpegQuality: editedPhotoJpegQuality,
        // Done without an edit keeps the picked file (an animated GIF too).
        allowEmptyEditingCompletion: false,
        maxOutputSize: const Size.square(editedPhotoMaxSide),
        // A fresh encode, so the source's EXIF (location) never rides along.
        enableUseOriginalBytes: false,
      ),
    );
    return ColoredBox(
      color: NotionMediaColors.viewer,
      child: ProImageEditor.memory(
        source,
        key: _editor,
        configs: configs,
        callbacks: ProImageEditorCallbacks(
          onImageEditingComplete: _complete,
          onCloseEditor: _close,
          mainEditorCallbacks: MainEditorCallbacks(
            helperLines: HelperLinesCallbacks(
              onLineHit: NotionHaptics.selection,
            ),
          ),
          paintEditorCallbacks: PaintEditorCallbacks(
            onAfterViewInit: _paintReady,
            onDrawingDone: _drawingDone,
          ),
        ),
      ),
    );
  }
}

/// A large photo is being scaled down for the editor: the stage with a
/// spinner (shown only when the wait is not short) and a way out.
class _Preparing extends StatelessWidget {
  final VoidCallback onClose;

  const _Preparing({required this.onClose});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: NotionMediaColors.viewer,
    child: SafeArea(
      child: Column(
        children: [
          NotionEditorTopBar(
            title: 'Edit photo',
            onClose: onClose,
            onDone: null,
          ),
          const Expanded(
            child: Center(
              child: NotionDelayedSpinner(
                size: NotionSize.iconLg,
                color: NotionMediaColors.onScrim,
                maxSpin: null,
                semanticsLabel: 'Preparing photo',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The photo is being written: a short wait, shown only when it is not.
class _Saving extends StatelessWidget {
  const _Saving();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: NotionMediaColors.scrim,
    child: Center(
      child: NotionDelayedReveal(
        child: Padding(
          padding: EdgeInsets.all(NotionSpace.lg),
          child: NotionEditorProgress(label: 'Saving photo…', progress: null),
        ),
      ),
    ),
  );
}

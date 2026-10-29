// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/editor/media_editor_skin.dart';
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
Future<EditedPhoto?> showPhotoEditor(
  BuildContext context, {
  required Uint8List bytes,
  required String heroTag,
}) => Navigator.of(context).push<EditedPhoto>(
  NotionMediaRoute(
    builder: (_) => PhotoEditorPage(bytes: bytes, heroTag: heroTag),
  ),
);

class PhotoEditorPage extends StatefulWidget {
  final Uint8List bytes;
  final String heroTag;

  const PhotoEditorPage({
    super.key,
    required this.bytes,
    required this.heroTag,
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
  final _censoring = ValueNotifier(false);
  late final EditedPhotoFormat _format = EditedPhotoFormat.of(
    hasAlpha: photoHasAlpha(widget.bytes),
  );
  EditedPhoto? _result;
  bool _closed = false;

  @override
  void dispose() {
    _censoring.dispose();
    super.dispose();
  }

  void _open(NotionEditorTool tool) {
    final editor = _editor.currentState;
    if (editor == null) return;
    switch (tool.id) {
      case 'crop':
        editor.openCropRotateEditor();
      case 'draw' || 'blur':
        final censor = tool.id == 'blur';
        _censoring.value = censor;
        editor.openPaintEditor();
        if (censor) {
          // The paint editor mounts with its brush; the Blur tool starts
          // on the blur area instead.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => editor.paintEditor.currentState?.setMode(PaintMode.blur),
          );
        }
      case 'filter':
        editor.openFilterEditor();
      case 'tune':
        editor.openTuneEditor();
    }
  }

  Future<void> _complete(Uint8List bytes) async {
    _result = EditedPhoto(bytes, _format);
  }

  void _close(EditorMode mode) {
    if (mode != EditorMode.main || _closed || !mounted) return;
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
    final configs = MediaEditorSkin.configs(
      context,
      heroTag: widget.heroTag,
      censoring: _censoring,
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
        widget.bytes,
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
        ),
      ),
    );
  }
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

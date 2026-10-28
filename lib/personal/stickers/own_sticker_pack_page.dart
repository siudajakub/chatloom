// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_selector.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'own_sticker_pack.dart';
import 'sticker_library.dart';
import 'sticker_pack_import.dart';
import 'sticker_tile.dart' show stickerCacheName;

/// Settings › Stickers › Your sticker pack.
const ownStickerPackPath = '/rooms/settings/chat/stickers/own';

/// Picks images for the pack (tests replace it).
typedef OwnStickerPicker =
    Future<List<OwnStickerInput>> Function(BuildContext context);

Future<List<OwnStickerInput>> _pickImages(BuildContext context) async {
  final files = await selectFiles(
    context,
    title: 'Choose sticker images',
    type: FileType.image,
    allowMultiple: true,
  );
  return [
    for (final file in files)
      OwnStickerInput(bytes: await file.readAsBytes(), name: file.name),
  ];
}

/// The account's own pack: pick images (PNG, WebP, GIF, JPEG; animated
/// WebP and GIF stay animated), give each an emoji, upload; rename,
/// reorder by drag, change an emoji, delete with Undo.
class OwnStickerPackPage extends StatefulWidget {
  const OwnStickerPackPage({
    super.key,
    required this.client,
    this.library,
    this.editor,
    this.picker,
  });

  final Client client;
  final StickerLibrary? library;
  final OwnStickerPackEditor? editor;
  final OwnStickerPicker? picker;

  @override
  State<OwnStickerPackPage> createState() => _OwnStickerPackPageState();
}

class _Draft {
  _Draft(this.input) : emoji = input.emoji ?? '';
  OwnStickerInput input;
  String emoji;
  String? problem;
}

class _OwnStickerPackPageState extends State<OwnStickerPackPage> {
  late final StickerLibrary _library =
      widget.library ?? StickerLibrary.of(widget.client);
  late final OwnStickerPackEditor _editor =
      widget.editor ??
      OwnStickerPackEditor.of(widget.client, library: _library);
  final _drafts = <_Draft>[];

  /// (done, total) while uploading.
  (int, int)? _progress;
  bool _saving = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _library.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _library.removeListener(_changed);
    super.dispose();
  }

  void _say(String text, {VoidCallback? undo}) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(text),
          action: undo == null
              ? null
              : SnackBarAction(label: 'Undo', onPressed: undo),
        ),
      );

  Future<void> _pick() async {
    final picked = await (widget.picker ?? _pickImages)(context);
    if (!mounted || picked.isEmpty) return;
    setState(() => _drafts.addAll(picked.map(_Draft.new)));
  }

  Future<void> _upload() async {
    if (_progress != null || _drafts.isEmpty) return;
    final drafts = List.of(_drafts);
    setState(() => _progress = (0, drafts.length));
    final OwnPackAddResult result;
    try {
      result = await _editor.add(
        [
          for (final d in drafts)
            OwnStickerInput(
              bytes: d.input.bytes,
              name: d.input.name,
              emoji: d.emoji,
            ),
        ],
        packName: _editor.pack == null
            ? OwnStickerPackEditor.defaultName
            : null,
        cancelled: () => _disposed,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
      );
    } on StickerImportException catch (e) {
      if (mounted) {
        setState(() => _progress = null);
        _say(e.message);
      }
      return;
    }
    if (!mounted) return;
    final failedBytes = {for (final (input, _) in result.failed) input.bytes};
    setState(() {
      _progress = null;
      // Failed images stay, with their reason, for another try.
      _drafts.removeWhere((d) => !failedBytes.contains(d.input.bytes));
      for (final (input, reason) in result.failed) {
        for (final d in _drafts) {
          if (identical(d.input.bytes, input.bytes)) d.problem = reason;
        }
      }
    });
    _say(
      [
        if (result.added > 0)
          result.added == 1
              ? '1 sticker added'
              : '${result.added} stickers added',
        if (result.duplicates > 0)
          result.duplicates == 1
              ? '1 was already in your pack'
              : '${result.duplicates} were already in your pack',
        if (result.failed.isNotEmpty)
          '${result.failed.length} couldn’t be added',
      ].join(' · '),
    );
  }

  Future<String?> _ask({
    required String title,
    required String initial,
    required String hint,
    String? helper,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showNotionCustomDialog<String>(
      context: context,
      builder: (context) => NotionDialog(
        title: title,
        content: NotionTextField(
          controller: controller,
          autofocus: true,
          hint: hint,
          helper: helper,
          textInputAction: TextInputAction.done,
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          NotionButton.ghost(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).pop(),
          ),
          NotionButton.primary(
            label: 'Save',
            onPressed: () => Navigator.of(context).pop(controller.text),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _write(Future<void> Function() change) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await change();
    } on StickerImportException catch (e) {
      if (mounted) _say(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename() async {
    final name = await _ask(
      title: 'Pack name',
      initial: _editor.name,
      hint: OwnStickerPackEditor.defaultName,
    );
    if (name == null || !mounted) return;
    await _write(() => _editor.rename(name));
  }

  Future<void> _editEmoji(String shortcode, String current) async {
    final emoji = await _ask(
      title: 'Emoji',
      initial: current,
      hint: '😀',
      helper: 'Typing this emoji suggests the sticker.',
    );
    if (emoji == null || !mounted) return;
    await _write(() => _editor.setEmoji(shortcode, emoji));
  }

  Future<void> _editDraftEmoji(_Draft draft) async {
    final emoji = await _ask(
      title: 'Emoji',
      initial: draft.emoji,
      hint: '😀',
      helper: 'Typing this emoji suggests the sticker.',
    );
    if (emoji == null || !mounted) return;
    setState(() => draft.emoji = emoji.trim());
  }

  Future<void> _delete(String shortcode, Map<String, Object?> image) async {
    final order = [for (final (key, _) in _editor.images) key];
    await _write(() => _editor.remove([shortcode]));
    if (!mounted) return;
    _say(
      'Sticker removed',
      undo: () => unawaited(
        _write(() => _editor.restore(shortcode, image, order: order)),
      ),
    );
  }

  void _reorder(List<String> keys, int from, int to) {
    final order = List.of(keys);
    final moved = order.removeAt(from);
    order.insert(to.clamp(0, order.length), moved);
    unawaited(_write(() => _editor.reorder(order)));
  }

  Widget _imageOf(Map<String, Object?> image) {
    final url = image['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    final placeholder = Icon(
      Icons.image_outlined,
      color: context.notion.colors.textTertiary,
    );
    if (uri == null) return placeholder;
    return TickerMode(
      enabled: false,
      child: MxcImage(
        uri: uri,
        client: widget.client,
        width: NotionSize.iconLg,
        height: NotionSize.iconLg,
        fit: BoxFit.contain,
        cacheKey: uri.toString(),
        cacheName: stickerCacheName,
        borderRadius: NotionRadius.xsAll,
        animationDuration: Duration.zero,
        placeholder: (_) => placeholder,
        usePlaceholderOnError: true,
      ),
    );
  }

  Widget _draftImage(Uint8List bytes) => ClipRRect(
    borderRadius: NotionRadius.xsAll,
    child: Image.memory(
      bytes,
      width: NotionSize.iconLg,
      height: NotionSize.iconLg,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, _, _) => Icon(
        Icons.broken_image_outlined,
        color: context.notion.colors.textTertiary,
      ),
    ),
  );

  List<Widget> _draftSection() {
    final notion = context.notion;
    final progress = _progress;
    return [
      NotionSectionHeader(
        title: _drafts.length == 1
            ? '1 new image'
            : '${_drafts.length} new images',
      ),
      for (final draft in _drafts)
        NotionListRow(
          key: ObjectKey(draft),
          leading: _draftImage(draft.input.bytes),
          title: draft.emoji.isEmpty
              ? draft.input.name
              : '${draft.emoji}  ${draft.input.name}',
          subtitle:
              draft.problem ??
              (draft.emoji.isEmpty ? 'Tap to set an emoji' : null),
          onTap: progress != null ? null : () => _editDraftEmoji(draft),
          trailing: NotionIconButton(
            icon: Icons.close,
            label: 'Don’t add ${draft.input.name}',
            onPressed: progress != null
                ? null
                : () => setState(() => _drafts.remove(draft)),
          ),
        ),
      const SizedBox(height: NotionSpace.sm),
      NotionButton.primary(
        key: const ValueKey('own-pack-upload'),
        label: progress != null
            ? 'Uploading ${(progress.$1 + 1).clamp(1, progress.$2)} of ${progress.$2}…'
            : _drafts.length == 1
            ? 'Add 1 sticker'
            : 'Add ${_drafts.length} stickers',
        icon: Icons.upload_outlined,
        expand: true,
        busy: progress != null,
        onPressed: progress != null ? null : _upload,
      ),
      Padding(
        padding: const EdgeInsets.only(top: NotionSpace.xs),
        child: Text(
          'Square images up to 512 × 512 and 2 MB work best. Animated WebP '
          'and GIF stay animated.',
          style: notion.typography.footnoteMuted,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final images = _editor.images;
    final keys = [for (final (key, _) in images) key];
    return NotionSettingsScaffold(
      title: 'Your sticker pack',
      actions: [
        if (_saving) const NotionDelayedSpinner(),
        NotionIconButton(
          icon: Icons.add_photo_alternate_outlined,
          label: 'Choose images',
          onPressed: _progress != null ? null : _pick,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (images.isEmpty && _drafts.isEmpty)
            NotionEmptyState(
              icon: Icons.add_photo_alternate_outlined,
              title: 'Make your own stickers',
              message:
                  'Choose images from your device. Each one becomes a sticker '
                  'you can send in any chat.',
              action: NotionButton.primary(
                key: const ValueKey('own-pack-choose'),
                label: 'Choose images',
                icon: Icons.add_photo_alternate_outlined,
                onPressed: _pick,
              ),
            ),
          if (_drafts.isNotEmpty) ..._draftSection(),
          if (images.isNotEmpty) ...[
            const NotionSettingsSection('Pack'),
            NotionListRow(
              key: const ValueKey('own-pack-name'),
              leading: const Icon(Icons.drive_file_rename_outline),
              title: _editor.name,
              subtitle: 'Pack name',
              onTap: _rename,
            ),
            NotionSettingsSection(
              images.length == 1 ? '1 sticker' : '${images.length} stickers',
            ),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: images.length,
              onReorderItem: (from, to) => _reorder(keys, from, to),
              proxyDecorator: (child, _, _) => Material(
                color: notion.colors.selected,
                borderRadius: NotionRadius.rowAll,
                child: child,
              ),
              itemBuilder: (context, i) {
                final (shortcode, image) = images[i];
                final body = image['body'];
                final emoji = body is String && body != shortcode ? body : '';
                return KeyedSubtree(
                  key: ValueKey('own-$shortcode'),
                  child: NotionListRow(
                    leading: _imageOf(image),
                    title: emoji.isEmpty ? shortcode : emoji,
                    subtitle: emoji.isEmpty ? 'Tap to set an emoji' : shortcode,
                    onTap: () => _editEmoji(shortcode, emoji),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NotionIconButton(
                          icon: Icons.delete_outline,
                          label: 'Remove $shortcode',
                          onPressed: () => _delete(shortcode, image),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.all(NotionSpace.xs),
                            child: Icon(
                              Icons.drag_handle,
                              semanticLabel: 'Reorder $shortcode',
                              color: notion.colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.lg),
            child: Text(
              'Your pack is kept in your Matrix account and its images on your '
              'server, unencrypted like every sticker pack, so your server can '
              'see them. Other Matrix apps show it too.',
              style: notion.typography.footnoteMuted,
            ),
          ),
        ],
      ),
    );
  }
}

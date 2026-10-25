// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_pack_import.dart';
import 'sticker_tile.dart';

/// Telegram's pack sheet: the stickers of a pack with "Add N stickers" or
/// "Remove". Opened from a `t.me/addstickers` link, a received sticker,
/// the panel and settings. A pack that is not installed is previewed
/// through its network's bridge first. [onSend] (from a chat) sends a
/// tapped sticker.
Future<void> showStickerPackSheet(
  BuildContext context, {
  required Client client,
  StickerPackLink? link,
  StickerPack? pack,
  void Function(StickerItem item)? onSend,
  StickerPackProvisioning? provisioning,
  StickerLibrary? library,
}) {
  assert(link != null || pack != null);
  return showNotionSheet<void>(
    context: context,
    builder: (context) => StickerPackSheet(
      client: client,
      link: link,
      pack: pack,
      onSend: onSend,
      provisioning: provisioning,
      library: library,
    ),
  );
}

class StickerPackSheet extends StatefulWidget {
  const StickerPackSheet({
    super.key,
    required this.client,
    this.link,
    this.pack,
    this.onSend,
    this.provisioning,
    this.library,
  });

  final Client client;
  final StickerPackLink? link;
  final StickerPack? pack;
  final void Function(StickerItem item)? onSend;
  final StickerPackProvisioning? provisioning;
  final StickerLibrary? library;

  @override
  State<StickerPackSheet> createState() => _StickerPackSheetState();
}

class _StickerPackSheetState extends State<StickerPackSheet> {
  late final StickerLibrary _library =
      widget.library ?? StickerLibrary.of(widget.client);
  late final StickerPackProvisioning _provisioning =
      widget.provisioning ?? StickerPackProvisioning.of(widget.client);
  ImagePackContent? _preview;
  bool _loading = false, _importing = false;
  String? _error;

  StickerPackLink? get _link =>
      widget.link ?? StickerPackLink.parse(widget.pack?.packUrl);

  /// The installed pack (live: it may be added or removed meanwhile).
  StickerPack? get _installed {
    final pack = widget.pack;
    if (pack != null) {
      final current = _library.packByKey(pack.key);
      if (current != null) return current;
    }
    final link = _link;
    return link == null ? null : _library.packByUrl(link.url);
  }

  @override
  void initState() {
    super.initState();
    _library.addListener(_changed);
    if (_installed == null && widget.pack == null) unawaited(_loadPreview());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _library.removeListener(_changed);
    super.dispose();
  }

  Future<void> _loadPreview() async {
    final link = _link;
    if (link == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await _provisioning.preview(link);
      if (!mounted) return;
      setState(() => _preview = preview);
    } on StickerImportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final link = _link;
    if (link == null) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      await _provisioning.install(
        link,
        title: _preview?.pack.displayName ?? widget.pack?.title,
        preview: _preview,
        library: _library,
      );
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('${_title()} added to your stickers')),
      );
    } on StickerImportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _remove(StickerPack pack) {
    final index = _library.doc.packs.indexWhere((r) => r.key == pack.key);
    _library.removePack(pack);
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    messenger?.showSnackBar(
      SnackBar(
        content: Text('${pack.title} removed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _library.restorePack(pack, index: index),
        ),
      ),
    );
  }

  String _title() {
    final installed = _installed;
    if (installed != null) return installed.title;
    final name = _preview?.pack.displayName ?? widget.pack?.title;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return _link?.name ?? 'Sticker pack';
  }

  List<StickerItem> _stickers() {
    final installed = _installed ?? widget.pack;
    if (installed != null) return installed.stickers;
    final preview = _preview;
    if (preview == null) return const [];
    return StickerPack.fromContent(
      preview,
      key: 'preview|${_link?.url}',
      source: StickerPackSource.installed,
    ).stickers;
  }

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final installed = _installed;
    final stickers = _stickers();
    final link = _link;
    final media = MediaQuery.sizeOf(context);
    final width =
        math.min(media.width, NotionSize.contentMaxWidth) - 2 * NotionSpace.lg;
    const columns = 5;
    final tile = width / columns;
    final rows = (stickers.length / columns).ceil();
    final gridHeight = math.min(media.height * .5, math.max(1, rows) * tile);
    final canAdd = installed == null && link != null && _preview != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _title(),
          style: notion.typography.headline,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (stickers.isNotEmpty || link != null)
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xxs),
            child: Text(
              [
                if (stickers.isNotEmpty)
                  stickers.length == 1
                      ? '1 sticker'
                      : '${stickers.length} stickers',
                if (link != null) link.networkLabel,
                if (installed != null) 'In your stickers',
              ].join(' · '),
              style: notion.typography.footnoteMuted,
            ),
          ),
        const SizedBox(height: NotionSpace.sm),
        SizedBox(
          height: gridHeight,
          child: NotionFadeThrough(
            child: _loading && stickers.isEmpty
                ? KeyedSubtree(
                    key: const ValueKey('loading'),
                    child: _SkeletonGrid(tile: tile, columns: columns),
                  )
                : GridView.builder(
                    key: const ValueKey('grid'),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: tile,
                    ),
                    itemCount: stickers.length,
                    itemBuilder: (context, i) {
                      final item = stickers[i];
                      return StickerTile(
                        key: ValueKey(item.key),
                        item: item,
                        client: widget.client,
                        size: tile,
                        onTap: () {
                          final send = widget.onSend;
                          if (send == null) return;
                          Navigator.of(context).pop();
                          send(item);
                        },
                        onLongPress: () => showStickerPreview(
                          context,
                          item: item,
                          client: widget.client,
                          actions: [
                            if (widget.onSend != null)
                              StickerPreviewAction(
                                icon: Icons.send_outlined,
                                label: 'Send',
                                onSelected: () {
                                  Navigator.of(context).pop();
                                  widget.onSend!(item);
                                },
                              ),
                            _favouriteAction(item),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: NotionSpace.sm),
          NotionCallout(
            icon: Icons.error_outline,
            tone: NotionCalloutTone.warning,
            title: _error!,
            actionLabel: _preview == null && installed == null
                ? 'Try again'
                : null,
            onAction: _preview == null && installed == null
                ? _loadPreview
                : null,
          ),
        ],
        const SizedBox(height: NotionSpace.md),
        if (installed != null)
          installed.ref == null &&
                  installed.source != StickerPackSource.enabledElsewhere
              ? const SizedBox.shrink()
              : NotionButton(
                  label: 'Remove from ChatLoom',
                  icon: Icons.remove_circle_outline,
                  expand: true,
                  onPressed: () => _remove(installed),
                )
        else if (link != null)
          NotionButton.primary(
            label: stickers.isEmpty
                ? 'Add sticker pack'
                : 'Add ${stickers.length} stickers',
            icon: Icons.add,
            expand: true,
            busy: _importing,
            onPressed: canAdd ? _add : null,
          ),
        if (link != null) ...[
          const SizedBox(height: NotionSpace.xs),
          NotionButton.ghost(
            label: 'Open in ${link.networkLabel}',
            icon: Icons.open_in_new,
            expand: true,
            onPressed: () =>
                launchUrlString(link.url, mode: LaunchMode.externalApplication),
          ),
        ],
      ],
    );
  }

  StickerPreviewAction _favouriteAction(StickerItem item) {
    final favourite = _library.isFavourite(item);
    return StickerPreviewAction(
      icon: favourite ? Icons.star : Icons.star_outline,
      label: favourite ? 'Remove from favourites' : 'Add to favourites',
      onSelected: () => _library.toggleFavourite(item),
    );
  }
}

class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid({required this.tile, required this.columns});
  final double tile;
  final int columns;

  @override
  Widget build(BuildContext context) => NotionSkeleton(
    enabled: true,
    child: GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisExtent: tile,
      ),
      itemCount: columns * 2,
      itemBuilder: (context, _) => Padding(
        padding: const EdgeInsets.all(NotionSpace.xs),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.notion.colors.surface,
            borderRadius: NotionRadius.mdAll,
          ),
        ),
      ),
    ),
  );
}

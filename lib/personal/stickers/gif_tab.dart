// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_send_plan.dart';
import 'sticker_sender.dart';
import 'sticker_tile.dart';

/// A GIF search provider the GIF tab can use (Telegram's `@gif` through
/// the bridge is planned). None is registered yet: the tab then shows only
/// saved and recent GIFs and no search field. A source returns sendable
/// items (`m.video` + `fi.mau.gif` or `m.image` GIFs) that go through the
/// same per-network send adaptation as saved GIFs.
abstract interface class GifSearchSource {
  /// Shown as the search field's hint ("Search GIFs via Telegram").
  String get label;

  /// Whether it can search for a chat (its bridge is reachable).
  bool availableIn(Room room);

  /// Results for [query] from [offset] (paging).
  Future<List<StickerItem>> search(Room room, String query, {int offset = 0});
}

/// Registered GIF search providers, first available wins.
abstract final class GifSearchSources {
  static final List<GifSearchSource> registered = [];

  static GifSearchSource? forRoom(Room room) =>
      registered.where((s) => s.availableIn(room)).firstOrNull;
}

/// The GIFs tab: saved GIFs, then recently sent ones (Telegram's GIF tab
/// without a provider). Tap sends at once, long-press previews with Save /
/// Remove. Save a GIF from a chat by long-pressing it ("Save GIF").
class GifTab extends StatefulWidget {
  const GifTab({
    super.key,
    required this.host,
    this.searchFocus,
    this.library,
  });

  final ConversationComposerHost host;
  final FocusNode? searchFocus;
  final StickerLibrary? library;

  @override
  State<GifTab> createState() => _GifTabState();
}

class _GifTabState extends State<GifTab> {
  late StickerLibrary _library;
  final _query = TextEditingController();
  List<StickerItem>? _results;
  bool _searching = false;
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _library = widget.library ?? StickerLibrary.of(widget.host.room.client);
    _library.addListener(_changed);
  }

  @override
  void didUpdateWidget(GifTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.library ?? StickerLibrary.of(widget.host.room.client);
    if (!identical(next, _library)) {
      _library.removeListener(_changed);
      _library = next..addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _library.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(GifSearchSource source, String query) async {
    final generation = ++_searchGeneration;
    if (query.trim().isEmpty) {
      setState(() {
        _results = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await source.search(widget.host.room, query.trim());
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _results = results);
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _results = const []);
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _send(StickerItem item) =>
      StickerSender.send(context, widget.host, item);

  void _preview(StickerItem item) {
    final room = widget.host.room;
    final plan = StickerSendPlan.forRoom(room, item);
    final saved = _library.isSavedGif(item);
    final recent = _library.recentGifs.any((g) => g.key == item.key);
    showStickerPreview(
      context,
      item: item,
      client: room.client,
      note: plan.possible ? null : plan.reason,
      actions: [
        StickerPreviewAction(
          icon: Icons.send_outlined,
          label: 'Send',
          onSelected: plan.possible ? () => _send(item) : null,
        ),
        StickerPreviewAction(
          icon: saved ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined,
          label: saved ? 'Remove from saved GIFs' : 'Save GIF',
          onSelected: () => saved
              ? _library.removeSavedGif(item)
              : _library.saveGif(item),
        ),
        if (recent && !saved)
          StickerPreviewAction(
            icon: Icons.history_toggle_off,
            label: 'Remove from recent',
            onSelected: () => _library.removeRecentGif(item),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.host.room;
    final source = GifSearchSources.forRoom(room);
    final saved = _library.savedGifs;
    final savedKeys = {for (final g in saved) g.key};
    final recent = [
      for (final g in _library.recentGifs)
        if (!savedKeys.contains(g.key)) g,
    ];
    final results = _results;
    final body = results != null
        ? _GifGrid(
            key: const ValueKey('results'),
            sections: [('Results', results)],
            client: room.client,
            onTap: _send,
            onLongPress: _preview,
            empty: _searching ? null : 'No GIFs found',
          )
        : saved.isEmpty && recent.isEmpty
        ? const SingleChildScrollView(
            key: ValueKey('empty'),
            child: NotionEmptyState(
              icon: Icons.gif_box_outlined,
              title: 'No saved GIFs yet',
              message:
                  'Long-press a GIF in a chat and choose Save GIF. GIFs you send show up here too.',
            ),
          )
        : _GifGrid(
            key: const ValueKey('library'),
            sections: [
              if (saved.isNotEmpty) ('Saved', saved),
              if (recent.isNotEmpty) ('Recent', recent),
            ],
            client: room.client,
            onTap: _send,
            onLongPress: _preview,
          );
    return Column(
      children: [
        if (source != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NotionSpace.xs,
              NotionSpace.xxs,
              NotionSpace.xs,
              0,
            ),
            child: TextField(
              controller: _query,
              focusNode: widget.searchFocus,
              textInputAction: TextInputAction.search,
              onSubmitted: (q) => unawaited(_search(source, q)),
              onChanged: (q) {
                if (q.trim().isEmpty) unawaited(_search(source, q));
              },
              style: context.notion.typography.callout,
              decoration: InputDecoration(
                hintText: source.label,
                prefixIcon: const Icon(Icons.search, size: NotionSize.icon),
                isDense: true,
              ),
            ),
          ),
        Expanded(child: NotionFadeThrough(child: body)),
      ],
    );
  }
}

class _GifGrid extends StatelessWidget {
  const _GifGrid({
    super.key,
    required this.sections,
    required this.client,
    required this.onTap,
    required this.onLongPress,
    this.empty,
  });

  final List<(String, List<StickerItem>)> sections;
  final Client client;
  final void Function(StickerItem) onTap;
  final void Function(StickerItem) onLongPress;
  final String? empty;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      // Telegram shows GIFs larger than stickers: 3 per row on phones.
      final columns = math.max(3, (width / 140).floor()).clamp(3, 6);
      final tile = width / columns;
      if (sections.every((s) => s.$2.isEmpty) && empty != null) {
        return Center(
          child: Text(empty!, style: context.notion.typography.calloutMuted),
        );
      }
      return TickerMode(
        enabled: false,
        child: CustomScrollView(
          slivers: [
            for (final (title, items) in sections) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NotionSpace.sm,
                    NotionSpace.xs,
                    NotionSpace.sm,
                    NotionSpace.xxs,
                  ),
                  child: Text(
                    title,
                    style: context.notion.typography.captionMuted,
                  ),
                ),
              ),
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: tile,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) => StickerTile(
                  key: ValueKey('$title/${items[i].key}'),
                  item: items[i],
                  client: client,
                  size: tile,
                  fit: BoxFit.cover,
                  onTap: () => onTap(items[i]),
                  onLongPress: () => onLongPress(items[i]),
                ),
              ),
            ],
            const SliverPadding(
              padding: EdgeInsets.only(bottom: NotionSpace.xs),
            ),
          ],
        ),
      );
    },
  );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'gif_result_tile.dart';
import 'gif_search.dart';
import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_send_plan.dart';
import 'sticker_sender.dart';
import 'sticker_tile.dart';

/// The GIFs tab: saved GIFs, then recently sent ones, and search through
/// Telegram's `@gif` ([GifSearchSources]). Tap sends at once, long-press
/// previews with Save / Remove. Save a GIF from a chat by long-pressing it
/// ("Save GIF").
class GifTab extends StatefulWidget {
  const GifTab({
    super.key,
    required this.host,
    this.searchFocus,
    this.library,
    this.source,
  });

  final ConversationComposerHost host;
  final FocusNode? searchFocus;
  final StickerLibrary? library;

  /// The search provider (default: the first registered one).
  final GifSearchSource? source;

  /// Typing pause before a search is sent (Telegram: 300 ms).
  static const debounce = Duration(milliseconds: 350);

  @override
  State<GifTab> createState() => _GifTabState();
}

class _GifTabState extends State<GifTab> {
  late StickerLibrary _library;
  GifSearchSource? _source;
  final _query = TextEditingController();
  Timer? _debounce;
  String _activeQuery = '';
  List<GifSearchResult>? _results;
  String? _nextOffset;
  String? _error;
  bool _searching = false;
  bool _loadingMore = false;
  bool _focused = false;
  String? _busyId;
  int _searchGeneration = 0;

  Room get _room => widget.host.room;

  @override
  void initState() {
    super.initState();
    _library = widget.library ?? StickerLibrary.of(_room.client);
    _library.addListener(_changed);
    _attachSource();
    widget.searchFocus?.addListener(_focusChanged);
  }

  void _attachSource() {
    _source = widget.source ?? GifSearchSources.forRoom(_room);
    _source?.changes.addListener(_changed);
    _source?.prepare(_room);
  }

  @override
  void didUpdateWidget(GifTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.library ?? StickerLibrary.of(_room.client);
    if (!identical(next, _library)) {
      _library.removeListener(_changed);
      _library = next..addListener(_changed);
    }
    final source = widget.source ?? GifSearchSources.forRoom(_room);
    if (!identical(source, _source)) {
      _source?.changes.removeListener(_changed);
      _attachSource();
    }
    if (!identical(oldWidget.searchFocus, widget.searchFocus)) {
      oldWidget.searchFocus?.removeListener(_focusChanged);
      widget.searchFocus?.addListener(_focusChanged);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _focusChanged() {
    final focused = widget.searchFocus?.hasFocus ?? false;
    if (focused != _focused && mounted) setState(() => _focused = focused);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _library.removeListener(_changed);
    _source?.changes.removeListener(_changed);
    widget.searchFocus?.removeListener(_focusChanged);
    _query.dispose();
    super.dispose();
  }

  void _typed(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      _clear();
      return;
    }
    _debounce = Timer(GifTab.debounce, () => unawaited(_run(text)));
  }

  void _submitted(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      _clear();
    } else {
      unawaited(_run(text));
    }
  }

  void _clear() {
    ++_searchGeneration;
    setState(() {
      _activeQuery = '';
      _results = null;
      _nextOffset = null;
      _error = null;
      _searching = false;
      _loadingMore = false;
    });
  }

  /// Runs a search (first page) or loads the next page ([offset]). The
  /// previous results stay until the new ones arrive.
  Future<void> _run(String query, {String? offset}) async {
    final source = _source;
    if (source == null || !source.availability(_room).enabled) return;
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final more = offset != null;
    final generation = more ? _searchGeneration : ++_searchGeneration;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _searching = true;
        _activeQuery = trimmed;
      }
      _error = null;
    });
    try {
      final page = await source.search(_room, trimmed, offset: offset);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        if (more) {
          final seen = {for (final r in _results ?? const []) r.id};
          _results = [
            ...?_results,
            for (final r in page.results)
              if (seen.add(r.id)) r,
          ];
        } else {
          _results = page.results;
        }
        _nextOffset = page.results.isEmpty ? null : page.nextOffset;
      });
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _error = e is GifSearchException
            ? e.message
            : 'GIF search didn’t work. Try again.';
        if (!more) _results = const [];
        _nextOffset = null;
      });
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searching = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _loadMore() {
    final offset = _nextOffset;
    if (offset == null || _loadingMore || _searching) return;
    unawaited(_run(_activeQuery, offset: offset));
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  /// The sendable GIF of [result], or null (the reason was shown).
  Future<StickerItem?> _resolve(GifSearchResult result) async {
    final source = _source;
    if (source == null) return null;
    setState(() => _busyId = result.id);
    try {
      final media = await source.media(_room, result, video: true);
      final item = media.item;
      if (item == null) {
        _say('This GIF can’t be sent. Try another one.');
      }
      return item;
    } on GifSearchException catch (e) {
      _say(e.message);
      if (e.searchAgain && _activeQuery.isNotEmpty) {
        source.forget(_room);
        unawaited(_run(_activeQuery));
      }
      return null;
    } catch (_) {
      _say('This GIF couldn’t be loaded. Try again.');
      return null;
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _sendResult(GifSearchResult result) async {
    if (_busyId != null) return;
    final item = await _resolve(result);
    if (item == null || !mounted) return;
    await _send(item);
  }

  Future<void> _previewResult(GifSearchResult result) async {
    if (_busyId != null) return;
    final item = await _resolve(result);
    if (item == null || !mounted) return;
    _preview(item);
  }

  Future<void> _send(StickerItem item) =>
      StickerSender.send(context, widget.host, item);

  void _preview(StickerItem item) {
    final room = _room;
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
          icon: saved
              ? Icons.bookmark_remove_outlined
              : Icons.bookmark_add_outlined,
          label: saved ? 'Remove from saved GIFs' : 'Save GIF',
          onSelected: () =>
              saved ? _library.removeSavedGif(item) : _library.saveGif(item),
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

  Widget _libraryBody({required Key key}) {
    final room = _room;
    final saved = _library.savedGifs;
    final savedKeys = {for (final g in saved) g.key};
    final recent = [
      for (final g in _library.recentGifs)
        if (!savedKeys.contains(g.key)) g,
    ];
    if (saved.isEmpty && recent.isEmpty) {
      return SingleChildScrollView(
        key: key,
        child: const NotionEmptyState(
          icon: Icons.gif_box_outlined,
          title: 'No saved GIFs yet',
          message:
              'Search above, or long-press a GIF in a chat and choose Save GIF. GIFs you send show up here too.',
        ),
      );
    }
    return _GifGrid(
      key: key,
      sections: [
        if (saved.isNotEmpty) ('Saved', saved),
        if (recent.isNotEmpty) ('Recent', recent),
      ],
      client: room.client,
      onTap: _send,
      onLongPress: _preview,
    );
  }

  Widget _searchBody(GifSearchSource source, List<GifSearchResult> results) {
    final error = _error;
    if (results.isEmpty) {
      if (_searching) {
        return const Center(
          key: ValueKey('searching'),
          child: NotionDelayedSpinner(),
        );
      }
      return Center(
        key: const ValueKey('no-results'),
        child: Padding(
          padding: const EdgeInsets.all(NotionSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error ?? 'No GIFs found',
                textAlign: TextAlign.center,
                style: context.notion.typography.calloutMuted,
              ),
              if (error != null) ...[
                const SizedBox(height: NotionSpace.xs),
                NotionButton.ghost(
                  label: 'Try again',
                  onPressed: () => unawaited(_run(_activeQuery)),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return _GifResultsGrid(
      key: const ValueKey('results'),
      results: results,
      source: source,
      room: _room,
      busyId: _busyId,
      loadingMore: _loadingMore,
      footer: error,
      onNearEnd: _nextOffset == null ? null : _loadMore,
      onTap: (r) => unawaited(_sendResult(r)),
      onLongPress: (r) => unawaited(_previewResult(r)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final availability = source?.availability(_room);
    final results = _results;
    final body = source != null && results != null && _activeQuery.isNotEmpty
        ? _searchBody(source, results)
        : _libraryBody(key: const ValueKey('library'));
    final typography = context.notion.typography;
    final note = availability == null
        ? null
        : !availability.enabled
        ? availability.note
        : _focused && _query.text.trim().isEmpty
        ? source!.privacyNote
        : null;
    return Column(
      children: [
        if (source != null && availability != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NotionSpace.xs,
              NotionSpace.xxs,
              NotionSpace.xs,
              0,
            ),
            child: TextField(
              key: const ValueKey('gif-search-field'),
              controller: _query,
              focusNode: widget.searchFocus,
              enabled: availability.enabled,
              textInputAction: TextInputAction.search,
              onSubmitted: _submitted,
              onChanged: _typed,
              style: typography.callout,
              decoration: InputDecoration(
                hintText: availability.hint,
                helperText: note,
                helperMaxLines: 2,
                helperStyle: typography.captionMuted,
                prefixIcon: const Icon(Icons.search, size: NotionSize.icon),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(NotionSpace.sm),
                        child: NotionDelayedSpinner(size: NotionSize.iconSm),
                      )
                    : null,
                isDense: true,
              ),
            ),
          ),
        Expanded(child: NotionFadeThrough(child: body)),
      ],
    );
  }
}

/// Search results: a lazy 3-column grid (more on wide panels) whose cells
/// loop while visible; the next page loads near the end.
class _GifResultsGrid extends StatelessWidget {
  const _GifResultsGrid({
    super.key,
    required this.results,
    required this.source,
    required this.room,
    required this.onTap,
    required this.onLongPress,
    this.busyId,
    this.loadingMore = false,
    this.footer,
    this.onNearEnd,
  });

  final List<GifSearchResult> results;
  final GifSearchSource source;
  final Room room;
  final void Function(GifSearchResult) onTap;
  final void Function(GifSearchResult) onLongPress;
  final String? busyId;
  final bool loadingMore;
  final String? footer;
  final VoidCallback? onNearEnd;

  /// Rows before the end at which the next page is requested.
  static const _prefetchItems = 6;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = math.max(3, (width / 140).floor()).clamp(3, 6);
      const gap = NotionSpace.xxs;
      final tile = (width - gap * (columns + 1)) / columns;
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NotionSpace.sm,
                NotionSpace.xs,
                NotionSpace.sm,
                NotionSpace.xxs,
              ),
              child: Text(
                'Results from Telegram',
                style: context.notion.typography.captionMuted,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: gap),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: tile,
                crossAxisSpacing: gap,
                mainAxisSpacing: gap,
              ),
              itemCount: results.length,
              itemBuilder: (context, i) {
                final nearEnd = onNearEnd;
                if (nearEnd != null && i >= results.length - _prefetchItems) {
                  // Never notify during build.
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => nearEnd(),
                  );
                }
                final result = results[i];
                return GifResultTile(
                  key: ValueKey('gif-result-${result.id}'),
                  result: result,
                  source: source,
                  room: room,
                  size: tile,
                  busy: busyId == result.id,
                  onTap: () => onTap(result),
                  onLongPress: () => onLongPress(result),
                );
              },
            ),
          ),
          if (loadingMore || footer != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(NotionSpace.sm),
                child: Center(
                  child: loadingMore
                      ? const NotionDelayedSpinner()
                      : Text(
                          footer!,
                          textAlign: TextAlign.center,
                          style: context.notion.typography.captionMuted,
                        ),
                ),
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: NotionSpace.xs)),
        ],
      );
    },
  );
}

class _GifGrid extends StatelessWidget {
  const _GifGrid({
    super.key,
    required this.sections,
    required this.client,
    required this.onTap,
    required this.onLongPress,
  });

  final List<(String, List<StickerItem>)> sections;
  final Client client;
  final void Function(StickerItem) onTap;
  final void Function(StickerItem) onLongPress;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      // Telegram shows GIFs larger than stickers: 3 per row on phones.
      final columns = math.max(3, (width / 140).floor()).clamp(3, 6);
      final tile = width / columns;
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

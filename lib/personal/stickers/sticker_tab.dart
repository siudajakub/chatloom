// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_pack_sheet.dart';
import 'sticker_send_plan.dart';
import 'sticker_sender.dart';
import 'sticker_tile.dart';
import 'telegram_pack_import_page.dart';

/// One labelled block of the sticker grid (favourites, recents, a pack).
@immutable
class StickerSection {
  const StickerSection({
    required this.key,
    required this.title,
    required this.items,
    this.icon,
    this.iconUri,
    this.pack,
  });

  final String key;
  final String title;
  final List<StickerItem> items;

  /// Glyph in the strip (favourites, recents) or the pack's image.
  final IconData? icon;
  final Uri? iconUri;
  final StickerPack? pack;
}

/// The sections of the sticker tab in Telegram's order: favourites,
/// recents, the chat's own packs, then the installed packs.
List<StickerSection> stickerSections(StickerLibrary library, Room room) {
  final favourites = library.favourites;
  final favouriteKeys = {for (final f in favourites) f.key};
  final recent = [
    for (final r in library.recentStickers)
      if (!favouriteKeys.contains(r.key)) r,
  ];
  final installed = {for (final p in library.packs) p.key};
  final roomPacks = <StickerPack>[
    for (final entry in roomImagePacks(room).entries)
      StickerPack.fromContent(
        entry.value,
        key: StickerPackRef.packKeyOf(room.id, entry.key),
        source: StickerPackSource.room,
        fallbackTitle: 'Chat stickers',
      ),
  ];
  return [
    if (favourites.isNotEmpty)
      StickerSection(
        key: 'favourites',
        title: 'Favourites',
        items: favourites,
        icon: Icons.star_outline,
      ),
    if (recent.isNotEmpty)
      StickerSection(
        key: 'recent',
        title: 'Recent',
        items: recent,
        icon: Icons.history,
      ),
    for (final pack in roomPacks)
      if (pack.stickers.isNotEmpty && !installed.contains(pack.key))
        StickerSection(
          key: pack.key,
          title: pack.title,
          items: pack.stickers,
          iconUri: pack.icon,
          pack: pack,
        ),
    for (final pack in library.packs)
      StickerSection(
        key: pack.key,
        title: pack.title,
        items: pack.stickers,
        iconUri: pack.icon,
        pack: pack,
      ),
  ];
}

/// The Stickers tab: pack strip on top (search, favourites, recents,
/// packs), one lazy grid per section below. Tap sends at once and keeps
/// the panel open; long-press previews (Telegram). Only visible cells are
/// built; thumbnails are small and static.
class StickerTab extends StatefulWidget {
  const StickerTab({
    super.key,
    required this.host,
    this.searchFocus,
    this.library,
  });

  final ConversationComposerHost host;
  final FocusNode? searchFocus;
  final StickerLibrary? library;

  @override
  State<StickerTab> createState() => _StickerTabState();
}

class _StickerTabState extends State<StickerTab> {
  late StickerLibrary _library;
  final _scroll = ScrollController();
  final _strip = ScrollController();
  final _selected = ValueNotifier<int>(0);
  final _query = TextEditingController();
  bool _searching = false;

  /// Memo of the sections (rebuilt only when the library changes).
  (int, String)? _sectionsKey;
  List<StickerSection> _sections = const [];

  /// Section start offsets of the last layout, and their section keys.
  List<double> _offsets = const [];
  List<String> _offsetKeys = const [];

  static const _stripExtent = NotionSize.touchTarget;

  @override
  void initState() {
    super.initState();
    _library = widget.library ?? StickerLibrary.of(widget.host.room.client);
    _library.addListener(_changed);
    _scroll.addListener(_trackSection);
  }

  @override
  void didUpdateWidget(StickerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.library ?? StickerLibrary.of(widget.host.room.client);
    if (!identical(next, _library)) {
      _library.removeListener(_changed);
      _library = next..addListener(_changed);
      _sectionsKey = null;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _library.removeListener(_changed);
    _scroll.dispose();
    _strip.dispose();
    _selected.dispose();
    _query.dispose();
    super.dispose();
  }

  List<StickerSection> _currentSections() {
    final key = (_library.revision, widget.host.room.id);
    if (_sectionsKey != key) {
      _sectionsKey = key;
      _sections = stickerSections(_library, widget.host.room);
    }
    return _sections;
  }

  void _trackSection() {
    if (_searching || _offsets.isEmpty || !_scroll.hasClients) return;
    final offset = _scroll.offset + 1;
    var index = 0;
    for (var i = 0; i < _offsets.length; i++) {
      if (_offsets[i] <= offset) index = i;
    }
    if (_selected.value == index) return;
    _selected.value = index;
    _revealInStrip(index);
  }

  /// Keeps the selected pack icon visible in the strip (+1: search).
  void _revealInStrip(int index) {
    if (!_strip.hasClients) return;
    final position = _strip.position;
    final start = NotionSpace.xxs + (index + 1) * _stripExtent;
    final end = start + _stripExtent;
    double? target;
    if (start < position.pixels) {
      target = start;
    } else if (end > position.pixels + position.viewportDimension) {
      target = end - position.viewportDimension;
    }
    if (target == null) return;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    if (NotionMotion.reduced(context)) {
      _strip.jumpTo(clamped);
    } else {
      _strip.animateTo(
        clamped,
        duration: NotionMotion.short,
        curve: NotionMotion.standard,
      );
    }
  }

  /// A sent sticker joins the recents (or a favourite is added) above the
  /// pack being browsed: the grid keeps that pack where it was instead of
  /// jumping by the rows that appeared above it.
  void _keepAnchor(List<String> keys, List<double> offsets) {
    final previousKeys = _offsetKeys;
    final previous = _offsets;
    _offsetKeys = keys;
    if (_searching || !_scroll.hasClients || previous.isEmpty) return;
    final selected = _selected.value;
    if (selected >= previousKeys.length || _scroll.offset <= 0) return;
    final index = keys.indexOf(previousKeys[selected]);
    if (index < 0) return;
    final delta = offsets[index] - previous[selected];
    if (delta.abs() < .5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
      );
    });
  }

  void _jumpTo(int index) {
    if (_searching) _closeSearch();
    _selected.value = index;
    if (!_scroll.hasClients || index >= _offsets.length) return;
    final target = _offsets[index].clamp(0.0, _scroll.position.maxScrollExtent);
    if (NotionMotion.reduced(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: NotionMotion.medium,
        curve: NotionMotion.standard,
      );
    }
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() {
    widget.searchFocus?.unfocus();
    _query.clear();
    setState(() => _searching = false);
  }

  Future<void> _send(StickerItem item) =>
      StickerSender.send(context, widget.host, item);

  void _preview(StickerItem item, {StickerSection? section}) {
    final room = widget.host.room;
    final plan = StickerSendPlan.forRoom(room, item);
    final favourite = _library.isFavourite(item);
    final pack = section?.pack ?? _library.packOf(item);
    final client = room.client;
    showStickerPreview(
      context,
      item: item,
      client: client,
      note: plan.possible ? null : plan.reason,
      actions: [
        StickerPreviewAction(
          icon: Icons.send_outlined,
          label: 'Send',
          onSelected: plan.possible ? () => _send(item) : null,
        ),
        StickerPreviewAction(
          icon: favourite ? Icons.star : Icons.star_outline,
          label: favourite ? 'Remove from favourites' : 'Add to favourites',
          onSelected: () => _library.toggleFavourite(item),
        ),
        if (section?.key == 'recent')
          StickerPreviewAction(
            icon: Icons.history_toggle_off,
            label: 'Remove from recent',
            onSelected: () => _library.removeRecent(item),
          ),
        if (pack != null && section?.pack == null)
          StickerPreviewAction(
            icon: Icons.collections_outlined,
            label: 'View pack',
            onSelected: () => showStickerPackSheet(
              context,
              client: client,
              pack: pack,
              library: _library,
              onSend: _send,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = _currentSections();
    if (sections.isEmpty && !_searching) {
      return SingleChildScrollView(
        child: NotionEmptyState(
          icon: Icons.sticky_note_2_outlined,
          title: 'No sticker packs yet',
          message:
              'Add your Telegram packs, or tap a t.me/addstickers link in a chat.',
          action: NotionButton.primary(
            label: 'Import from Telegram',
            icon: Icons.download_outlined,
            onPressed: () => showTelegramPackImport(context),
          ),
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: _stripExtent,
          child: NotionFadeThrough(
            child: _searching
                ? KeyedSubtree(
                    key: const ValueKey('search'),
                    child: _searchField(),
                  )
                : KeyedSubtree(
                    key: const ValueKey('strip'),
                    child: _packStrip(sections),
                  ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _grid(context, constraints.maxWidth, sections),
          ),
        ),
      ],
    );
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _query,
            focusNode: widget.searchFocus,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            style: context.notion.typography.callout,
            decoration: const InputDecoration(
              hintText: 'Search stickers by emoji or word',
              prefixIcon: Icon(Icons.search, size: NotionSize.icon),
              isDense: true,
            ),
          ),
        ),
        NotionIconButton(
          icon: Icons.close,
          label: 'Close search',
          onPressed: _closeSearch,
        ),
      ],
    ),
  );

  Widget _packStrip(List<StickerSection> sections) {
    final client = widget.host.room.client;
    final colors = context.notion.colors;
    return ValueListenableBuilder<int>(
      valueListenable: _selected,
      builder: (context, selected, _) => ListView.builder(
        controller: _strip,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xxs),
        itemExtent: _stripExtent,
        itemCount: sections.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) {
            return NotionIconButton(
              icon: Icons.search,
              label: 'Search stickers',
              onPressed: _openSearch,
            );
          }
          if (i == sections.length + 1) {
            return NotionIconButton(
              icon: Icons.add,
              label: 'Add sticker packs',
              onPressed: () => showTelegramPackImport(context),
            );
          }
          final index = i - 1;
          final section = sections[index];
          final active = index == selected;
          final icon = section.icon;
          final uri = section.iconUri;
          return Semantics(
            button: true,
            selected: active,
            label: section.title,
            child: Tooltip(
              message: section.title,
              child: NotionPressable(
                scale: NotionMotion.pressIcon,
                onTap: () => _jumpTo(index),
                child: AnimatedContainer(
                  duration: NotionMotion.of(context, NotionMotion.quick),
                  curve: NotionMotion.standard,
                  margin: const EdgeInsets.all(NotionSpace.xxs),
                  decoration: BoxDecoration(
                    color: active
                        ? context.notion.palette.accentTint
                        : Colors.transparent,
                    borderRadius: NotionRadius.smAll,
                  ),
                  alignment: Alignment.center,
                  child: icon != null || uri == null
                      ? Icon(
                          icon ?? Icons.sticky_note_2_outlined,
                          size: NotionSize.iconMd,
                          color: active ? colors.text : colors.textSecondary,
                        )
                      : TickerMode(
                          enabled: false,
                          child: MxcImage(
                            uri: uri,
                            client: client,
                            width: NotionSize.iconLg + NotionSpace.xxs,
                            height: NotionSize.iconLg + NotionSpace.xxs,
                            fit: BoxFit.contain,
                            cacheKey: uri.toString(),
                            cacheName: stickerCacheName,
                            borderRadius: NotionRadius.xsAll,
                            placeholder: (_) => Icon(
                              Icons.sticky_note_2_outlined,
                              size: NotionSize.iconMd,
                              color: colors.textTertiary,
                            ),
                            usePlaceholderOnError: true,
                            animationDuration: Duration.zero,
                          ),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Phones get 5 columns (Telegram); wider panels as many ~72 pt cells
  /// as fit.
  static int columnsFor(double width) =>
      math.max(5, (width / 72).floor()).clamp(5, 10);

  Widget _grid(
    BuildContext context,
    double width,
    List<StickerSection> sections,
  ) {
    final client = widget.host.room.client;
    final columns = columnsFor(width);
    final tile = width / columns;
    final header =
        MediaQuery.textScalerOf(
          context,
        ).scale(NotionType.caption.fontSize! * 1.5) +
        NotionSpace.sm;
    if (_searching) {
      final query = _query.text;
      final results = query.trim().isEmpty
          ? const <StickerItem>[]
          : _library.search(
              query,
              languageCode: Localizations.localeOf(context).languageCode,
            );
      if (query.trim().isNotEmpty && results.isEmpty) {
        return Center(
          child: Text(
            'No stickers found',
            style: context.notion.typography.calloutMuted,
          ),
        );
      }
      return GridView.builder(
        padding: const EdgeInsets.only(bottom: NotionSpace.xs),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: tile,
        ),
        itemCount: results.length,
        itemBuilder: (context, i) => StickerTile(
          key: ValueKey(results[i].key),
          item: results[i],
          client: client,
          size: tile,
          onTap: () => _send(results[i]),
          onLongPress: () => _preview(results[i]),
        ),
      );
    }
    // Section offsets for the strip (headers and rows have fixed extents).
    final offsets = <double>[];
    var y = 0.0;
    for (final section in sections) {
      offsets.add(y);
      y += header + (section.items.length / columns).ceil() * tile;
    }
    _keepAnchor([for (final s in sections) s.key], offsets);
    _offsets = offsets;
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        for (final section in sections) ...[
          SliverToBoxAdapter(
            key: ValueKey('header-${section.key}'),
            child: SizedBox(
              height: header,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
                child: Align(
                  alignment: AlignmentDirectional.bottomStart,
                  child: Text(
                    section.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.notion.typography.captionMuted,
                  ),
                ),
              ),
            ),
          ),
          SliverGrid.builder(
            key: ValueKey('grid-${section.key}'),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: tile,
            ),
            itemCount: section.items.length,
            itemBuilder: (context, i) {
              final item = section.items[i];
              return StickerTile(
                key: ValueKey('${section.key}/${item.key}'),
                item: item,
                client: client,
                size: tile,
                onTap: () => _send(item),
                onLongPress: () => _preview(item, section: section),
              );
            },
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: NotionSpace.xs)),
      ],
    );
  }
}

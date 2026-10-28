// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'add_sticker_packs.dart';
import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_pack_sheet.dart';
import 'sticker_search.dart';
import 'sticker_send_plan.dart';
import 'sticker_sender.dart';
import 'sticker_tile.dart';

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

/// Where the sticker grid was (Telegram keeps the panel's place across
/// openings and chats): the section at the top and the distance into it,
/// so recents that changed meanwhile do not move the pack being browsed.
abstract final class _GridMemory {
  static String? section;
  static double within = 0;
}

/// Fixed geometry of the browsing grid: every header and row has a fixed
/// extent, so section offsets are exact without laying anything out.
class _GridLayout {
  _GridLayout({
    required this.columns,
    required this.tile,
    required this.header,
    required this.search,
    required List<StickerSection> sections,
  }) {
    var y = search;
    for (final section in sections) {
      offsets.add(y);
      keys.add(section.key);
      y += header + (section.items.length / columns).ceil() * tile;
    }
    extent = y + bottomPadding;
  }

  static const bottomPadding = NotionSpace.xs;

  final int columns;
  final double tile;
  final double header;
  final double search;
  final offsets = <double>[];
  final keys = <String>[];
  late final double extent;

  /// The section whose header is at (or last passed) the top edge; at the
  /// very end of the grid the last section, whose header may never reach
  /// the top.
  int indexAt(double pixels, {double maxScrollExtent = 0}) {
    if (offsets.isEmpty) return 0;
    if (maxScrollExtent > 0 && pixels >= maxScrollExtent - 1) {
      return offsets.length - 1;
    }
    var index = 0;
    for (var i = 0; i < offsets.length; i++) {
      if (offsets[i] > pixels + 1) break;
      index = i;
    }
    return index;
  }
}

/// The Stickers tab (Telegram's sticker page): the pack strip on top
/// (search, favourites, recents, packs, add), one [CustomScrollView] below
/// with the search field first (it floats back on any upward scroll, and
/// stays pinned while searching) and one group per section whose title
/// sticks to the top while its stickers pass under it.
///
/// - The strip follows the scroll and a tap on a pack scrolls there
///   (long distances jump to one screen before the pack and glide the
///   rest); the strip keeps the selected pack centred.
/// - The place in the grid survives tab switches, closing the panel and
///   other chats; recents and favourites that change above the browsed
///   pack never move it.
/// - Search is local and instant: emoji, words, shortcodes, alt text and
///   pack titles ([StickerSearchIndex]). Back closes the search first.
/// - Tap sends at once and keeps the panel open (the cell dips once);
///   long-press previews. Only visible cells are built, with fixed extents;
///   animated stickers play only while the grid rests.
class StickerTab extends StatefulWidget {
  const StickerTab({
    super.key,
    required this.host,
    this.searchFocus,
    this.library,
  });

  final ConversationComposerHost host;

  /// Focus node of the search field (created here when null).
  final FocusNode? searchFocus;
  final StickerLibrary? library;

  /// Phones get 5 columns (Telegram); wider panels as many ~72 pt cells
  /// as fit.
  static int columnsFor(double width) =>
      math.max(5, (width / 72).floor()).clamp(5, 10);

  @visibleForTesting
  static void debugResetPosition() {
    _GridMemory.section = null;
    _GridMemory.within = 0;
  }

  @override
  State<StickerTab> createState() => _StickerTabState();
}

class _StickerTabState extends State<StickerTab>
    with SingleTickerProviderStateMixin {
  late StickerLibrary _library;
  ScrollController? _scroll;
  final _strip = ScrollController();
  final _selected = ValueNotifier<int>(0);
  final _query = TextEditingController();
  FocusNode? _ownFocus;

  /// The search field keeps its state (and focus) when its header changes
  /// from floating to pinned.
  final _searchKey = GlobalKey(debugLabel: 'sticker search field');

  /// Animated stickers play only while the grid rests.
  final _idle = ValueNotifier<bool>(true);

  /// The last cell a sticker was sent from (it dips once).
  final _sent = ValueNotifier<StickerSentPulse?>(null);
  int _sentCount = 0;

  /// The query in effect (trimmed); empty when not searching.
  String _activeQuery = '';
  bool _focused = false;

  /// Grid offset to come back to when the search closes.
  double? _browseOffset;

  /// Set by a closing search: applied in the next layout, in that frame.
  double? _restoreOffset;

  /// The grid is jumping to the top for a search (not browsing).
  bool _searchJump = false;

  /// The section a strip tap scrolls to: the strip keeps it selected
  /// while the grid passes the others.
  int? _jumpTarget;

  /// Fades the results in when they change (from [NotionMotion.refreshFrom]).
  AnimationController? _fade;
  Animation<double>? _fadeOpacity;

  /// Memo of the sections and their search index (rebuilt only when the
  /// library changes).
  (int, String)? _sectionsKey;
  List<StickerSection> _sections = const [];
  StickerSearchIndex? _index;
  (String, (int, String)?, String)? _resultsKey;
  StickerSearchResults _results = StickerSearchResults.empty;

  _GridLayout? _layout;

  static const _stripExtent = NotionSize.touchTarget;

  FocusNode get _searchFocus =>
      widget.searchFocus ?? (_ownFocus ??= FocusNode());
  bool get _searching => _activeQuery.isNotEmpty;
  bool get _searchActive => _searching || _focused;

  @override
  void initState() {
    super.initState();
    _library = widget.library ?? StickerLibrary.of(widget.host.room.client);
    _library.addListener(_changed);
    _query.addListener(_queryChanged);
    _searchFocus.addListener(_focusChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealInStrip(_selected.value, animate: false),
    );
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
    if (!identical(oldWidget.searchFocus, widget.searchFocus)) {
      (oldWidget.searchFocus ?? _ownFocus)?.removeListener(_focusChanged);
      _searchFocus.addListener(_focusChanged);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _library.removeListener(_changed);
    _searchFocus.removeListener(_focusChanged);
    _ownFocus?.dispose();
    _scroll?.dispose();
    _strip.dispose();
    _selected.dispose();
    _query.dispose();
    _idle.dispose();
    _sent.dispose();
    _fade?.dispose();
    super.dispose();
  }

  List<StickerSection> _currentSections() {
    final key = (_library.revision, widget.host.room.id);
    if (_sectionsKey != key) {
      _sectionsKey = key;
      _sections = stickerSections(_library, widget.host.room);
      _index = null;
    }
    return _sections;
  }

  /// Everything the tab shows is searchable, the chat's own packs too.
  StickerSearchIndex get _searchIndex => _index ??= StickerSearchIndex(
    [for (final section in _sections) ...section.items],
    packs: [for (final section in _sections) ?section.pack],
  );

  StickerSearchResults _resultsFor(String query) {
    final language = Localizations.maybeLocaleOf(context)?.languageCode ?? '';
    final key = (query, _sectionsKey, language);
    if (_resultsKey != key) {
      _resultsKey = key;
      _results = _searchIndex.searchRanked(query, languageCode: language);
    }
    return _results;
  }

  // ---------------------------------------------------------------------
  // Scrolling.

  /// Applies a layout before the grid lays out: the first one restores the
  /// remembered place; later ones restore the place the search left, or
  /// keep the browsed section still when sections above it changed. Uses
  /// [ScrollPosition.correctPixels], so the content never shows a frame at
  /// the wrong place.
  void _applyLayout(_GridLayout layout, double viewport) {
    final previous = _layout;
    _layout = layout;
    if (_scroll == null) {
      var initial = 0.0;
      final remembered = _GridMemory.section;
      final index = remembered == null ? -1 : layout.keys.indexOf(remembered);
      if (index >= 0) {
        initial = layout.offsets[index] + _GridMemory.within;
        _selected.value = index;
      }
      initial = initial.clamp(0.0, math.max(0.0, layout.extent - viewport));
      _scroll = ScrollController(initialScrollOffset: initial)
        ..addListener(_scrolled);
      return;
    }
    final scroll = _scroll!;
    if (_searchActive || !scroll.hasClients) return;
    final position = scroll.position;
    final restore = _restoreOffset;
    if (restore != null) {
      _restoreOffset = null;
      final max = math.max(0.0, layout.extent - position.viewportDimension);
      final target = restore.clamp(0.0, max);
      if (target != position.pixels) position.correctPixels(target);
      final index = layout.indexAt(target, maxScrollExtent: max);
      _remember(layout, index, target);
      _selected.value = index;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealInStrip(index, animate: false),
      );
      return;
    }
    if (previous == null || position.pixels <= 0) return;
    // A sent sticker joins the recents (or a favourite is added) above the
    // pack being browsed: that pack stays where it was, in this frame.
    final selected = _selected.value;
    if (selected >= previous.keys.length) return;
    final index = layout.keys.indexOf(previous.keys[selected]);
    if (index < 0) return;
    final delta = layout.offsets[index] - previous.offsets[selected];
    if (index != selected) _selected.value = index;
    if (delta.abs() < .5) return;
    position.correctPixels(math.max(0.0, position.pixels + delta));
  }

  void _scrolled() {
    final layout = _layout;
    final scroll = _scroll;
    if (layout == null || scroll == null || _searchActive || _searchJump) {
      return;
    }
    if (!scroll.hasClients || layout.keys.isEmpty) return;
    final position = scroll.position;
    final pixels = position.pixels;
    final index = layout.indexAt(
      pixels,
      maxScrollExtent: position.maxScrollExtent,
    );
    _remember(layout, index, pixels);
    // A strip tap holds its pack while the grid glides past the others.
    if (_jumpTarget != null || _selected.value == index) return;
    _selected.value = index;
    _revealInStrip(index);
  }

  static void _remember(_GridLayout layout, int index, double pixels) {
    if (index >= layout.keys.length) return;
    _GridMemory.section = layout.keys[index];
    _GridMemory.within = pixels - layout.offsets[index];
  }

  /// Keeps the selected pack icon centred in the strip.
  void _revealInStrip(int index, {bool animate = true}) {
    if (!mounted || !_strip.hasClients) return;
    final position = _strip.position;
    final start = NotionSpace.xxs + index * _stripExtent;
    final target = (start - (position.viewportDimension - _stripExtent) / 2)
        .clamp(0.0, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return;
    if (!animate || NotionMotion.reduced(context)) {
      _strip.jumpTo(target);
    } else {
      unawaited(
        _strip.animateTo(
          target,
          duration: NotionMotion.short,
          curve: NotionMotion.standard,
        ),
      );
    }
  }

  /// Scrolls to a section from the strip. A long way jumps to one screen
  /// before it and glides the rest, so the grid never builds (and loads)
  /// every row in between.
  void _jumpTo(int index) {
    final layout = _layout;
    _selected.value = index;
    _revealInStrip(index);
    if (layout == null || index >= layout.offsets.length) return;
    if (_searchActive) {
      _closeSearch(restoreTo: layout.offsets[index]);
      return;
    }
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients) return;
    final position = scroll.position;
    final target = math.min(layout.offsets[index], position.maxScrollExtent);
    final distance = target - position.pixels;
    if (distance.abs() < .5) return;
    _jumpTarget = index;
    void release() {
      if (_jumpTarget == index) _jumpTarget = null;
    }

    if (NotionMotion.reduced(context)) {
      position.jumpTo(target);
      release();
      return;
    }
    final viewport = position.viewportDimension;
    if (distance.abs() > viewport * 2) {
      position.jumpTo(target - distance.sign * viewport);
    }
    unawaited(
      scroll
          .animateTo(
            target,
            duration: NotionMotion.medium,
            curve: NotionMotion.standard,
          )
          .whenComplete(release),
    );
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _idle.value = false;
    } else if (notification is ScrollEndNotification) {
      _idle.value = true;
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // Search.

  void _focusChanged() {
    final focused = _searchFocus.hasFocus;
    if (focused == _focused || !mounted) return;
    if (focused) {
      // Search starts at the top; closing it comes back here.
      _startSearch();
      setState(() => _focused = true);
    } else if (_searching) {
      // The keyboard went away: the results stay.
      setState(() => _focused = false);
    } else {
      _closeSearch();
    }
  }

  void _startSearch() {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients) return;
    _browseOffset ??= scroll.offset;
    if (scroll.offset == 0) return;
    // The browsing place stays remembered: this jump is the search's.
    _searchJump = true;
    scroll.jumpTo(0);
    _searchJump = false;
  }

  void _queryChanged() {
    final next = _query.text.trim();
    if (next == _activeQuery || !mounted) return;
    final before = _searching ? _resultsFor(_activeQuery) : null;
    if (next.isNotEmpty) _startSearch();
    setState(() => _activeQuery = next);
    if (next.isEmpty) {
      if (!_focused) _closeSearch();
      _playFade();
      return;
    }
    final after = _resultsFor(next);
    if (before == null ||
        !_same(before.stickers, after.stickers) ||
        !_same(before.packs, after.packs)) {
      _playFade();
    }
  }

  static bool _same<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _playFade() {
    if (NotionMotion.reduced(context)) return;
    final fade = _fade ??= AnimationController(
      vsync: this,
      duration: NotionMotion.short,
    );
    _fadeOpacity ??= fade.drive(
      Tween<double>(
        begin: NotionMotion.refreshFrom,
        end: 1,
      ).chain(CurveTween(curve: NotionMotion.standard)),
    );
    fade.forward(from: 0);
  }

  void _openSearch() {
    _startSearch();
    _searchFocus.requestFocus();
  }

  /// Leaves the search: the keyboard closes, the query clears and the grid
  /// comes back to where it was (or to [restoreTo], a strip tap).
  void _closeSearch({double? restoreTo}) {
    final restore = restoreTo ?? _browseOffset;
    _browseOffset = null;
    if (_searchFocus.hasFocus) _searchFocus.unfocus();
    if (!mounted) return;
    setState(() {
      _focused = false;
      _activeQuery = '';
      _restoreOffset = restore;
    });
    if (_query.text.isNotEmpty) _query.clear();
  }

  // ---------------------------------------------------------------------
  // Actions.

  Future<void> _send(StickerItem item) async {
    await StickerSender.send(context, widget.host, item);
  }

  Future<void> _sendFrom(StickerItem item, String cell) async {
    final sent = await StickerSender.send(context, widget.host, item);
    if (sent && mounted) _sent.value = (cell, ++_sentCount);
  }

  void _addPacks() =>
      unawaited(showAddStickerPacks(context, library: _library));

  void _preview(StickerItem item, {StickerSection? section}) {
    final room = widget.host.room;
    final plan = StickerSendPlan.forRoom(room, item);
    final favourite = _library.isFavourite(item);
    final pack = section?.pack ?? _library.packOf(item);
    final client = room.client;
    unawaited(
      showStickerPreview(
        context,
        item: item,
        client: client,
        note: plan.possible ? null : plan.reason,
        packTitle: pack?.title,
        actions: [
          StickerPreviewAction(
            icon: Icons.send_outlined,
            label: 'Send',
            onSelected: plan.possible ? () => unawaited(_send(item)) : null,
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
                onSend: (item) => unawaited(_send(item)),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Build.

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _build);

  Widget _build(BuildContext context, BoxConstraints constraints) {
    final sections = _currentSections();
    if (sections.isEmpty && !_searchActive) {
      // Installed packs whose content has not synced yet get a static
      // note (a sync can take long or never come: no endless shimmer).
      final syncing = _library.doc.packs.isNotEmpty;
      return SingleChildScrollView(
        child: NotionEmptyState(
          icon: Icons.sticky_note_2_outlined,
          title: syncing ? 'Sticker packs are syncing' : 'No sticker packs yet',
          message: syncing
              ? 'Your packs show up here as soon as they arrive.'
              : 'Add packs to send stickers here, or tap a sticker pack link in a chat.',
          action: NotionButton.primary(
            label: 'Add sticker packs',
            icon: Icons.add,
            onPressed: _addPacks,
          ),
        ),
      );
    }
    final width = constraints.maxWidth;
    final columns = StickerTab.columnsFor(width);
    final tile = width / columns;
    final scaler = MediaQuery.textScalerOf(context);
    final header =
        scaler.scale(NotionType.caption.fontSize! * 1.5) + NotionSpace.sm;
    final search = math.max(
      NotionSize.touchTarget,
      scaler.scale(NotionType.callout.fontSize! * 1.4) +
          NotionSpace.md +
          NotionSpace.xs,
    );
    final layout = _GridLayout(
      columns: columns,
      tile: tile,
      header: header,
      search: search,
      sections: sections,
    );
    final stripShown = !_searchActive;
    _applyLayout(
      layout,
      constraints.maxHeight - (stripShown ? _stripExtent : 0),
    );
    final back =
        _searchActive &&
        TickerMode.valuesOf(context).enabled &&
        Router.maybeOf(context)?.backButtonDispatcher != null;
    return Column(
      children: [
        NotionSizeReveal(
          visible: stripShown,
          duration: NotionMotion.short,
          child: _packStrip(sections),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: CustomScrollView(
              key: const ValueKey('sticker-grid'),
              controller: _scroll,
              // About two rows ahead: enough to never show an empty row,
              // few enough loads per fling.
              scrollCacheExtent: ScrollCacheExtent.pixels(tile * 2),
              slivers: [
                _searchHeader(search),
                if (_searching)
                  ..._resultSlivers(layout)
                else
                  for (final section in sections) _group(section, layout),
                const SliverPadding(
                  padding: EdgeInsets.only(bottom: _GridLayout.bottomPadding),
                ),
              ],
            ),
          ),
        ),
        // Back closes the search before the panel (Telegram).
        if (back)
          BackButtonListener(
            onBackButtonPressed: () async {
              _closeSearch();
              return true;
            },
            child: const SizedBox.shrink(),
          ),
      ],
    );
  }

  /// The opaque tone of the composer's glass, for chrome that content
  /// scrolls under (the search field, sticky titles).
  Color _chrome(BuildContext context) =>
      notionGlassOpaque(context, context.notion.glass.tint);

  Widget _searchHeader(double extent) {
    final field = KeyedSubtree(
      key: _searchKey,
      child: ColoredBox(
        color: _chrome(context),
        child: SizedBox(
          height: extent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: NotionSpace.xxs,
                    ),
                    child: TextField(
                      key: const ValueKey('sticker-search-field'),
                      controller: _query,
                      focusNode: _searchFocus,
                      expands: true,
                      maxLines: null,
                      textAlignVertical: TextAlignVertical.center,
                      textInputAction: TextInputAction.search,
                      // The keyboard goes, the results stay.
                      onSubmitted: (_) => _searchFocus.unfocus(),
                      style: context.notion.typography.callout,
                      decoration: const InputDecoration(
                        hintText: 'Search stickers',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: NotionSpace.sm,
                        ),
                        prefixIcon: Icon(Icons.search, size: NotionSize.icon),
                        prefixIconConstraints: BoxConstraints.tightFor(
                          width: NotionSize.touchTarget - NotionSpace.xs,
                        ),
                      ),
                    ),
                  ),
                ),
                NotionSizeReveal(
                  visible: _searchActive,
                  axis: Axis.horizontal,
                  duration: NotionMotion.short,
                  child: NotionIconButton(
                    icon: Icons.close,
                    label: 'Close search',
                    onPressed: _closeSearch,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Pinned while searching; otherwise it scrolls away with the grid and
    // floats back on any upward scroll (Telegram).
    if (_searchActive) return PinnedHeaderSliver(child: field);
    final reduced = NotionMotion.reduced(context);
    return SliverFloatingHeader(
      animationStyle: AnimationStyle(
        duration: reduced ? Duration.zero : NotionMotion.short,
        reverseDuration: reduced ? Duration.zero : NotionMotion.short,
        curve: NotionMotion.standard,
        reverseCurve: NotionMotion.standard,
      ),
      child: field,
    );
  }

  Widget _sectionTitle(String title, double extent) => ColoredBox(
    color: _chrome(context),
    child: SizedBox(
      height: extent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
        child: Align(
          alignment: AlignmentDirectional.bottomStart,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.notion.typography.captionMuted,
          ),
        ),
      ),
    ),
  );

  /// One section: its title sticks to the top while its rows pass.
  Widget _group(StickerSection section, _GridLayout layout) =>
      SliverMainAxisGroup(
        key: ValueKey('section-${section.key}'),
        slivers: [
          PinnedHeaderSliver(
            child: _sectionTitle(section.title, layout.header),
          ),
          _grid(section.key, section.items, layout, section: section),
        ],
      );

  Widget _grid(
    String group,
    List<StickerItem> items,
    _GridLayout layout, {
    StickerSection? section,
  }) {
    final client = widget.host.room.client;
    return SliverGrid.builder(
      key: ValueKey('grid-$group'),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: layout.columns,
        mainAxisExtent: layout.tile,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final cell = '$group/${item.key}';
        return StickerTile(
          key: ValueKey(cell),
          item: item,
          client: client,
          size: layout.tile,
          animate: _idle,
          sent: _sent,
          sentId: cell,
          onTap: () => unawaited(_sendFrom(item, cell)),
          onLongPress: () => _preview(item, section: section),
        );
      },
    );
  }

  List<Widget> _resultSlivers(_GridLayout layout) {
    final results = _resultsFor(_activeQuery);
    final Widget body;
    if (results.isEmpty) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: NotionEmptyState(
          icon: Icons.search_off,
          title: 'No stickers found',
          message: 'Try an emoji or another word, or add more packs.',
          action: NotionButton.ghost(
            label: 'Add sticker packs',
            icon: Icons.add,
            onPressed: _addPacks,
          ),
        ),
      );
    } else {
      body = SliverMainAxisGroup(
        slivers: [
          if (results.stickers.isNotEmpty)
            SliverMainAxisGroup(
              key: const ValueKey('results-stickers'),
              slivers: [
                PinnedHeaderSliver(
                  child: _sectionTitle('Stickers', layout.header),
                ),
                _grid('results', results.stickers, layout),
              ],
            ),
          for (final pack in results.packs)
            SliverMainAxisGroup(
              key: ValueKey('results-pack-${pack.key}'),
              slivers: [
                PinnedHeaderSliver(
                  child: _sectionTitle(pack.title, layout.header),
                ),
                _grid('results-${pack.key}', pack.stickers, layout),
              ],
            ),
        ],
      );
    }
    final opacity = _fadeOpacity;
    return [
      if (opacity == null)
        body
      else
        SliverFadeTransition(opacity: opacity, sliver: body),
    ];
  }

  /// The search button stays at the start; the packs scroll, "add" ends
  /// them.
  Widget _packStrip(List<StickerSection> sections) {
    final client = widget.host.room.client;
    final colors = context.notion.colors;
    return SizedBox(
      height: _stripExtent,
      child: Row(
        children: [
          NotionIconButton(
            icon: Icons.search,
            label: 'Search stickers',
            onPressed: _openSearch,
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _selected,
              builder: (context, selected, _) => ListView.builder(
                key: const ValueKey('sticker-pack-strip'),
                controller: _strip,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: NotionSpace.xxs,
                ),
                itemExtent: _stripExtent,
                itemCount: sections.length + 1,
                itemBuilder: (context, i) {
                  if (i == sections.length) {
                    return NotionIconButton(
                      icon: Icons.add,
                      label: 'Add sticker packs',
                      onPressed: _addPacks,
                    );
                  }
                  final index = i;
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
                          duration: NotionMotion.of(
                            context,
                            NotionMotion.quick,
                          ),
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
                                  color: active
                                      ? colors.text
                                      : colors.textSecondary,
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
            ),
          ),
        ],
      ),
    );
  }
}

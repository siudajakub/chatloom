// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'own_sticker_pack_page.dart';
import 'room_sticker_packs.dart';
import 'sticker_catalog.dart';
import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_pack_import.dart';
import 'sticker_pack_sheet.dart';
import 'sticker_tile.dart' show stickerCacheName;
import 'telegram_pack_import_page.dart';

/// "Add stickers": the one place packs come from. Search and browse
/// Telegram's catalogue (through the Telegram bridge fork, feature-detected),
/// paste a pack link (Telegram, WhatsApp, a Matrix pack room), add packs of
/// rooms the account is in, the user's own Telegram packs and a pack made
/// from the user's images. Every pack opens the pack sheet with Add/Remove;
/// added packs show in the composer panel at once (the library notifies).
Future<void> showAddStickerPacks(
  BuildContext context, {
  StickerLibrary? library,
}) {
  final client = Matrix.of(context).client;
  return showNotionSheet<void>(
    context: context,
    title: 'Add stickers',
    builder: (_) => AddStickerPacksSheet(
      client: client,
      library: library,
      // Pages open from the caller's router (the sheet closes first).
      router: GoRouter.maybeOf(context),
    ),
  );
}

class AddStickerPacksSheet extends StatefulWidget {
  const AddStickerPacksSheet({
    super.key,
    required this.client,
    this.library,
    this.catalog,
    this.provisioning,
    this.roomLoader,
    this.router,
    this.searchDelay = const Duration(milliseconds: 400),
  });

  final Client client;
  final StickerLibrary? library;
  final TelegramStickerCatalog? catalog;
  final StickerPackProvisioning? provisioning;
  final RoomPackLoader? roomLoader;
  final GoRouter? router;

  /// Typing pause before a search is sent.
  final Duration searchDelay;

  @override
  State<AddStickerPacksSheet> createState() => _AddStickerPacksSheetState();
}

const _pasteHint =
    'Paste a t.me/addstickers, wa.me/stickerpack or matrix.to link above to '
    'open a pack.';

class _AddStickerPacksSheetState extends State<AddStickerPacksSheet> {
  late final StickerLibrary _library =
      widget.library ?? StickerLibrary.of(widget.client);
  late final TelegramStickerCatalog _catalog =
      widget.catalog ?? TelegramStickerCatalog.of(widget.client);
  late final StickerPackProvisioning _provisioning =
      widget.provisioning ?? StickerPackProvisioning.of(widget.client);
  late final RoomPackLoader _rooms =
      widget.roomLoader ?? RoomPackLoader.of(widget.client);
  final _controller = TextEditingController();
  Timer? _debounce;

  /// Bumped by every new query: answers of an older one are dropped.
  int _generation = 0;

  String _query = '';
  CatalogPage? _results;
  String? _searchError;
  bool _searching = false;

  final _featured = <CatalogStickerSet>[];
  int? _featuredNext;
  bool _featuredLoading = false;
  bool _featuredLoaded = false;
  String? _featuredError;

  StickerPackLink? _packLink;
  RoomPackLink? _roomLink;
  RoomPackPreview? _roomPreview;
  bool _roomLoading = false;
  String? _roomError;

  final _adding = <String>{};
  final _addErrors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _library.addListener(_changed);
    _catalog.prepare();
    if (_catalog.availability.usable) {
      _featuredLoading = true;
      unawaited(_fetchFeatured());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _library.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Input: a link opens its pack, other text searches the catalogue.

  void _onChanged(String text) {
    _debounce?.cancel();
    final packLink = StickerPackLink.parse(text);
    final roomLink = packLink == null ? RoomPackLink.parse(text) : null;
    final query = packLink != null || roomLink != null ? '' : text.trim();
    final generation = ++_generation;
    setState(() {
      _packLink = packLink;
      if (roomLink != _roomLink) {
        _roomLink = roomLink;
        _roomPreview = null;
        _roomError = null;
        _roomLoading = false;
      }
      if (query != _query) {
        _query = query;
        _results = null;
        _searchError = null;
        _searching = query.isNotEmpty && _catalog.availability.usable;
      }
    });
    if (roomLink != null && _roomPreview == null && !_roomLoading) {
      unawaited(_loadRoom(roomLink));
    }
    if (query.isEmpty || !_catalog.availability.usable) return;
    _debounce = Timer(widget.searchDelay, () => _search(query, generation));
  }

  /// Return opens a pasted link, or sends a search that is still waiting
  /// for the typing pause.
  void _submit(String text) {
    final pending = _debounce?.isActive ?? false;
    _debounce?.cancel();
    final link = _packLink;
    if (link != null) {
      _openLink(link);
      return;
    }
    if (pending && _query.isNotEmpty) unawaited(_search(_query, _generation));
  }

  Future<void> _search(String query, int generation) async {
    if (!mounted) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final page = await _catalog.search(query);
      if (!mounted || generation != _generation) return;
      setState(() => _results = page);
    } on StickerCatalogException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _searchError = e.message);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
      }
    }
  }

  void _clear() {
    _controller.clear();
    _onChanged('');
  }

  Future<void> _loadFeatured() async {
    if (_featuredLoading) return;
    setState(() {
      _featuredLoading = true;
      _featuredError = null;
    });
    await _fetchFeatured();
  }

  Future<void> _fetchFeatured() async {
    try {
      final page = await _catalog.featured(offset: _featuredNext ?? 0);
      if (!mounted) return;
      final known = {for (final s in _featured) s.link};
      setState(() {
        _featured.addAll(page.sets.where((s) => !known.contains(s.link)));
        _featuredNext = page.nextOffset;
        _featuredLoaded = true;
      });
    } on StickerCatalogException catch (e) {
      if (mounted) setState(() => _featuredError = e.message);
    } finally {
      if (mounted) setState(() => _featuredLoading = false);
    }
  }

  Future<void> _loadRoom(RoomPackLink link) async {
    setState(() {
      _roomLoading = true;
      _roomError = null;
    });
    try {
      final preview = await _rooms.preview(link);
      if (!mounted || link != _roomLink) return;
      setState(() => _roomPreview = preview);
    } on StickerImportException catch (e) {
      if (mounted && link == _roomLink) setState(() => _roomError = e.message);
    } finally {
      if (mounted && link == _roomLink) setState(() => _roomLoading = false);
    }
  }

  /// Joins the pack room when the user asked to see its stickers.
  Future<void> _joinRoom(RoomPackLink link) async {
    setState(() {
      _roomLoading = true;
      _roomError = null;
    });
    try {
      final preview = await _rooms.join(link);
      if (!mounted || link != _roomLink) return;
      setState(() => _roomPreview = preview);
    } on StickerImportException catch (e) {
      if (mounted && link == _roomLink) setState(() => _roomError = e.message);
    } finally {
      if (mounted && link == _roomLink) setState(() => _roomLoading = false);
    }
  }

  // ---------------------------------------------------------------------
  // Adding.

  void _openLink(StickerPackLink link) => showStickerPackSheet(
    context,
    client: widget.client,
    link: link,
    provisioning: _provisioning,
    library: _library,
  );

  /// Imports a network pack; idempotent (the provisioning skips a pack the
  /// library has and joins a running import of the same link).
  Future<void> _addNetworkPack(StickerPackLink link, String title) async {
    final key = link.url;
    if (_adding.contains(key) || _library.isInstalled(link.url)) return;
    setState(() {
      _adding.add(key);
      _addErrors.remove(key);
    });
    try {
      await _provisioning.install(link, title: title, library: _library);
    } on StickerImportException catch (e) {
      if (mounted) setState(() => _addErrors[key] = e.message);
    } finally {
      if (mounted) setState(() => _adding.remove(key));
    }
  }

  Future<void> _addRoomPack(
    RoomPackPreview preview,
    StickerPack pack, {
    RoomPackLink? link,
  }) async {
    final key = pack.key;
    if (_adding.contains(key)) return;
    setState(() {
      _adding.add(key);
      _addErrors.remove(key);
    });
    try {
      await _rooms.add(preview, pack, library: _library, link: link);
    } on StickerImportException catch (e) {
      if (mounted) setState(() => _addErrors[key] = e.message);
    } finally {
      if (mounted) setState(() => _adding.remove(key));
    }
  }

  void _openRoomPack(
    RoomPackPreview preview,
    StickerPack pack, {
    RoomPackLink? link,
  }) => showStickerPackSheet(
    context,
    client: widget.client,
    pack: pack,
    library: _library,
    onAdd: () => _rooms.add(preview, pack, library: _library, link: link),
    addNote: preview.joined
        ? null
        : 'Adding joins this room, so its members can see you.',
  );

  void _push(String path) {
    final router = widget.router ?? GoRouter.maybeOf(context);
    Navigator.of(context).pop();
    router?.push(path);
  }

  // ---------------------------------------------------------------------
  // UI.

  bool _installed(StickerPackLink link) => _library.isInstalled(link.url);

  Widget _addTrailing(
    String key, {
    required bool installed,
    VoidCallback? onAdd,
  }) {
    if (installed) {
      return Icon(
        Icons.check,
        semanticLabel: 'Added',
        color: context.notion.colors.textSecondary,
      );
    }
    final busy = _adding.contains(key);
    return NotionButton(
      label: _addErrors.containsKey(key) ? 'Retry' : 'Add',
      busy: busy,
      onPressed: busy ? null : onAdd,
    );
  }

  Widget _setRow(CatalogStickerSet set) {
    final installed = _installed(set.link);
    final error = _addErrors[set.link.url];
    return NotionListRow(
      key: ValueKey('set-${set.link.url}'),
      leading: _CatalogCover(
        catalog: _catalog,
        set: set,
        client: widget.client,
      ),
      title: set.title,
      subtitle:
          error ??
          [
            set.count == 1 ? '1 sticker' : '${set.count} stickers',
            if (set.emoji) 'Custom emoji',
            if (installed) 'In your stickers',
          ].join(' · '),
      onTap: () => _openLink(set.link),
      trailing: _addTrailing(
        set.link.url,
        installed: installed,
        onAdd: () => _addNetworkPack(set.link, set.title),
      ),
    );
  }

  Widget _roomPackRow(
    RoomPackPreview preview,
    StickerPack pack, {
    RoomPackLink? link,
    String? subtitle,
  }) {
    final installed =
        _library.packByKey(pack.key)?.source == StickerPackSource.installed;
    final count = pack.stickers.length == 1
        ? '1 sticker'
        : '${pack.stickers.length} stickers';
    return NotionListRow(
      key: ValueKey('room-${pack.key}'),
      leading: _PackIcon(uri: pack.icon, client: widget.client),
      title: pack.title,
      subtitle:
          _addErrors[pack.key] ??
          [count, ?subtitle, if (installed) 'In your stickers'].join(' · '),
      onTap: () => _openRoomPack(preview, pack, link: link),
      trailing: _addTrailing(
        pack.key,
        installed: installed,
        onAdd: () => _addRoomPack(preview, pack, link: link),
      ),
    );
  }

  Widget _skeleton([int rows = 4]) => NotionSkeleton(
    enabled: true,
    child: Column(
      children: [for (var i = 0; i < rows; i++) const NotionSkeletonRow()],
    ),
  );

  List<Widget> _linkBody() {
    final link = _packLink!;
    return [
      NotionListRow(
        key: const ValueKey('open-pack-link'),
        leading: const Icon(Icons.collections_outlined),
        title: _library.packByUrl(link.url)?.title ?? link.name,
        subtitle: [
          '${link.networkLabel} sticker pack',
          if (_installed(link)) 'In your stickers',
        ].join(' · '),
        onTap: () => _openLink(link),
        trailing: const Icon(Icons.chevron_right),
      ),
    ];
  }

  List<Widget> _roomBody() {
    final link = _roomLink!;
    final preview = _roomPreview;
    final error = _roomError;
    if (error != null) {
      return [
        NotionCallout(
          icon: Icons.error_outline,
          tone: NotionCalloutTone.warning,
          title: error,
          actionLabel: 'Try again',
          onAction: () => _loadRoom(link),
        ),
      ];
    }
    if (preview == null) return [_skeleton(2)];
    final packs = preview.stickerPacks;
    if (packs.isEmpty && !preview.joined) {
      return [
        NotionCallout(
          key: const ValueKey('room-join'),
          icon: Icons.meeting_room_outlined,
          title: 'This room’s packs show once you join it',
          message: 'Its members can see that you joined.',
          actionLabel: 'Join room',
          actionBusy: _roomLoading,
          onAction: _roomLoading ? null : () => _joinRoom(link),
        ),
      ];
    }
    if (packs.isEmpty) {
      return [
        const NotionEmptyState(
          icon: Icons.sticky_note_2_outlined,
          title: 'No sticker packs in this room',
          message: 'The room has no image packs with stickers.',
        ),
      ];
    }
    return [
      NotionSectionHeader(title: preview.roomName ?? 'Packs in this room'),
      for (final pack in packs) _roomPackRow(preview, pack, link: link),
    ];
  }

  List<Widget> _searchBody() {
    final available = _catalog.availability;
    if (!available.usable) {
      return [
        _availabilityCallout(available),
        const SizedBox(height: NotionSpace.sm),
        Text(
          'You can still paste a t.me/addstickers, wa.me/stickerpack or '
          'matrix.to pack link.',
          style: context.notion.typography.footnoteMuted,
        ),
      ];
    }
    final error = _searchError;
    if (error != null) {
      return [
        NotionCallout(
          icon: Icons.error_outline,
          tone: NotionCalloutTone.warning,
          title: error,
          actionLabel: 'Try again',
          onAction: () => _search(_query, _generation),
        ),
      ];
    }
    final results = _results;
    if (results == null) return [_skeleton(5)];
    if (results.sets.isEmpty) {
      return [
        const NotionEmptyState(
          icon: Icons.search_off,
          title: 'No packs found',
          message: 'Try another word, or paste a pack link.',
        ),
      ];
    }
    return [
      NotionSectionHeader(
        title: results.sets.length == 1
            ? '1 pack on Telegram'
            : '${results.sets.length} packs on Telegram',
      ),
      for (final set in results.sets) _setRow(set),
    ];
  }

  Widget _availabilityCallout(CatalogAvailability available) => NotionCallout(
    key: ValueKey('catalog-${available.status.name}'),
    icon: available.status == CatalogStatus.needsBridgeUpdate
        ? Icons.update
        : Icons.info_outline,
    title: available.message ?? '',
  );

  List<Widget> _browseBody() {
    final notion = context.notion;
    final available = _catalog.availability;
    final roomPacks = packsInJoinedRooms(widget.client, _library);
    return [
      if (!available.usable && available.status != CatalogStatus.noBridge)
        _availabilityCallout(available)
      else if (available.usable) ...[
        const NotionSectionHeader(title: 'Trending on Telegram'),
        if (_featuredError != null && _featured.isEmpty)
          NotionCallout(
            icon: Icons.error_outline,
            tone: NotionCalloutTone.warning,
            title: _featuredError!,
            actionLabel: 'Try again',
            onAction: _loadFeatured,
          )
        else if (!_featuredLoaded)
          _skeleton(3)
        else if (_featured.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
            child: Text(
              'Nothing trending right now.',
              style: notion.typography.footnoteMuted,
            ),
          )
        else ...[
          for (final set in _featured) _setRow(set),
          if (_featuredNext != null || _featuredError != null)
            Padding(
              padding: const EdgeInsets.only(top: NotionSpace.xs),
              child: NotionButton.ghost(
                key: const ValueKey('featured-more'),
                label: _featuredError != null ? 'Try again' : 'Show more',
                expand: true,
                busy: _featuredLoading,
                onPressed: _featuredLoading ? null : _loadFeatured,
              ),
            ),
        ],
      ],
      if (roomPacks.isNotEmpty) ...[
        const NotionSectionHeader(title: 'Packs in your rooms'),
        for (final (ref, pack, content) in roomPacks)
          _roomPackRow(
            RoomPackPreview(
              roomId: ref.roomId,
              roomName: widget.client
                  .getRoomById(ref.roomId)
                  ?.getLocalizedDisplayname(),
              packs: {ref.stateKey: content},
              joined: true,
            ),
            pack,
            subtitle: widget.client
                .getRoomById(ref.roomId)
                ?.getLocalizedDisplayname(),
          ),
      ],
      const NotionSectionHeader(title: 'More ways to add'),
      NotionListRow(
        key: const ValueKey('add-telegram-packs'),
        leading: const Icon(Icons.download_outlined),
        title: 'Your Telegram packs',
        subtitle: 'Packs installed in your Telegram account',
        onTap: () => _push(telegramPackImportPath),
      ),
      NotionListRow(
        key: const ValueKey('add-own-pack'),
        leading: const Icon(Icons.add_photo_alternate_outlined),
        title: 'Create a pack from images',
        subtitle: 'PNG, WebP or GIF images from your device',
        onTap: () => _push(ownStickerPackPath),
      ),
      Padding(
        padding: const EdgeInsets.only(top: NotionSpace.md),
        child: Text(
          [
            _pasteHint,
            if (available.usable)
              'Searches go to Telegram from your Telegram account.',
          ].join(' '),
          style: notion.typography.footnoteMuted,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final height = math.min(
      MediaQuery.sizeOf(context).height * .78,
      NotionSize.sheetDialogMaxHeight,
    );
    final available = _catalog.availability;
    final String mode;
    final List<Widget> body;
    if (_packLink != null) {
      mode = 'link';
      body = _linkBody();
    } else if (_roomLink != null) {
      mode = 'room';
      body = _roomBody();
    } else if (_query.isNotEmpty) {
      mode = 'search';
      body = _searchBody();
    } else {
      mode = 'browse';
      body = _browseBody();
    }
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NotionTextField(
            key: const ValueKey('add-stickers-field'),
            controller: _controller,
            hint: available.usable
                ? 'Search Telegram packs or paste a link'
                : 'Paste a sticker pack link',
            prefixIcon: available.usable ? Icons.search : Icons.link,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            onChanged: _onChanged,
            onSubmitted: _submit,
            suffix: _controller.text.isEmpty
                ? null
                : NotionIconButton(
                    icon: Icons.close,
                    label: 'Clear',
                    onPressed: _clear,
                  ),
          ),
          if (_searching && _results != null)
            const Padding(
              padding: EdgeInsets.only(top: NotionSpace.xs),
              child: Center(child: NotionDelayedSpinner()),
            ),
          const SizedBox(height: NotionSpace.xs),
          Expanded(
            child: NotionFadeThrough(
              child: ListView(
                key: ValueKey(mode),
                padding: const EdgeInsets.only(bottom: NotionSpace.lg),
                children: body,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A catalogue set's cover, loaded through the bridge once it is built
/// (rows built by scrolling ask for theirs; a few at a time).
class _CatalogCover extends StatefulWidget {
  const _CatalogCover({
    required this.catalog,
    required this.set,
    required this.client,
  });

  final TelegramStickerCatalog catalog;
  final CatalogStickerSet set;
  final Client client;

  @override
  State<_CatalogCover> createState() => _CatalogCoverState();
}

class _CatalogCoverState extends State<_CatalogCover> {
  late Future<Uri?> _cover = widget.catalog.cover(widget.set);

  @override
  void didUpdateWidget(_CatalogCover old) {
    super.didUpdateWidget(old);
    if (old.set != widget.set) _cover = widget.catalog.cover(widget.set);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uri?>(
    future: _cover,
    builder: (context, snapshot) =>
        _PackIcon(uri: snapshot.data, client: widget.client),
  );
}

class _PackIcon extends StatelessWidget {
  const _PackIcon({required this.uri, required this.client});
  final Uri? uri;
  final Client client;

  @override
  Widget build(BuildContext context) {
    final placeholder = Icon(
      Icons.sticky_note_2_outlined,
      color: context.notion.colors.textTertiary,
    );
    final uri = this.uri;
    return SizedBox.square(
      dimension: NotionSize.iconLg,
      child: uri == null
          ? placeholder
          : TickerMode(
              enabled: false,
              child: MxcImage(
                uri: uri,
                client: client,
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
            ),
    );
  }
}

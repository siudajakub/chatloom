// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'sticker_models.dart';
import 'sticker_search.dart';
import 'sticker_store.dart';

/// Where the library reads and writes. Production uses
/// [MatrixStickerBackend]; tests use a fake.
abstract interface class StickerLibraryBackend {
  /// Content of a synced account data event, or null.
  Map<String, Object?>? readSynced(String type);
  Future<void> writeSynced(String type, Map<String, Object?> content);

  /// Content of a device-only event (encrypted database), or null.
  Map<String, Object?>? readLocal(String type);
  Future<void> writeLocal(String type, Map<String, Object?> content);

  /// Fires when synced library data or any pack state changed.
  Stream<void> get changes;

  /// The packs a room holds (stable and unstable, split packs joined), by
  /// state key, or null when the room is unknown or not joined.
  Map<String, ImagePackContent>? packsOfRoom(String roomId);

  /// Name of a room for a pack without a title.
  String? roomName(String roomId);

  /// Packs enabled by other Matrix clients (`m.image_pack.rooms` and its
  /// unstable name), as (room, state key) in their order.
  List<(String, String)> enabledElsewhere();

  /// The account's own pack (`m.image_pack` / `im.ponies.user_emotes`).
  ImagePackContent? userPack();
}

/// The account's stickers and GIFs (Telegram's sticker library):
/// installed packs in the user's order, recent and favourite stickers,
/// saved and recent GIFs.
///
/// Every change is optimistic: it shows at once and is stored in the
/// background (debounced like Telegram's pack reorder). Changes stay
/// pending until stored and are re-applied on top of every newer version
/// that arrives by sync, so two devices merge instead of overwriting each
/// other. The pack index (stickers per pack, emoji and keyword search) is
/// rebuilt only when the library or pack state changes, never per build.
class StickerLibrary extends ChangeNotifier {
  StickerLibrary(
    this.backend, {
    this.debounce = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _changes = backend.changes.listen((_) {
      // A newer synced version of a type replaces what this device wrote.
      _written.removeWhere(
        (type, written) => !identical(backend.readSynced(type), written.$1),
      );
      _invalidate();
    });
  }

  static final _instances = Expando<(String?, StickerLibrary)>(
    'sticker library',
  );

  /// The library of [client]'s signed-in account (a new one after the
  /// client signs in as someone else).
  static StickerLibrary of(Client client) {
    final cached = _instances[client];
    if (cached != null && cached.$1 == client.userID) return cached.$2;
    cached?.$2._retire();
    final library = StickerLibrary(MatrixStickerBackend(client));
    _instances[client] = (client.userID, library);
    return library;
  }

  /// Replaces the library of [client] (tests).
  @visibleForTesting
  static void debugSet(Client client, StickerLibrary library) =>
      _instances[client] = (client.userID, library);

  final StickerLibraryBackend backend;

  /// Null writes at once (tests).
  final Duration? debounce;
  final DateTime Function() _clock;
  late final StreamSubscription<void> _changes;
  final _pending = <StickerLibraryOp>[];
  Timer? _flushTimer;
  Future<void>? _flushing;
  bool _disposed = false;

  StickerLibraryDoc? _doc;

  /// What this device stored per type (with the synced version it
  /// replaced), shown until the sync echo or another newer version arrives.
  final _written =
      <String, (Map<String, Object?>?, Map<String, Object?>)>{};

  Map<String, Object?>? _synced(String type) =>
      _written[type]?.$2 ?? backend.readSynced(type);
  List<StickerPack>? _packs;
  StickerSearchIndex? _index;
  _PackCache? _cache;

  /// Bumped on every change (memo key for widgets).
  int revision = 0;

  int get _now => _clock().millisecondsSinceEpoch;

  /// Synced and local state with the pending changes applied.
  StickerLibraryDoc get doc => _doc ??= _pending.fold<StickerLibraryDoc>(
    StickerLibraryDoc.fromJson(
      stickers: _synced(stickerLibraryType),
      gifs: _synced(gifLibraryType),
      local: backend.readLocal(stickerLocalType),
    ),
    (doc, op) => op.apply(doc),
  );

  List<StickerItem> list(StickerList list) => doc.list(list);

  List<StickerItem> get recentStickers => doc
      .list(StickerList.recentStickers)
      .take(StickerList.recentStickers.shown)
      .toList();
  List<StickerItem> get favourites => doc.list(StickerList.favouriteStickers);
  List<StickerItem> get savedGifs => doc.list(StickerList.savedGifs);
  List<StickerItem> get recentGifs => doc
      .list(StickerList.recentGifs)
      .take(StickerList.recentGifs.shown)
      .toList();

  bool isFavourite(StickerItem item) =>
      favourites.any((f) => f.key == item.key);
  bool isSavedGif(StickerItem item) => savedGifs.any((g) => g.key == item.key);
  bool isRecent(StickerItem item) =>
      doc.list(StickerList.recentStickers).any((r) => r.key == item.key);

  _PackCache get _packCache =>
      _cache ??= _PackCache.fromJson(backend.readLocal(stickerPackCacheType));

  /// Installed packs (the library's order), then packs enabled by other
  /// clients and the account's own pack. Packs whose state is unavailable
  /// fall back to the cached content of their import; packs with neither
  /// are left out until their state syncs.
  List<StickerPack> get packs => _packs ??= _resolvePacks();

  List<StickerPack> _resolvePacks() {
    final out = <StickerPack>[];
    final seen = <String>{};
    final roomPacks = <String, Map<String, ImagePackContent>?>{};
    Map<String, ImagePackContent>? statesOf(String roomId) =>
        roomPacks.putIfAbsent(roomId, () => backend.packsOfRoom(roomId));
    for (final ref in doc.packs) {
      if (!seen.add(ref.key)) continue;
      final content =
          statesOf(ref.roomId)?[ref.stateKey] ?? _packCache.content(ref.key);
      if (content == null) continue;
      final pack = StickerPack.fromContent(
        content,
        key: ref.key,
        source: StickerPackSource.installed,
        fallbackTitle: backend.roomName(ref.roomId),
        ref: ref,
      );
      if (pack.stickers.isNotEmpty) out.add(pack);
    }
    final hidden = doc.hidden.toSet();
    for (final (roomId, stateKey) in backend.enabledElsewhere()) {
      final key = StickerPackRef.packKeyOf(roomId, stateKey);
      if (hidden.contains(key) || !seen.add(key)) continue;
      final content = statesOf(roomId)?[stateKey];
      if (content == null) continue;
      final pack = StickerPack.fromContent(
        content,
        key: key,
        source: StickerPackSource.enabledElsewhere,
        fallbackTitle: backend.roomName(roomId),
      );
      if (pack.stickers.isNotEmpty) out.add(pack);
    }
    final user = backend.userPack();
    if (user != null && !hidden.contains(_userPackKey)) {
      final pack = StickerPack.fromContent(
        user,
        key: _userPackKey,
        source: StickerPackSource.user,
        fallbackTitle: 'Your stickers',
      );
      if (pack.stickers.isNotEmpty) out.add(pack);
    }
    return List.unmodifiable(out);
  }

  static const _userPackKey = 'user|';

  StickerPack? packByKey(String key) =>
      packs.where((p) => p.key == key).firstOrNull;

  /// The installed pack a network pack link (`t.me/addstickers/…`) points
  /// at, or null.
  StickerPack? packByUrl(String packUrl) {
    final wanted = _normalizePackUrl(packUrl);
    return packs
        .where(
          (p) => p.packUrl != null && _normalizePackUrl(p.packUrl!) == wanted,
        )
        .firstOrNull;
  }

  bool isInstalled(String packUrl) {
    final wanted = _normalizePackUrl(packUrl);
    return doc.packs.any(
          (r) => r.packUrl != null && _normalizePackUrl(r.packUrl!) == wanted,
        ) ||
        packByUrl(packUrl) != null;
  }

  static String _normalizePackUrl(String url) =>
      url.trim().toLowerCase().replaceFirst(RegExp(r'^https?://'), '');

  /// The pack of a library item (to open "View pack").
  StickerPack? packOf(StickerItem item) {
    final key = item.packKey;
    if (key != null) {
      final pack = packByKey(key);
      if (pack != null) return pack;
    }
    for (final pack in packs) {
      if (pack.stickers.any((s) => s.key == item.key)) return pack;
    }
    final url = item.bridged?.packUrl;
    return url == null ? null : packByUrl(url);
  }

  StickerSearchIndex get searchIndex =>
      _index ??= StickerSearchIndex([
        ...favourites,
        ...doc.list(StickerList.recentStickers),
        for (final pack in packs) ...pack.stickers,
      ], packs: packs);

  /// Telegram's sticker search: stickers for an emoji, for a word (through
  /// the emoji keywords of [locale]), by shortcode and by pack title.
  List<StickerItem> search(String query, {String? languageCode}) =>
      searchIndex.search(query, languageCode: languageCode);

  // ---------------------------------------------------------------------
  // Changes (optimistic).

  /// A sticker was sent: it becomes the newest recent.
  void useSticker(StickerItem item) =>
      _apply(UseItemOp(StickerList.recentStickers, item.copyWith(ts: _now)));

  /// A GIF was sent from the panel.
  void useGif(StickerItem item) =>
      _apply(UseItemOp(StickerList.recentGifs, item.copyWith(ts: _now)));

  void addFavourite(StickerItem item) => _apply(
    AddItemOp(StickerList.favouriteStickers, item.copyWith(ts: _now)),
  );

  void removeFavourite(StickerItem item) =>
      _apply(RemoveItemOp(StickerList.favouriteStickers, item.key));

  /// Returns whether it is a favourite now.
  bool toggleFavourite(StickerItem item) {
    if (isFavourite(item)) {
      removeFavourite(item);
      return false;
    }
    addFavourite(item);
    return true;
  }

  void removeRecent(StickerItem item) =>
      _apply(RemoveItemOp(StickerList.recentStickers, item.key));

  void clearRecentStickers() =>
      _apply(const ClearListOp(StickerList.recentStickers));

  void saveGif(StickerItem item) =>
      _apply(AddItemOp(StickerList.savedGifs, item.copyWith(ts: _now)));

  void removeSavedGif(StickerItem item) =>
      _apply(RemoveItemOp(StickerList.savedGifs, item.key));

  void removeRecentGif(StickerItem item) =>
      _apply(RemoveItemOp(StickerList.recentGifs, item.key));

  /// Undo of a removal: puts [item] back with its old position (its ts).
  void restore(StickerList list, StickerItem item) =>
      _apply(AddItemOp(list, item));

  /// Installs a pack. [content] (the import preview) is cached so the pack
  /// is usable before its room state syncs.
  void addPack(StickerPackRef ref, {ImagePackContent? content}) {
    if (content != null) {
      _packCache.put(ref.key, content, _now);
      unawaited(_writeCache());
    }
    _apply(
      AddPackOp(ref.addedTs == 0 ? _withAdded(ref) : ref),
    );
  }

  StickerPackRef _withAdded(StickerPackRef ref) => StickerPackRef(
    roomId: ref.roomId,
    stateKey: ref.stateKey,
    packUrl: ref.packUrl,
    network: ref.network,
    title: ref.title,
    addedTs: _now,
  );

  /// Removes a pack from ChatLoom; a pack enabled by another client is
  /// hidden instead.
  void removePack(StickerPack pack) =>
      _apply(RemovePackOp(pack.key, hide: pack.ref == null));

  /// Puts a removed pack back (Undo).
  void restorePack(StickerPack pack, {int? index}) {
    final ref = pack.ref;
    if (ref == null) {
      _apply(UnhidePackOp(pack.key));
      return;
    }
    _apply(AddPackOp(ref));
    if (index != null) {
      final keys = [
        for (final r in doc.packs)
          if (r.key != ref.key) r.key,
      ];
      keys.insert(index.clamp(0, keys.length), ref.key);
      _apply(OrderPacksOp(keys));
    }
  }

  /// The user's order of installed packs (by key).
  void reorderPacks(List<String> keys) => _apply(OrderPacksOp(keys));

  void _apply(StickerLibraryOp op) {
    if (_disposed) return;
    _pending.add(op);
    _invalidate(
      packs:
          op is AddPackOp ||
          op is RemovePackOp ||
          op is OrderPacksOp ||
          op is UnhidePackOp,
    );
    _scheduleFlush();
  }

  void _invalidate({bool packs = true}) {
    if (_disposed) return;
    _doc = null;
    if (packs) _packs = null;
    _index = null;
    revision++;
    notifyListeners();
  }

  void _scheduleFlush() {
    final delay = debounce;
    _flushTimer?.cancel();
    if (delay == null) {
      unawaited(flush());
      return;
    }
    _flushTimer = Timer(delay, () => unawaited(flush()));
  }

  /// Stores the pending changes: each on top of the newest known version.
  /// A failed write keeps them pending for the next change or sync.
  Future<void> flush() async {
    _flushTimer?.cancel();
    final running = _flushing;
    if (running != null) {
      await running;
      if (_pending.isNotEmpty && !_disposed) await flush();
      return;
    }
    final done = _flushing = _flushRounds();
    try {
      await done;
    } finally {
      _flushing = null;
    }
  }

  /// A write that raced with a synced change is stored again on top of the
  /// newer version (a no-op when the change was its own echo).
  Future<void> _flushRounds() async {
    for (var round = 0; round < 3; round++) {
      if (!await _flush()) return;
    }
  }

  /// Returns true when it must run again (a synced change arrived while
  /// writing).
  Future<bool> _flush() async {
    if (_pending.isEmpty) return false;
    final ops = List<StickerLibraryOp>.of(_pending);
    final synced = {
      for (final type in const [stickerLibraryType, gifLibraryType])
        type: backend.readSynced(type),
    };
    final base = StickerLibraryDoc.fromJson(
      stickers: _synced(stickerLibraryType),
      gifs: _synced(gifLibraryType),
      local: backend.readLocal(stickerLocalType),
    );
    final next = ops.fold(base, (doc, op) => op.apply(doc));
    final stickers = next.stickersJson();
    final gifs = next.gifsJson();
    final local = next.localJson();
    final written = <String, Map<String, Object?>>{};
    try {
      if (!_same(stickers, base.stickersJson())) {
        await backend.writeSynced(stickerLibraryType, stickers);
        written[stickerLibraryType] = stickers;
      }
      if (!_same(gifs, base.gifsJson())) {
        await backend.writeSynced(gifLibraryType, gifs);
        written[gifLibraryType] = gifs;
      }
      if (!_same(local, base.localJson())) {
        await backend.writeLocal(stickerLocalType, local);
      }
    } catch (e, s) {
      // Offline or rejected: stays pending (and visible); retried later.
      Logs().d('Sticker library not stored yet', e, s);
      return false;
    }
    if (_disposed) return false;
    final stale = written.keys.any(
      (type) => !identical(backend.readSynced(type), synced[type]),
    );
    if (stale) {
      // Something synced while this was stored: it may be another device's
      // edit this write did not include. Keep the changes and store them
      // again on top of the newer version (a no-op if it was the echo).
      _invalidate(packs: false);
      return true;
    }
    for (final entry in written.entries) {
      _written[entry.key] = (synced[entry.key], entry.value);
    }
    _pending.removeRange(0, ops.length.clamp(0, _pending.length));
    _invalidate(packs: false);
    return false;
  }

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  Future<void> _writeCache() async {
    try {
      await backend.writeLocal(stickerPackCacheType, _packCache.toJson());
    } catch (e, s) {
      Logs().d('Sticker pack cache not stored', e, s);
    }
  }

  @visibleForTesting
  int get pendingCount => _pending.length;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  /// Stops listening and storing (another account signed in) without
  /// disposing: widgets may still hold and unsubscribe from it.
  void _retire() {
    _disposed = true;
    _flushTimer?.cancel();
    unawaited(_changes.cancel());
  }

  @override
  void dispose() {
    _retire();
    super.dispose();
  }
}

/// Bounded cache of pack contents (imported or previewed packs whose room
/// state is not available yet): at most [maxPacks] packs and [maxChars] of
/// JSON, least recently stored first out.
class _PackCache {
  _PackCache(this._entries);

  static const maxPacks = 24;
  static const maxChars = 1536 * 1024;

  final Map<String, (int, Map<String, Object?>)> _entries;

  factory _PackCache.fromJson(Map<String, Object?>? json) {
    final entries = <String, (int, Map<String, Object?>)>{};
    final packs = json?['packs'];
    if (packs is Map) {
      for (final entry in packs.entries) {
        final value = entry.value;
        if (entry.key is! String || value is! Map) continue;
        final content = value['content'];
        final ts = value['ts'];
        if (content is! Map) continue;
        entries[entry.key as String] = (
          ts is int ? ts : 0,
          content.cast<String, Object?>(),
        );
      }
    }
    return _PackCache(entries);
  }

  ImagePackContent? content(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    try {
      return ImagePackContent.fromJson(entry.$2);
    } catch (_) {
      return null;
    }
  }

  void put(String key, ImagePackContent content, int ts) {
    _entries[key] = (ts, content.toJson());
    final byAge = _entries.entries.toList()
      ..sort((a, b) => a.value.$1.compareTo(b.value.$1));
    var size = jsonEncode(toJson()).length;
    for (final entry in byAge) {
      if (_entries.length <= maxPacks && size <= maxChars) break;
      if (entry.key == key) continue;
      _entries.remove(entry.key);
      size = jsonEncode(toJson()).length;
    }
  }

  Map<String, Object?> toJson() => {
    'packs': {
      for (final entry in _entries.entries)
        entry.key: {'ts': entry.value.$1, 'content': entry.value.$2},
    },
  };
}

/// The library on a Matrix client: synced state in account data, device
/// state in the client's (SQLCipher) database, packs from room state.
class MatrixStickerBackend implements StickerLibraryBackend {
  MatrixStickerBackend(this.client);

  final Client client;

  static const _accountTypes = {
    stickerLibraryType,
    gifLibraryType,
    imagePackRoomsType,
    unstableImagePackRoomsType,
    userImagePackType,
    unstableUserImagePackType,
  };

  @override
  Map<String, Object?>? readSynced(String type) =>
      client.accountData[type]?.content;

  /// The library shows the written version until the sync echo arrives;
  /// [Client.accountData] keeps what the server last sent.
  @override
  Future<void> writeSynced(String type, Map<String, Object?> content) async {
    final userId = client.userID;
    if (userId == null) throw StateError('Not signed in');
    await client.setAccountData(userId, type, content);
  }

  @override
  Map<String, Object?>? readLocal(String type) =>
      client.accountData[type]?.content;

  /// Device-only data goes into the client's encrypted database under an
  /// account data type that is never uploaded; the database loads it into
  /// [Client.accountData] at start.
  @override
  Future<void> writeLocal(String type, Map<String, Object?> content) async {
    client.accountData[type] = BasicEvent(type: type, content: content);
    await client.database.storeAccountData(type, content);
  }

  @override
  Stream<void> get changes => client.onSync.stream
      .where(_relevant)
      .map((_) {});

  static bool _relevant(SyncUpdate update) {
    if (update.accountData?.any((e) => _accountTypes.contains(e.type)) ??
        false) {
      return true;
    }
    final join = update.rooms?.join;
    if (join == null) return false;
    bool packEvent(BasicEvent event) =>
        imagePackStateTypes.contains(event.type);
    for (final room in join.values) {
      if (room.state?.any(packEvent) ?? false) return true;
      if (room.timeline?.events?.any(packEvent) ?? false) return true;
    }
    return false;
  }

  @override
  Map<String, ImagePackContent>? packsOfRoom(String roomId) {
    final room = client.getRoomById(roomId);
    if (room == null) return null;
    return roomImagePacks(room);
  }

  @override
  String? roomName(String roomId) =>
      client.getRoomById(roomId)?.getLocalizedDisplayname();

  @override
  List<(String, String)> enabledElsewhere() {
    final out = <(String, String)>[];
    final seen = <String>{};
    for (final type in [imagePackRoomsType, unstableImagePackRoomsType]) {
      final rooms = client.accountData[type]?.content['rooms'];
      if (rooms is! Map) continue;
      for (final entry in rooms.entries) {
        final keys = entry.value;
        if (entry.key is! String || keys is! Map) continue;
        for (final stateKey in keys.keys.whereType<String>()) {
          if (seen.add('${entry.key}|$stateKey')) {
            out.add((entry.key as String, stateKey));
          }
        }
      }
    }
    return out;
  }

  @override
  ImagePackContent? userPack() {
    for (final type in [userImagePackType, unstableUserImagePackType]) {
      final event = client.accountData[type];
      if (event == null) continue;
      try {
        return event.parsedImagePackContent;
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}

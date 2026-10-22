// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';

import 'sticker_models.dart';

/// Account data with the installed packs, recent and favourite stickers.
/// Synced through the homeserver (account data is not end-to-end
/// encrypted: the server sees which media and packs are used, never
/// messages).
const stickerLibraryType = 'pl.personal.chat.stickers.v1';

/// Account data with saved and recent GIFs (a separate event: account data
/// events are limited to about 64 KB).
const gifLibraryType = 'pl.personal.chat.gifs.v1';

/// Kept in this device's encrypted database only, never uploaded: recents,
/// favourites and GIFs whose media is a private encrypted file (its key
/// must not reach the server).
const stickerLocalType = 'pl.personal.chat.stickers.local.v1';

/// Kept in this device's database only: contents of imported or previewed
/// packs whose room state is not (yet) available.
const stickerPackCacheType = 'pl.personal.chat.stickers.cache.v1';

/// The library's item lists.
enum StickerList {
  recentStickers('recent', StickerKind.sticker, 30),
  favouriteStickers('favourites', StickerKind.sticker, 50),
  savedGifs('saved', StickerKind.gif, 100),
  recentGifs('recent', StickerKind.gif, 30);

  const StickerList(this.jsonKey, this.kind, this.cap);

  /// Key inside its account data event.
  final String jsonKey;
  final StickerKind kind;

  /// Telegram keeps 30 recent stickers (20 shown), 5 favourites (200 with
  /// Premium) and 200 saved GIFs; these caps keep both events well under
  /// the account data size limit.
  final int cap;

  bool get recent => this == recentStickers || this == recentGifs;

  /// The local (device-only) key of the list.
  String get localKey => '${kind.name}_$jsonKey';

  /// How many a strip or section shows.
  int get shown => recent ? 20 : cap;
}

/// Byte budget for one synced event (account data is limited to ~64 KB);
/// the oldest recents go first when an event would grow past it.
const syncedEventBudget = 48 * 1024;

/// The whole library state: one value, immutable. Item lists are newest
/// first (by [StickerItem.ts]), unique by media, capped.
@immutable
class StickerLibraryDoc {
  const StickerLibraryDoc({
    this.packs = const [],
    this.hidden = const [],
    this.lists = const {},
  });

  static const empty = StickerLibraryDoc();

  /// Installed packs in the user's order.
  final List<StickerPackRef> packs;

  /// Keys of packs enabled by other clients that the user hid here.
  final List<String> hidden;
  final Map<StickerList, List<StickerItem>> lists;

  List<StickerItem> list(StickerList list) => lists[list] ?? const [];

  StickerLibraryDoc copyWith({
    List<StickerPackRef>? packs,
    List<String>? hidden,
    Map<StickerList, List<StickerItem>>? lists,
  }) => StickerLibraryDoc(
    packs: packs ?? this.packs,
    hidden: hidden ?? this.hidden,
    lists: lists ?? this.lists,
  );

  StickerLibraryDoc withList(StickerList list, List<StickerItem> items) =>
      copyWith(lists: {...lists, list: normalizeList(items, list.cap)});

  /// Parses the synced events and the local one into one value. Items of
  /// the same media in both keep the newer entry.
  static StickerLibraryDoc fromJson({
    Map<String, Object?>? stickers,
    Map<String, Object?>? gifs,
    Map<String, Object?>? local,
  }) {
    final packs = <StickerPackRef>[];
    final seenPacks = <String>{};
    final rawPacks = stickers?['packs'];
    if (rawPacks is List) {
      for (final raw in rawPacks) {
        final ref = StickerPackRef.fromJson(raw);
        if (ref != null && seenPacks.add(ref.key)) packs.add(ref);
      }
    }
    final rawHidden = stickers?['hidden'];
    final lists = <StickerList, List<StickerItem>>{};
    for (final list in StickerList.values) {
      final synced = list.kind == StickerKind.sticker ? stickers : gifs;
      lists[list] = normalizeList([
        ..._items(synced?[list.jsonKey], list.kind),
        ..._items(local?[list.localKey], list.kind),
      ], list.cap);
    }
    return StickerLibraryDoc(
      packs: packs,
      hidden: [
        if (rawHidden is List) ...rawHidden.whereType<String>().toSet(),
      ],
      lists: lists,
    );
  }

  static List<StickerItem> _items(Object? raw, StickerKind kind) => [
    if (raw is List)
      for (final entry in raw) ?StickerItem.fromJson(entry, kind),
  ];

  /// The synced sticker event: packs, hidden packs and syncable items.
  Map<String, Object?> stickersJson() => {
    'packs': [for (final ref in packs) ref.toJson()],
    if (hidden.isNotEmpty) 'hidden': hidden,
    ..._syncedLists([StickerList.recentStickers, StickerList.favouriteStickers]),
  };

  /// The synced GIF event.
  Map<String, Object?> gifsJson() =>
      _syncedLists([StickerList.savedGifs, StickerList.recentGifs]);

  /// The device-only event: items that must not be synced.
  Map<String, Object?> localJson() => {
    for (final list in StickerList.values)
      list.localKey: [
        for (final item in this.list(list))
          if (!item.syncable) item.toJson(),
      ],
  };

  Map<String, Object?> _syncedLists(List<StickerList> which) {
    final out = <String, List<StickerItem>>{
      for (final list in which)
        list.jsonKey: [
          for (final item in this.list(list))
            if (item.syncable) item,
        ],
    };
    // Over budget: drop the oldest recents, then the oldest of the rest.
    int weight() => out.values.fold(
      256,
      (sum, items) => items.fold(sum, (s, item) => s + item.weight + 1),
    );
    final order = [
      for (final list in which)
        if (list.recent) list.jsonKey,
      for (final list in which)
        if (!list.recent) list.jsonKey,
    ];
    for (final key in order) {
      final items = out[key]!;
      while (items.isNotEmpty && weight() > syncedEventBudget) {
        items.removeLast();
      }
    }
    return {
      for (final entry in out.entries)
        entry.key: [for (final item in entry.value) item.toJson()],
    };
  }
}

/// Newest first, one entry per media (the newest), at most [cap].
List<StickerItem> normalizeList(Iterable<StickerItem> items, int cap) {
  final sorted = items.toList()..sort((a, b) => b.ts.compareTo(a.ts));
  final seen = <String>{};
  final out = <StickerItem>[];
  for (final item in sorted) {
    if (item.key.isEmpty || !seen.add(item.key)) continue;
    out.add(item);
    if (out.length >= cap) break;
  }
  return List.unmodifiable(out);
}

/// One change the user made. Changes are kept until they are stored, and
/// applied again on top of every newer version that arrives by sync, so
/// edits on two devices merge instead of overwriting each other.
@immutable
sealed class StickerLibraryOp {
  const StickerLibraryOp();
  StickerLibraryDoc apply(StickerLibraryDoc doc);
}

/// Adds [item] at the top of [list] (or moves it there).
class AddItemOp extends StickerLibraryOp {
  const AddItemOp(this.list, this.item);
  final StickerList list;
  final StickerItem item;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) {
    var items = [item, ...doc.list(list)];
    var result = doc.withList(list, items);
    // Telegram: a favourite does not also show among the recents.
    if (list == StickerList.favouriteStickers) {
      items = [
        for (final r in result.list(StickerList.recentStickers))
          if (r.key != item.key) r,
      ];
      result = result.withList(StickerList.recentStickers, items);
    }
    return result;
  }
}

/// Records a use: the item becomes the newest recent unless it is a
/// favourite (Telegram keeps favourites out of the recents).
class UseItemOp extends StickerLibraryOp {
  const UseItemOp(this.list, this.item);
  final StickerList list;
  final StickerItem item;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) {
    if (list == StickerList.recentStickers &&
        doc
            .list(StickerList.favouriteStickers)
            .any((f) => f.key == item.key)) {
      return doc;
    }
    return doc.withList(list, [item, ...doc.list(list)]);
  }
}

class RemoveItemOp extends StickerLibraryOp {
  const RemoveItemOp(this.list, this.key);
  final StickerList list;
  final String key;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) => doc.withList(list, [
    for (final item in doc.list(list))
      if (item.key != key) item,
  ]);
}

class ClearListOp extends StickerLibraryOp {
  const ClearListOp(this.list);
  final StickerList list;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) => doc.withList(list, []);
}

/// Installs a pack at the top (Telegram puts a newly added set first). A
/// pack that is already installed keeps its place.
class AddPackOp extends StickerLibraryOp {
  const AddPackOp(this.ref);
  final StickerPackRef ref;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) {
    final hidden = [
      for (final key in doc.hidden)
        if (key != ref.key) key,
    ];
    if (doc.packs.any((p) => p.key == ref.key)) {
      return doc.copyWith(hidden: hidden);
    }
    return doc.copyWith(packs: [ref, ...doc.packs], hidden: hidden);
  }
}

/// Removes a pack from ChatLoom (it stays installed on its network). A pack
/// enabled by another client is hidden instead.
class RemovePackOp extends StickerLibraryOp {
  const RemovePackOp(this.key, {this.hide = false});
  final String key;
  final bool hide;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) => doc.copyWith(
    packs: [
      for (final ref in doc.packs)
        if (ref.key != key) ref,
    ],
    hidden: hide && !doc.hidden.contains(key) ? [...doc.hidden, key] : null,
  );
}

/// The user's pack order. Packs it does not name (added elsewhere in the
/// meantime) keep their relative order after the named ones.
class OrderPacksOp extends StickerLibraryOp {
  const OrderPacksOp(this.keys);
  final List<String> keys;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) {
    final byKey = {for (final ref in doc.packs) ref.key: ref};
    final ordered = <StickerPackRef>[
      for (final key in keys) ?byKey.remove(key),
    ];
    return doc.copyWith(packs: [...ordered, ...byKey.values]);
  }
}

/// Shows a pack enabled by another client again (Undo of a hide).
class UnhidePackOp extends StickerLibraryOp {
  const UnhidePackOp(this.key);
  final String key;

  @override
  StickerLibraryDoc apply(StickerLibraryDoc doc) => doc.copyWith(
    hidden: [
      for (final k in doc.hidden)
        if (k != key) k,
    ],
  );
}

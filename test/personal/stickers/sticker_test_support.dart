// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline sticker library fixtures: fictional packs, rooms and media only.
import 'dart:async';

import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:matrix/matrix.dart';

/// An in-memory [StickerLibraryBackend].
class FakeStickerBackend implements StickerLibraryBackend {
  final synced = <String, Map<String, Object?>>{};
  final local = <String, Map<String, Object?>>{};
  final rooms = <String, Map<String, ImagePackContent>>{};
  final roomNames = <String, String>{};
  final elsewhere = <(String, String)>[];
  ImagePackContent? user;
  final writes = <String>[];
  final written = <String, Map<String, Object?>>{};
  Object? failWrites;

  /// The server's echo of a write arrives (by sync) before it returns.
  bool echo = true;
  final _changes = StreamController<void>.broadcast(sync: true);

  /// Another device wrote [content] (arrives by sync).
  void remote(String type, Map<String, Object?> content) {
    synced[type] = content;
    _changes.add(null);
  }

  void packStateChanged() => _changes.add(null);

  @override
  Map<String, Object?>? readSynced(String type) => synced[type];

  @override
  Future<void> writeSynced(String type, Map<String, Object?> content) async {
    await Future<void>.value();
    if (failWrites != null) throw failWrites!;
    writes.add(type);
    written[type] = content;
    if (echo) remote(type, content);
  }

  @override
  Map<String, Object?>? readLocal(String type) => local[type];

  @override
  Future<void> writeLocal(String type, Map<String, Object?> content) async {
    writes.add(type);
    local[type] = content;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Map<String, ImagePackContent>? packsOfRoom(String roomId) => rooms[roomId];

  @override
  String? roomName(String roomId) => roomNames[roomId];

  @override
  List<(String, String)> enabledElsewhere() => elsewhere;

  @override
  ImagePackContent? userPack() => user;

  @override
  Iterable<String> syncedTypes(String prefix) =>
      synced.keys.where((type) => type.startsWith(prefix)).toList();
}

StickerLibrary fakeLibrary(FakeStickerBackend backend, {int now = 1000}) {
  var clock = now;
  return StickerLibrary(
    backend,
    debounce: null,
    clock: () => DateTime.fromMillisecondsSinceEpoch(clock++),
  );
}

/// A sticker image of a pack (Telegram-style, with the bridge tag).
Map<String, Object?> packImage(
  String id, {
  String emoji = '😀',
  String mime = 'image/webp',
  bool tagged = true,
}) => {
  'url': 'mxc://example.invalid/$id',
  'body': emoji,
  'info': {
    'mimetype': mime,
    'w': 256,
    'h': 256,
    'size': 2048,
    'xyz.amorgan.blurhash': 'LEHV6nWB2yk8',
    if (tagged)
      'fi.mau.bridged_sticker': {
        'network': 'telegram',
        'id': id,
        'emoji': emoji,
        'pack_url': 'https://t.me/addstickers/FictionalPack',
      },
  },
};

ImagePackContent pack(
  String title,
  Map<String, Map<String, Object?>> images, {
  String? url,
}) => ImagePackContent.fromJson({
  'images': images,
  'pack': {
    'display_name': title,
    'usage': ['sticker'],
    if (url != null) 'fi.mau.bridged_pack': {'network': 'telegram', 'url': url},
  },
});

StickerItem sticker(String id, {String emoji = '😀', bool encrypted = false}) {
  final item = StickerItem.fromJson({
    if (!encrypted) 'url': 'mxc://example.invalid/$id',
    if (encrypted)
      'file': {
        'url': 'mxc://example.invalid/$id',
        'key': {'k': 'fixture-key-$id', 'alg': 'A256CTR'},
        'iv': 'fixture-iv',
        'hashes': {'sha256': 'fixture'},
        'v': 'v2',
      },
    'body': emoji,
    'info': {'mimetype': 'image/webp', 'w': 256, 'h': 256},
  }, StickerKind.sticker);
  return item!;
}

StickerItem videoGif(String id) => StickerItem.fromJson({
  'url': 'mxc://example.invalid/$id',
  'body': 'gif.mp4',
  'msgtype': MessageTypes.Video,
  'info': {
    'mimetype': 'video/mp4',
    'w': 320,
    'h': 240,
    'size': 40000,
    'duration': 2000,
    'thumbnail_url': 'mxc://example.invalid/$id-thumb',
    'fi.mau.gif': true,
    'fi.mau.loop': true,
    'fi.mau.autoplay': true,
    'fi.mau.hide_controls': true,
    'fi.mau.no_audio': true,
  },
}, StickerKind.gif)!;

StickerItem imageGif(String id) => StickerItem.fromJson({
  'url': 'mxc://example.invalid/$id',
  'body': 'funny.gif',
  'msgtype': MessageTypes.Image,
  'info': {'mimetype': 'image/gif', 'w': 200, 'h': 200, 'size': 30000},
}, StickerKind.gif)!;

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// `info` keys a saved sticker or GIF keeps. Everything a bridge needs to
/// send it natively survives (`fi.mau.bridged_sticker` makes the Telegram
/// bridge send the original document); previews, blurhashes and other
/// decoration are dropped so the synced account data stays small.
const _keptInfoKeys = {
  'mimetype',
  'size',
  'w',
  'h',
  'duration',
  'thumbnail_url',
  'thumbnail_file',
  'thumbnail_info',
  'fi.mau.bridged_sticker',
  'fi.mau.gif',
  'fi.mau.loop',
  'fi.mau.autoplay',
  'fi.mau.hide_controls',
  'fi.mau.no_audio',
  'fi.mau.telegram.animated_sticker',
};

const _keptThumbnailInfoKeys = {'mimetype', 'size', 'w', 'h'};

/// What a [StickerItem] is: a sticker (sent as `m.sticker` where possible)
/// or a GIF (an `m.image` GIF or an `m.video` flagged `fi.mau.gif`).
enum StickerKind { sticker, gif }

/// The `fi.mau.bridged_sticker` tag of a bridged sticker (mautrix-go
/// `event.BridgedSticker`): where it comes from on its network.
@immutable
class BridgedStickerRef {
  const BridgedStickerRef({
    required this.network,
    this.id,
    this.emoji,
    this.packUrl,
  });

  final String network;
  final String? id;
  final String? emoji;

  /// `https://t.me/addstickers/<name>` (Telegram) or a WhatsApp pack link.
  final String? packUrl;

  static BridgedStickerRef? fromInfo(Map<String, Object?>? info) {
    final raw = info?['fi.mau.bridged_sticker'];
    if (raw is! Map) return null;
    final network = raw['network'];
    if (network is! String || network.isEmpty) return null;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    return BridgedStickerRef(
      network: network,
      id: text(raw['id']),
      emoji: text(raw['emoji']),
      packUrl: text(raw['pack_url']),
    );
  }
}

/// One sendable sticker or GIF: an image of a pack, a recent, a favourite
/// or a saved GIF. [content] is the event content without relations:
/// `url` (or `file` for encrypted media), `body`, `info` and, for GIFs, a
/// `msgtype`. [ts] orders library lists (newest first).
@immutable
class StickerItem {
  const StickerItem._(this.kind, this.content, this.ts, this.packKey);

  final StickerKind kind;
  final Map<String, Object?> content;

  /// Milliseconds since the epoch: last use (recents) or when it was added.
  final int ts;

  /// The installed pack it was picked from, for "View pack".
  final String? packKey;

  /// A sticker from a pack image (`m.room.image_pack` / `im.ponies.*`).
  factory StickerItem.fromPackImage(
    ImagePackImageContent image, {
    required String shortcode,
    String? packKey,
  }) => StickerItem._(StickerKind.sticker, {
    'url': image.url.toString(),
    'body': (image.body?.trim().isNotEmpty ?? false) ? image.body! : shortcode,
    'info': _trimInfo(image.info),
    // Kept for search: the pack's shortcode ("<pack>_<keyword>").
    'shortcode': shortcode,
  }, 0, packKey);

  /// The sticker or GIF a message shows, or null when it is neither (or its
  /// media is missing). Relations, captions and formatting are not kept.
  static StickerItem? fromEvent(Event event) {
    if (event.redacted) return null;
    final content = event.content;
    final info = content.tryGetMap<String, Object?>('info');
    final url = content['url'];
    final file = content['file'];
    final hasMedia =
        (url is String && url.startsWith('mxc://')) ||
        (file is Map && file['url'] is String);
    if (!hasMedia) return null;
    final mime = info?['mimetype'];
    final StickerKind kind;
    String? msgtype;
    if (event.type == EventTypes.Sticker) {
      kind = StickerKind.sticker;
    } else if (event.type == EventTypes.Message &&
        content['msgtype'] == MessageTypes.Video &&
        info?['fi.mau.gif'] == true) {
      kind = info?['fi.mau.telegram.animated_sticker'] == true
          ? StickerKind.sticker
          : StickerKind.gif;
      msgtype = MessageTypes.Video;
    } else if (event.type == EventTypes.Message &&
        content['msgtype'] == MessageTypes.Image &&
        mime == 'image/gif') {
      kind = StickerKind.gif;
      msgtype = MessageTypes.Image;
    } else {
      return null;
    }
    // A video sticker stays an m.video (its bridge flags make it loop).
    if (kind == StickerKind.sticker && event.type == EventTypes.Message) {
      msgtype = MessageTypes.Video;
    }
    final body = content['body'];
    return StickerItem._(kind, {
      if (url is String) 'url': url,
      if (url is! String && file is Map) 'file': _copy(file),
      'body': body is String && body.isNotEmpty
          ? body
          : (kind == StickerKind.gif ? 'GIF' : 'Sticker'),
      'info': _trimInfo(info),
      'msgtype': ?msgtype,
    }, 0, null);
  }

  static StickerItem? fromJson(Object? json, StickerKind kind) {
    if (json is! Map) return null;
    final url = json['url'];
    final file = json['file'];
    if (!(url is String && url.startsWith('mxc://')) &&
        !(file is Map && file['url'] is String)) {
      return null;
    }
    final body = json['body'];
    final info = json['info'];
    final msgtype = json['msgtype'];
    final ts = json['ts'];
    final pack = json['pack'];
    final shortcode = json['shortcode'];
    return StickerItem._(
      kind,
      {
        if (url is String) 'url': url,
        if (url is! String && file is Map) 'file': _copy(file),
        'body': body is String ? body : '',
        'info': info is Map ? _trimInfo(_copy(info)) : <String, Object?>{},
        if (msgtype is String) 'msgtype': msgtype,
        if (shortcode is String) 'shortcode': shortcode,
      },
      ts is int ? ts : 0,
      pack is String ? pack : null,
    );
  }

  Map<String, Object?> toJson() => {
    ...content,
    'ts': ts,
    'pack': ?packKey,
  };

  StickerItem copyWith({int? ts, String? packKey}) =>
      StickerItem._(kind, content, ts ?? this.ts, packKey ?? this.packKey);

  String? get url => content['url'] as String?;
  Map<String, Object?>? get file =>
      (content['file'] as Map?)?.cast<String, Object?>();

  /// The mxc URI of the media (the ciphertext's for encrypted media).
  String get key => url ?? (file?['url'] as String? ?? '');

  Uri? get uri => url == null ? null : Uri.tryParse(url!);

  String get body => content['body'] as String? ?? '';
  String? get shortcode => content['shortcode'] as String?;
  Map<String, Object?> get info =>
      (content['info'] as Map?)?.cast<String, Object?>() ?? const {};
  String? get mimetype => info['mimetype'] as String?;
  String? get msgtype => content['msgtype'] as String?;
  int? get width => info['w'] is int ? info['w'] as int : null;
  int? get height => info['h'] is int ? info['h'] as int : null;
  int? get size => info['size'] is int ? info['size'] as int : null;

  bool get encrypted => url == null;
  bool get isVideo => msgtype == MessageTypes.Video;

  BridgedStickerRef? get bridged => BridgedStickerRef.fromInfo(info);

  /// The emoji a sticker stands for (Telegram stores it in the bridge tag
  /// and in the body), or null.
  String? get emoji {
    final tagged = bridged?.emoji;
    if (tagged != null) return tagged;
    final text = body.trim();
    return text.isNotEmpty && isEmojiOnly(text) ? text : null;
  }

  /// Unencrypted thumbnail of a GIF or video sticker.
  Uri? get thumbnailUri {
    final thumb = info['thumbnail_url'];
    return thumb is String ? Uri.tryParse(thumb) : null;
  }

  /// Whether the item may go into the synced (not end-to-end encrypted)
  /// account data. Unencrypted media and stickers of a public network pack
  /// are fine; the key of a private encrypted file stays on this device.
  bool get syncable => !encrypted || bridged?.packUrl != null;

  /// Approximate JSON size, for the account data budget.
  int get weight => _weigh(toJson());

  static int _weigh(Object? value) => switch (value) {
    final String s => s.length + 3,
    final Map m => m.entries.fold(
      2,
      (sum, e) => sum + _weigh(e.key) + _weigh(e.value) + 1,
    ),
    final List l => l.fold(2, (sum, e) => sum + _weigh(e) + 1),
    _ => 6,
  };

  @override
  bool operator ==(Object other) =>
      other is StickerItem && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);

  static Map<String, Object?> _copy(Map value) => {
    for (final entry in value.entries)
      '${entry.key}': _copyValue(entry.value),
  };

  static Object? _copyValue(Object? value) => switch (value) {
    final Map m => _copy(m),
    final List l => [for (final e in l) _copyValue(e)],
    _ => value,
  };

  static Map<String, Object?> _trimInfo(Map<String, Object?>? info) {
    if (info == null) return {};
    final out = <String, Object?>{};
    for (final entry in info.entries) {
      if (!_keptInfoKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (entry.key == 'thumbnail_info' && value is Map) {
        out[entry.key] = {
          for (final e in value.entries)
            if (_keptThumbnailInfoKeys.contains(e.key)) e.key as String: e.value,
        };
      } else {
        out[entry.key] = value is Map ? _copy(value) : value;
      }
    }
    return out;
  }
}

/// An installed pack: where its state lives. The pack content stays in the
/// room (normally the bridge's personal space), the library only points at
/// it. [stateKey] is the first (or combined) key of a split pack.
@immutable
class StickerPackRef {
  const StickerPackRef({
    required this.roomId,
    required this.stateKey,
    this.packUrl,
    this.network,
    this.title,
    this.addedTs = 0,
  });

  final String roomId;
  final String stateKey;

  /// The pack's network link (`https://t.me/addstickers/<name>`), if any.
  final String? packUrl;
  final String? network;

  /// Title when it was installed (shown while the state has not synced).
  final String? title;
  final int addedTs;

  String get key => packKeyOf(roomId, stateKey);

  static String packKeyOf(String roomId, String stateKey) =>
      '$roomId|$stateKey';

  static StickerPackRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final room = json['room_id'];
    final key = json['state_key'];
    if (room is! String || !room.startsWith('!') || key is! String) {
      return null;
    }
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    final added = json['added_ts'];
    return StickerPackRef(
      roomId: room,
      stateKey: key,
      packUrl: text(json['pack_url']),
      network: text(json['network']),
      title: text(json['title']),
      addedTs: added is int ? added : 0,
    );
  }

  Map<String, Object?> toJson() => {
    'room_id': roomId,
    'state_key': stateKey,
    'pack_url': ?packUrl,
    'network': ?network,
    'title': ?title,
    'added_ts': addedTs,
  };

  @override
  bool operator ==(Object other) => other is StickerPackRef && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Where a resolved pack comes from.
enum StickerPackSource {
  /// Installed in ChatLoom (the library's own list).
  installed,

  /// Enabled by another Matrix client (`m.image_pack.rooms`).
  enabledElsewhere,

  /// The account's own pack (`m.image_pack` account data).
  user,

  /// A pack of the open chat (Telegram's group sticker set).
  room,
}

/// A pack with its stickers, ready to show.
@immutable
class StickerPack {
  const StickerPack({
    required this.key,
    required this.title,
    required this.stickers,
    required this.source,
    this.avatar,
    this.packUrl,
    this.network,
    this.ref,
  });

  final String key;
  final String title;
  final Uri? avatar;
  final List<StickerItem> stickers;
  final StickerPackSource source;
  final String? packUrl;
  final String? network;

  /// The library entry, for installed packs.
  final StickerPackRef? ref;

  /// The pack icon: its avatar, else its first sticker.
  Uri? get icon => avatar ?? stickers.firstOrNull?.uri;

  /// Builds a pack from MSC2545 content. Images limited to emoticons are
  /// skipped (they are custom emoji, not stickers).
  static StickerPack fromContent(
    ImagePackContent content, {
    required String key,
    required StickerPackSource source,
    String? fallbackTitle,
    StickerPackRef? ref,
  }) {
    final packUsage = content.pack.usage;
    final stickers = <StickerItem>[];
    final seen = <String>{};
    for (final entry in content.images.entries) {
      final usage = entry.value.usage ?? packUsage;
      if (usage != null &&
          usage.isNotEmpty &&
          !usage.contains(ImagePackUsage.sticker)) {
        continue;
      }
      final item = StickerItem.fromPackImage(
        entry.value,
        shortcode: entry.key,
        packKey: key,
      );
      if (seen.add(item.key)) stickers.add(item);
    }
    final meta = content.pack.toJson();
    final bridged = meta['fi.mau.bridged_pack'];
    final avatar = content.pack.avatarUrl;
    return StickerPack(
      key: key,
      title:
          content.pack.displayName?.trim().isNotEmpty == true
          ? content.pack.displayName!.trim()
          : (ref?.title ?? fallbackTitle ?? 'Stickers'),
      avatar: avatar != null && avatar.scheme == 'mxc' ? avatar : null,
      stickers: stickers,
      source: source,
      packUrl: bridged is Map && bridged['url'] is String
          ? bridged['url'] as String
          : ref?.packUrl,
      network: bridged is Map && bridged['network'] is String
          ? bridged['network'] as String
          : ref?.network,
      ref: ref,
    );
  }
}

final _emojiOnly = RegExp(
  r'^(?:[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2190}-\u{21FF}'
  r'\u{2300}-\u{23FF}\u{3030}\u{303D}\u{3297}\u{3299}\u{00A9}\u{00AE}\u{2122}'
  r'\u{2139}\u{24C2}\u{25AA}-\u{25FE}\u{2934}\u{2935}\u{FE0F}\u{200D}'
  r'\u{20E3}\u{E0020}-\u{E007F}#*0-9])+$',
  unicode: true,
);

/// Whether [text] consists of emoji only (no letters or spaces).
bool isEmojiOnly(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  if (RegExp(r'^[#*0-9]+$').hasMatch(trimmed)) return false;
  return _emojiOnly.hasMatch(trimmed);
}

/// [emoji] without variation selectors and skin tones, so "❤️" finds "❤"
/// and "👍🏻" finds "👍".
String normalizeEmoji(String emoji) => emoji
    .replaceAll(RegExp(r'[\u{FE0E}\u{FE0F}\u{1F3FB}-\u{1F3FF}]', unicode: true), '')
    .trim();

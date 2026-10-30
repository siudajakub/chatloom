// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// One entry of a [GalleryContent], in the gallery's order.
@immutable
class GalleryItem {
  const GalleryItem._(this.index, this.type, this.content);

  final int index;

  /// `itemtype` (MSC4274) or `msgtype` (gomuks also writes `items` with
  /// ordinary msgtypes); null when the entry has neither.
  final String? type;

  /// The entry as written by the sender (the schema of an `m.image`,
  /// `m.video`, `m.audio` or `m.file` content).
  final Map<String, Object?> content;

  bool get _hasMedia => content['url'] is String || content['file'] is Map;

  /// An item ChatLoom can show: a known type with its media.
  bool get supported => GalleryContent.itemTypes.contains(type) && _hasMedia;

  /// A supported photo or video (a grid tile).
  bool get visual =>
      supported && (type == MessageTypes.Image || type == MessageTypes.Video);
}

/// MSC4274 inline media galleries: one `m.room.message` whose `itemtypes`
/// carry several photos, videos, audio files or files, and whose `body` is
/// the one caption. Until the MSC is merged the msgtype is
/// `dm.filament.gallery` (`m.gallery` once stable).
///
/// Senders seen (2026-10-29): gomuks (writes both `itemtypes` and `items`)
/// and the Matrix Rust SDK (Element X; `itemtypes`, caption or empty body).
/// No mautrix bridge sends one or accepts one: every bridgev2 connector
/// refuses the msgtype, so ChatLoom never sends galleries to a bridge (see
/// `MediaAlbumBatch` for multi-picks).
///
/// The MSC defines no fallback: a client that does not know the msgtype
/// shows only the caption. ChatLoom therefore draws every gallery, and an
/// entry it cannot show is listed as such instead of being dropped.
class GalleryContent {
  GalleryContent._(this.items, this.caption, this.malformed);

  static const unstableMsgType = 'dm.filament.gallery';
  static const stableMsgType = 'm.gallery';
  static const msgTypes = {unstableMsgType, stableMsgType};

  /// The item types MSC4274 allows.
  static const itemTypes = {
    MessageTypes.Image,
    MessageTypes.Video,
    MessageTypes.Audio,
    MessageTypes.File,
  };

  /// Every entry, in order (also the ones ChatLoom cannot show).
  final List<GalleryItem> items;

  /// The caption (`body`), or null when it is empty.
  final String? caption;

  /// The item list is missing or not a list: nothing to draw but the
  /// caption and a notice.
  final bool malformed;

  /// Whether [event] is a gallery message.
  static bool isGallery(Event event) =>
      event.type == EventTypes.Message &&
      msgTypes.contains(event.content['msgtype']);

  /// The gallery of [content], or null when it is not one.
  static GalleryContent? parse(Map<String, Object?> content, {String? body}) {
    if (!msgTypes.contains(content['msgtype'])) return null;
    final raw = _rawItems(content);
    final items = <GalleryItem>[];
    if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        final entry = raw[i];
        if (entry is! Map) {
          items.add(GalleryItem._(i, null, const {}));
          continue;
        }
        final map = <String, Object?>{
          for (final e in entry.entries)
            if (e.key is String) e.key as String: e.value,
        };
        final type = map['itemtype'] ?? map['msgtype'];
        items.add(GalleryItem._(i, type is String ? type : null, map));
      }
    }
    final text = body ?? content['body'];
    return GalleryContent._(
      List.unmodifiable(items),
      text is String && text.trim().isNotEmpty ? text.trim() : null,
      raw is! List,
    );
  }

  /// `itemtypes` (MSC4274, Rust SDK) first, else `items` (gomuks, the name
  /// mautrix-go reserves for the stable form).
  static Object? _rawItems(Map<String, Object?> content) {
    final itemtypes = content['itemtypes'];
    return itemtypes is List ? itemtypes : content['items'];
  }

  static final _cache = Expando<_Parsed>('gallery content');

  /// The gallery of [event] (null when it is not one), parsed once per
  /// event and content: rows rebuild often.
  static GalleryContent? of(Event event) {
    if (!isGallery(event)) return null;
    final cached = _cache[event];
    if (cached != null && cached.matches(event)) return cached.gallery;
    final content = event.content;
    final body = content['body'];
    final gallery = parse(
      content,
      // The caption without a reply fallback.
      body: body is String && body.trim().isNotEmpty
          ? event.calcUnlocalizedBody(hideReply: true, plaintextBody: true)
          : null,
    );
    _cache[event] = _Parsed(event, gallery);
    return gallery;
  }

  /// The supported items of [event]'s gallery as ordinary media events, so
  /// the timeline thumbnails, players and the photo viewer show them as
  /// they show any photo or video. Built once per event and content.
  static List<GalleryItemEvent> itemEvents(Event event) {
    final gallery = of(event);
    if (gallery == null) return const [];
    final cached = _cache[event];
    return cached!.events ??= List.unmodifiable([
      for (final item in gallery.items)
        if (item.supported) GalleryItemEvent._(event, item),
    ]);
  }

  /// Top-level keys of the gallery that protect its media (the keys
  /// `RoundMediaPolicy` reads): every item inherits them, so the viewer's
  /// save, share and forward follow the gallery's own limits.
  static const _protective = [
    'pl.personal.chat.telegram.media_policy',
    'pl.personal.chat.telegram.media',
    'fi.mau.telegram.media',
    'view_once',
    'fi.mau.telegram.view_once',
    'com.beeper.view_once',
    'com.beeper.view_limited',
    'ttl_seconds',
    'ttl',
    'fi.mau.telegram.ttl',
    'fi.mau.telegram.ttl_seconds',
  ];

  /// [item] as the content of an ordinary media message: its own msgtype,
  /// a body (the filename) and the gallery's protective keys.
  static Map<String, Object?> itemContent(
    GalleryItem item,
    Map<String, Object?> gallery,
  ) {
    final content = <String, Object?>{
      for (final key in _protective)
        if (gallery.containsKey(key)) key: gallery[key],
      ...item.content,
      'msgtype': item.type,
    }..remove('itemtype');
    final body = content['body'];
    if (body is! String || body.isEmpty) {
      final name = content['filename'];
      content['body'] = name is String && name.isNotEmpty
          ? name
          : switch (item.type) {
              MessageTypes.Image => 'image',
              MessageTypes.Video => 'video',
              MessageTypes.Audio => 'audio',
              _ => 'file',
            };
    }
    return content;
  }

  /// What a forward of [content] sends: a gallery becomes its items, one
  /// message each and in order, with the caption on the last one (a
  /// bridge refuses the gallery itself, and most clients would show only
  /// its caption). Anything else, or a gallery without a supported item,
  /// is forwarded as it is.
  static List<Map<String, Object?>> forwardContents(
    Map<String, Object?> content,
  ) {
    final gallery = parse(content);
    if (gallery == null) return [content];
    final supported = [
      for (final item in gallery.items)
        if (item.supported) item,
    ];
    if (supported.isEmpty) return [content];
    final out = [
      for (final item in supported)
        itemContent(item, content)
          ..remove('m.relates_to')
          ..remove('m.new_content'),
    ];
    final caption = gallery.caption;
    if (caption != null) {
      final last = out.last;
      // MSC2530: the body is a caption when a separate filename exists.
      final name = last['filename'];
      last['filename'] = name is String && name.isNotEmpty
          ? name
          : last['body'];
      last['body'] = caption;
      last.remove('format');
      last.remove('formatted_body');
    }
    return out;
  }
}

class _Parsed {
  _Parsed(Event event, this.gallery)
    : _items = GalleryContent._rawItems(event.content),
      _body = event.content['body'],
      _status = event.status;

  final GalleryContent? gallery;
  final Object? _items, _body;
  final EventStatus _status;
  List<GalleryItemEvent>? events;

  /// Edits and local echo updates replace [Event.content] values in place.
  bool matches(Event event) =>
      identical(_items, GalleryContent._rawItems(event.content)) &&
      identical(_body, event.content['body']) &&
      _status == event.status;
}

/// One item of a gallery message as an ordinary media event. Presentation
/// only: never sent, stored or acted on as a Matrix event (its id is not a
/// server event id); [gallery] is the real event.
class GalleryItemEvent extends Event {
  GalleryItemEvent._(this.gallery, GalleryItem item)
    : index = item.index,
      super(
        type: EventTypes.Message,
        eventId: '${gallery.eventId}/gallery/${item.index}',
        senderId: gallery.senderId,
        originServerTs: gallery.originServerTs,
        room: gallery.room,
        // A sending status would let the SDK mark this copy as failed and
        // write it into the timeline (`Event` constructor).
        status: gallery.status.isSending ? EventStatus.sent : gallery.status,
        content: GalleryContent.itemContent(item, gallery.content),
      );

  /// The gallery message this item belongs to.
  final Event gallery;

  /// Position in the gallery (also counting items ChatLoom cannot show).
  final int index;
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'sticker_models.dart';

/// One GIF of a search answer. Not sendable yet: [GifSearchSource.media]
/// turns it into Matrix media.
@immutable
class GifSearchResult {
  const GifSearchResult({
    required this.id,
    this.mimetype = 'video/mp4',
    this.width,
    this.height,
    this.durationMs,
    this.size,
    this.preview,
  });

  final String id;
  final String mimetype;
  final int? width;
  final int? height;
  final int? durationMs;
  final int? size;

  /// A tiny blurred JPEG (Telegram's stripped thumbnail) shown at once.
  final Uint8List? preview;

  double get aspectRatio {
    final w = width, h = height;
    return w != null && h != null && w > 0 && h > 0 ? w / h : 1;
  }

  static GifSearchResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    int? number(Object? value) => value is num ? value.toInt() : null;
    final mimetype = json['mimetype'];
    final thumb = json['thumb'];
    Uint8List? preview;
    if (thumb is String && thumb.isNotEmpty) {
      try {
        preview = base64.decode(base64.normalize(thumb));
      } catch (_) {
        preview = null;
      }
    }
    return GifSearchResult(
      id: id,
      mimetype: mimetype is String && mimetype.isNotEmpty
          ? mimetype
          : 'video/mp4',
      width: number(json['w']),
      height: number(json['h']),
      durationMs: number(json['duration']),
      size: number(json['size']),
      preview: preview,
    );
  }

  @override
  bool operator ==(Object other) => other is GifSearchResult && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// One page of results; [nextOffset] loads the next one.
@immutable
class GifSearchPage {
  const GifSearchPage(this.results, {this.nextOffset});

  final List<GifSearchResult> results;
  final String? nextOffset;

  static GifSearchPage fromJson(Object? json) {
    final results = json is Map ? json['results'] : null;
    final next = json is Map ? json['next_offset'] : null;
    return GifSearchPage([
      if (results is List)
        for (final entry in results) ?GifSearchResult.fromJson(entry),
    ], nextOffset: next is String && next.isNotEmpty ? next : null);
  }
}

/// The media of a result: its static [thumbnail] and, when asked for, the
/// sendable [item] (`m.video` + `fi.mau.gif`, unencrypted public media).
@immutable
class GifMedia {
  const GifMedia({this.thumbnail, this.item});

  final Uri? thumbnail;
  final StickerItem? item;

  static GifMedia fromJson(Object? json) {
    if (json is! Map) return const GifMedia();
    final thumb = json['thumbnail_url'];
    final url = json['url'];
    final info = json['info'];
    final thumbnail = thumb is String && thumb.startsWith('mxc://')
        ? Uri.tryParse(thumb)
        : null;
    final item = url is String && url.startsWith('mxc://') && info is Map
        ? StickerItem.fromJson({
            'url': url,
            'body': 'GIF',
            'info': info,
            'msgtype': MessageTypes.Video,
          }, StickerKind.gif)
        : null;
    return GifMedia(thumbnail: thumbnail, item: item);
  }
}

/// Whether search works for the account now, and what the field says.
@immutable
class GifSearchAvailability {
  const GifSearchAvailability.enabled(this.hint) : enabled = true, note = null;
  const GifSearchAvailability.disabled(this.hint, this.note) : enabled = false;

  final bool enabled;

  /// The search field's hint.
  final String hint;

  /// Why search is off (shown under the field), or null.
  final String? note;
}

/// A failed search or media request, as a sentence for people.
class GifSearchException implements Exception {
  const GifSearchException(this.message, {this.searchAgain = false});
  final String message;

  /// The result expired at the bridge: the current search should run again.
  final bool searchAgain;

  @override
  String toString() => 'GifSearchException';
}

/// A GIF search provider of the GIF tab. Results go through the same
/// per-network send adaptation as saved GIFs.
abstract interface class GifSearchSource {
  /// Whether search works for [room]'s account now.
  GifSearchAvailability availability(Room room);

  /// Notifies when [availability] may have changed.
  Listenable get changes;

  /// Checks reachability without sending any query (cached).
  void prepare(Room room);

  /// What the privacy note under the field says.
  String get privacyNote;

  /// One page of results for [query].
  Future<GifSearchPage> search(Room room, String query, {String? offset});

  /// The thumbnail and, with [video], the sendable GIF of [result].
  Future<GifMedia> media(Room room, GifSearchResult result, {bool video});

  /// Drops cached pages and media of [room]'s account (results expired).
  void forget(Room room);
}

/// Registered GIF search providers, first one wins (Telegram's `@gif`).
abstract final class GifSearchSources {
  static final List<GifSearchSource> registered = [TelegramGifSearch.shared];

  static GifSearchSource? forRoom(Room room) => registered.firstOrNull;
}

/// GIF search through Telegram's `@gif` bot, run by the Telegram bridge
/// fork with the user's own Telegram login (`POST /v3/gif/search`,
/// `POST /v3/gif/media`, same provisioning route and auth as sticker pack
/// import). No API key and no third-party provider: Telegram (and the
/// Beeper server relaying the request) see the search text, the bot does
/// not see which chat is open. A chosen GIF is uploaded once by the bridge
/// as public media and sent as an ordinary `m.video` + `fi.mau.gif`, so it
/// works on every network.
class TelegramGifSearch implements GifSearchSource {
  TelegramGifSearch({
    BridgeProvisioningTransport? Function(Client client, {required bool media})?
    transport,
    List<BridgeEndpoint> Function(Client client)? bridges,
    BridgeDirectory? Function(Client client)? directory,
  }) : _transportOf = transport ?? _defaultTransport,
       _bridgesOf = bridges ?? ((client) => discoverBridges(client.rooms)),
       _directoryOf = directory ?? BridgeDirectory.of;

  static final shared = TelegramGifSearch();

  static const network = 'telegram';
  static const mediaTimeout = Duration(seconds: 60);
  static const pageCacheSize = 16;
  static const mediaCacheSize = 200;

  final BridgeProvisioningTransport? Function(
    Client client, {
    required bool media,
  })
  _transportOf;
  final List<BridgeEndpoint> Function(Client client) _bridgesOf;
  final BridgeDirectory? Function(Client client) _directoryOf;

  final _changes = _Changes();
  final _unsupported = Expando<bool>('gif search unsupported');
  final _pages = Expando<_Lru<String, GifSearchPage>>('gif pages');
  final _media = Expando<_Lru<String, Future<GifMedia>>>('gif media');

  static BridgeProvisioningTransport? _defaultTransport(
    Client client, {
    required bool media,
  }) {
    final base = BridgeDirectory.of(client).api?.transport;
    if (!media || base is! BeeperProvisioningTransport) return base;
    // One GIF is downloaded from Telegram and uploaded before the answer.
    return BeeperProvisioningTransport(
      httpClient: base.httpClient,
      homeserver: base.homeserver,
      userId: base.userId,
      accessToken: base.accessToken,
      overrideUrl: base.overrideUrl,
      timeout: mediaTimeout,
    );
  }

  @override
  String get privacyNote =>
      'Searches go to Telegram’s @gif bot from your Telegram account.';

  @override
  Listenable get changes => _changes;

  BridgeEndpoint? _bridge(Client client) =>
      _bridgesOf(client).where((b) => b.network == network).firstOrNull;

  @override
  void prepare(Room room) {
    final bridge = _bridge(room.client);
    final directory = _directoryOf(room.client);
    if (bridge == null || directory == null) return;
    _changes.watch(directory);
    directory.probe([bridge]).ignore();
  }

  @override
  GifSearchAvailability availability(Room room) {
    const hint = 'Search GIFs via Telegram';
    final client = room.client;
    final bridge = _bridge(client);
    if (bridge == null) {
      return const GifSearchAvailability.disabled(
        hint,
        'GIF search uses your Telegram account. Connect Telegram to search GIFs.',
      );
    }
    if (_unsupported[client] == true) {
      return const GifSearchAvailability.disabled(
        hint,
        'Your Telegram bridge can’t search GIFs yet.',
      );
    }
    final directory = _directoryOf(client);
    if (directory == null || directory.api == null) {
      return const GifSearchAvailability.disabled(
        hint,
        'GIF search needs a Beeper account with your Telegram bridge.',
      );
    }
    if (!(directory.reaches?.call(bridge) ?? true)) {
      return const GifSearchAvailability.disabled(
        hint,
        'ChatLoom can’t reach your Telegram bridge from this account.',
      );
    }
    return switch (directory.stateOf(bridge).status) {
      BridgeRemoteStatus.notLoggedIn => const GifSearchAvailability.disabled(
        hint,
        'Sign in to Telegram to search GIFs.',
      ),
      BridgeRemoteStatus.unavailable => const GifSearchAvailability.disabled(
        hint,
        'ChatLoom can’t reach your Telegram bridge right now.',
      ),
      _ => const GifSearchAvailability.enabled(hint),
    };
  }

  Future<Object?> _send(
    Client client,
    String path,
    Map<String, Object?> body, {
    required bool media,
  }) async {
    final bridge = _bridge(client);
    final transport = _transportOf(client, media: media);
    if (bridge == null || transport == null) {
      throw const GifSearchException(
        'GIF search uses your Telegram account. Connect Telegram to search GIFs.',
      );
    }
    try {
      return await transport.send(
        bridge,
        BridgeProvisioningRequest('POST', path, body: body),
      );
    } on BridgeProvisioningException catch (e) {
      if (e.unsupported) {
        _unsupported[client] = true;
        _changes.changed();
      }
      throw GifSearchException(
        _message(e),
        searchAgain: e.errcode == 'M_NOT_FOUND',
      );
    }
  }

  /// A sentence for [e], from its status and code only (never the
  /// bridge's or Telegram's own text).
  static String _message(BridgeProvisioningException e) {
    if (e.unsupported) return 'Your Telegram bridge can’t search GIFs yet.';
    if (e.status == 0) {
      return 'Your Telegram bridge didn’t answer. Check your connection and try again.';
    }
    return switch (e.errcode) {
      'FI.MAU.NOT_LOGGED_IN' => 'Sign in to Telegram to search GIFs.',
      'M_LIMIT_EXCEEDED' =>
        'Telegram asked to slow down. Try again in a moment.',
      'M_NOT_FOUND' => 'This GIF is no longer available. Search again.',
      'M_TOO_LARGE' => 'This GIF is too large to send.',
      'M_INVALID_PARAM' => 'Type up to 256 characters to search.',
      _ when e.status == 401 || e.status == 403 =>
        'ChatLoom can’t reach your Telegram bridge right now.',
      _ => 'GIF search didn’t work. Try again.',
    };
  }

  static String _pageKey(String query, String? offset) =>
      '${query.trim().toLowerCase().split(RegExp(r'\s+')).join(' ')}\u0000${offset ?? ''}';

  @override
  Future<GifSearchPage> search(
    Room room,
    String query, {
    String? offset,
  }) async {
    final client = room.client;
    final pages = _pages[client] ??= _Lru(pageCacheSize);
    final key = _pageKey(query, offset);
    final cached = pages.get(key);
    if (cached != null) return cached;
    final json = await _send(client, '/v3/gif/search', {
      'query': query.trim(),
      'offset': offset ?? '',
    }, media: false);
    final page = GifSearchPage.fromJson(json);
    pages.put(key, page);
    return page;
  }

  @override
  Future<GifMedia> media(
    Room room,
    GifSearchResult result, {
    bool video = false,
  }) {
    final client = room.client;
    final cache = _media[client] ??= _Lru(mediaCacheSize);
    final full = cache.get('${result.id}|1');
    if (full != null) return full;
    final key = '${result.id}|${video ? 1 : 0}';
    final cached = cache.get(key);
    if (cached != null) return cached;
    final request = _send(client, '/v3/gif/media', {
      'id': result.id,
      'video': video,
    }, media: true).then(GifMedia.fromJson);
    cache.put(key, request);
    // A failure is not kept: the next request asks again.
    request.catchError((Object _) {
      if (identical(cache.get(key), request)) cache.remove(key);
      return const GifMedia();
    }).ignore();
    return request;
  }

  @override
  void forget(Room room) {
    _pages[room.client] = null;
    _media[room.client] = null;
  }
}

class _Changes extends ChangeNotifier {
  final _watched = <Listenable>{};

  void watch(Listenable source) {
    if (_watched.add(source)) source.addListener(notifyListeners);
  }

  void changed() => notifyListeners();
}

/// A small bounded LRU map.
class _Lru<K, V> {
  _Lru(this.limit);
  final int limit;
  final _map = <K, V>{};

  V? get(K key) {
    final value = _map.remove(key);
    if (value != null) _map[key] = value;
    return value;
  }

  void put(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > limit) {
      _map.remove(_map.keys.first);
    }
  }

  void remove(K key) => _map.remove(key);
}

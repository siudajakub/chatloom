// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'sticker_pack_import.dart';

/// One sticker set of Telegram's catalogue (a search answer or a trending
/// page of `/v3/sticker_sets/*`). Metadata only: its stickers are previewed
/// and imported through the pack link, like every Telegram pack.
@immutable
class CatalogStickerSet {
  const CatalogStickerSet({
    required this.shortName,
    required this.title,
    required this.link,
    this.count = 0,
    this.emoji = false,
    this.official = false,
    this.installedOnTelegram = false,
    this.hasCover = false,
  });

  final String shortName;
  final String title;
  final StickerPackLink link;
  final int count;

  /// A custom emoji set (sent as stickers in ChatLoom).
  final bool emoji;
  final bool official;

  /// Already in the user's Telegram account.
  final bool installedOnTelegram;

  /// The bridge can serve a cover image for it.
  final bool hasCover;

  static CatalogStickerSet? fromJson(Object? json) {
    if (json is! Map) return null;
    final shortName = json['short_name'];
    final url = json['url'];
    final link = StickerPackLink.parse(url is String ? url : null);
    if (shortName is! String || shortName.isEmpty || link == null) return null;
    if (link.network != 'telegram') return null;
    final title = json['title'];
    final count = json['count'];
    return CatalogStickerSet(
      shortName: shortName,
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : shortName,
      link: link,
      count: count is num ? count.toInt() : 0,
      emoji: json['emoji'] == true,
      official: json['official'] == true,
      installedOnTelegram: json['installed'] == true,
      hasCover: json['has_cover'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogStickerSet && other.link == link;

  @override
  int get hashCode => link.hashCode;
}

/// One page of sets; [nextOffset] loads the next trending page.
@immutable
class CatalogPage {
  const CatalogPage(this.sets, {this.nextOffset});

  final List<CatalogStickerSet> sets;
  final int? nextOffset;

  static CatalogPage fromJson(Object? json) {
    final sets = json is Map ? json['sets'] : null;
    final next = json is Map ? json['next_offset'] : null;
    final seen = <String>{};
    return CatalogPage([
      if (sets is List)
        for (final entry in sets)
          if (CatalogStickerSet.fromJson(entry) case final set?
              when seen.add(set.link.url.toLowerCase()))
            set,
    ], nextOffset: next is num && next > 0 ? next.toInt() : null);
  }
}

/// Why the catalogue can or can't be used now.
enum CatalogStatus {
  ready,

  /// No Telegram bridge on this account.
  noBridge,

  /// No route to the bridge (not a Beeper account, or not reachable).
  unreachable,

  /// The bridge answers but is not signed in to Telegram.
  notLoggedIn,

  /// The bridge is reachable but does not offer the catalogue routes yet
  /// (the ChatLoom fork with `/v3/sticker_sets/*` is not deployed).
  needsBridgeUpdate,
}

@immutable
class CatalogAvailability {
  const CatalogAvailability(this.status, [this.message]);

  static const ready = CatalogAvailability(CatalogStatus.ready);

  final CatalogStatus status;

  /// A sentence for people, null when ready.
  final String? message;

  bool get usable => status == CatalogStatus.ready;
}

/// A failed catalogue request, as a sentence (never a code or the bridge's
/// own text).
class StickerCatalogException implements Exception {
  const StickerCatalogException(this.message, {this.retryable = true});
  final String message;
  final bool retryable;

  @override
  String toString() => 'StickerCatalogException';
}

/// Telegram's sticker catalogue through the ChatLoom Telegram bridge fork
/// (`POST /v3/sticker_sets/search|featured|cover`, same provisioning route
/// and auth as pack import and GIF search). No API key and no third party:
/// Telegram (and the Beeper server relaying the request) see the search
/// text, nothing else. Feature-detected: the first `M_UNRECOGNIZED` answer
/// marks the bridge as "needs an update" for the session, so an old bridge
/// costs one request and never an error per keystroke.
class TelegramStickerCatalog {
  TelegramStickerCatalog(
    this.client, {
    BridgeProvisioningTransport? transport,
    BridgeProvisioningTransport? coverTransport,
    List<BridgeEndpoint>? bridges,
    BridgeDirectory? directory,
    bool useDirectory = true,
    this.retryDelay = const Duration(milliseconds: 800),
    DateTime Function()? clock,
  }) : _transport = transport,
       _coverTransport = coverTransport ?? transport,
       _bridges = bridges,
       _directory = useDirectory ? directory : null,
       _clock = clock ?? DateTime.now;

  factory TelegramStickerCatalog.of(Client client) {
    final directory = BridgeDirectory.of(client);
    final base = directory.api?.transport;
    return TelegramStickerCatalog(
      client,
      transport: base,
      // A cover is downloaded from Telegram and uploaded before the answer.
      coverTransport: base is BeeperProvisioningTransport
          ? BeeperProvisioningTransport(
              httpClient: base.httpClient,
              homeserver: base.homeserver,
              userId: base.userId,
              accessToken: base.accessToken,
              overrideUrl: base.overrideUrl,
              timeout: coverTimeout,
            )
          : base,
      directory: directory,
    );
  }

  static const network = 'telegram';
  static const coverTimeout = Duration(seconds: 40);
  static const cacheTtl = Duration(minutes: 10);
  static const pageCacheSize = 24;
  static const coverCacheSize = 300;
  static const maxQueryLength = 64;

  /// Concurrent cover requests (each one may upload a file at the bridge).
  static const coverSlots = 3;

  final Client client;
  final BridgeProvisioningTransport? _transport;
  final BridgeProvisioningTransport? _coverTransport;
  final List<BridgeEndpoint>? _bridges;
  final BridgeDirectory? _directory;
  final DateTime Function() _clock;

  /// Wait before the one automatic retry of a read that got no answer.
  final Duration retryDelay;

  // Per account, shared by every sheet of the session.
  static final _unsupported = Expando<bool>('sticker catalogue unsupported');
  static final _pages = Expando<_Lru<String, (DateTime, CatalogPage)>>(
    'sticker catalogue pages',
  );
  static final _covers = Expando<_Lru<String, Future<Uri?>>>(
    'sticker catalogue covers',
  );

  @visibleForTesting
  static void debugReset(Client client) {
    _unsupported[client] = null;
    _pages[client] = null;
    _covers[client] = null;
  }

  BridgeEndpoint? get bridge => (_bridges ?? discoverBridges(client.rooms))
      .where((b) => b.network == network)
      .firstOrNull;

  /// Checks reachability (whoami) without sending a query.
  void prepare() {
    final bridge = this.bridge;
    final directory = _directory;
    if (bridge == null || directory == null) return;
    directory.probe([bridge]).ignore();
  }

  CatalogAvailability get availability {
    final bridge = this.bridge;
    if (bridge == null) {
      return const CatalogAvailability(
        CatalogStatus.noBridge,
        'Connect Telegram to search its sticker packs.',
      );
    }
    if (_unsupported[client] == true) {
      return const CatalogAvailability(
        CatalogStatus.needsBridgeUpdate,
        'Searching Telegram’s packs needs an update of your Telegram bridge. '
        'Pack links and your Telegram packs still work.',
      );
    }
    final directory = _directory;
    if (_transport == null || (directory != null && directory.api == null)) {
      return const CatalogAvailability(
        CatalogStatus.unreachable,
        'Searching Telegram’s packs needs a Beeper account with your Telegram bridge.',
      );
    }
    if (directory != null) {
      if (!(directory.reaches?.call(bridge) ?? true)) {
        return const CatalogAvailability(
          CatalogStatus.unreachable,
          'ChatLoom can’t reach your Telegram bridge from this account.',
        );
      }
      if (directory.stateOf(bridge).status == BridgeRemoteStatus.notLoggedIn) {
        return const CatalogAvailability(
          CatalogStatus.notLoggedIn,
          'Sign in to Telegram to search its sticker packs.',
        );
      }
    }
    return CatalogAvailability.ready;
  }

  Future<Object?> _send(
    String path,
    Map<String, Object?> body, {
    bool cover = false,
  }) async {
    final bridge = this.bridge;
    final transport = cover ? _coverTransport : _transport;
    final available = availability;
    if (bridge == null || transport == null || !available.usable) {
      throw StickerCatalogException(
        available.message ?? 'Connect Telegram to search its sticker packs.',
        retryable: false,
      );
    }
    for (var attempt = 0; ; attempt++) {
      try {
        return await transport.send(
          bridge,
          BridgeProvisioningRequest('POST', path, body: body),
        );
      } on BridgeProvisioningException catch (e) {
        if (e.unsupported) {
          _unsupported[client] = true;
          throw StickerCatalogException(
            availability.message!,
            retryable: false,
          );
        }
        // Every catalogue route is a read: one quiet retry when the bridge
        // didn't answer or answered with a gateway error.
        final transient = e.status == 0 || e.status == 502 || e.status == 504;
        if (transient && attempt == 0) {
          if (retryDelay > Duration.zero) await Future.delayed(retryDelay);
          continue;
        }
        throw StickerCatalogException(_message(e), retryable: transient);
      }
    }
  }

  /// A sentence for [e], from its status and code only.
  static String _message(BridgeProvisioningException e) {
    if (e.status == 0) {
      return 'You’re offline or your Telegram bridge didn’t answer. Try again.';
    }
    return switch (e.errcode) {
      'FI.MAU.NOT_LOGGED_IN' =>
        'Sign in to Telegram to search its sticker packs.',
      'M_LIMIT_EXCEEDED' =>
        'Telegram asked to slow down. Try again in a moment.',
      'M_INVALID_PARAM' => 'Type up to $maxQueryLength characters to search.',
      'M_NOT_FOUND' => 'This sticker pack isn’t available.',
      _ when e.status == 401 || e.status == 403 =>
        'ChatLoom can’t reach your Telegram bridge right now.',
      _ => 'Telegram’s sticker packs couldn’t be loaded. Try again.',
    };
  }

  static String normalize(String query) =>
      query.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  _Lru<String, (DateTime, CatalogPage)> get _pageCache =>
      _pages[client] ??= _Lru(pageCacheSize);

  Future<CatalogPage> _cachedPage(
    String key,
    Future<Object?> Function() load,
  ) async {
    final now = _clock();
    final cached = _pageCache.get(key);
    if (cached != null && now.difference(cached.$1) < cacheTtl) {
      return cached.$2;
    }
    final page = CatalogPage.fromJson(await load());
    _pageCache.put(key, (now, page));
    return page;
  }

  /// Sets matching [query] (Telegram's own set search).
  Future<CatalogPage> search(String query) {
    final text = query.trim();
    if (text.isEmpty) return Future.value(const CatalogPage([]));
    final clipped = text.length > maxQueryLength
        ? text.substring(0, maxQueryLength)
        : text;
    return _cachedPage(
      'search\u0000${normalize(clipped)}',
      () => _send('/v3/sticker_sets/search', {'query': clipped}),
    );
  }

  /// Telegram's trending sets, page by page.
  Future<CatalogPage> featured({int offset = 0}) => _cachedPage(
    'featured\u0000$offset',
    () => _send('/v3/sticker_sets/featured', {'offset': offset}),
  );

  _Lru<String, Future<Uri?>> get _coverCache =>
      _covers[client] ??= _Lru(coverCacheSize);
  int _coversRunning = 0;
  final _coverQueue = <Completer<void>>[];

  /// The cover image of [set] (an mxc URI), or null when it has none.
  /// Cached per set; a failure is not kept, the next call asks again.
  Future<Uri?> cover(CatalogStickerSet set) {
    if (!set.hasCover) return Future.value(null);
    final key = set.shortName.toLowerCase();
    final cached = _coverCache.get(key);
    if (cached != null) return cached;
    final request = _loadCover(set);
    _coverCache.put(key, request);
    request.catchError((Object _) {
      if (identical(_coverCache.get(key), request)) _coverCache.remove(key);
      return null;
    }).ignore();
    return request;
  }

  Future<Uri?> _loadCover(CatalogStickerSet set) async {
    if (_coversRunning >= coverSlots) {
      final turn = Completer<void>();
      _coverQueue.add(turn);
      await turn.future;
    }
    _coversRunning++;
    try {
      final json = await _send('/v3/sticker_sets/cover', {
        'short_name': set.shortName,
      }, cover: true);
      final url = json is Map ? json['url'] : null;
      return url is String && url.startsWith('mxc://') ? Uri.parse(url) : null;
    } finally {
      _coversRunning--;
      if (_coverQueue.isNotEmpty) _coverQueue.removeAt(0).complete();
    }
  }
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

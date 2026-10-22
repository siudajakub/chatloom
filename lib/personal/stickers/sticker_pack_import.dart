// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';

/// A network sticker pack link the app can import: Telegram
/// `t.me/addstickers/<name>` (also `addemoji`, `telegram.me`, `tg://`) and
/// WhatsApp `wa.me/stickerpack/<id>`.
@immutable
class StickerPackLink {
  const StickerPackLink._(this.network, this.name, this.url, {this.emoji = false});

  /// `telegram` or `whatsapp`.
  final String network;
  final String name;

  /// The canonical link the bridge expects (`https://t.me/addstickers/x`).
  final String url;

  /// A Telegram custom emoji set (`addemoji`).
  final bool emoji;

  static final _telegram = RegExp(
    r'^(?:https?://)?(?:www\.)?(?:t|telegram)\.(?:me|dog)/(addstickers|addemoji)/([A-Za-z0-9_-]+)/?(?:[?#].*)?$',
    caseSensitive: false,
  );
  static final _telegramScheme = RegExp(
    r'^tg://(addstickers|addemoji)\?(?:.*&)?set=([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );
  static final _whatsapp = RegExp(
    r'^(?:https?://)?(?:www\.)?wa\.me/stickerpack/([A-Za-z0-9._-]+)/?(?:[?#].*)?$',
    caseSensitive: false,
  );

  static StickerPackLink? parse(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;
    final telegram =
        _telegram.firstMatch(text) ?? _telegramScheme.firstMatch(text);
    if (telegram != null) {
      final kind = telegram[1]!.toLowerCase();
      final name = telegram[2]!;
      return StickerPackLink._(
        'telegram',
        name,
        'https://t.me/$kind/$name',
        emoji: kind == 'addemoji',
      );
    }
    final whatsapp = _whatsapp.firstMatch(text);
    if (whatsapp != null) {
      final id = whatsapp[1]!;
      return StickerPackLink._(
        'whatsapp',
        id,
        'https://wa.me/stickerpack/$id',
      );
    }
    return null;
  }

  String get networkLabel => notionNetworkLabel(network);

  @override
  bool operator ==(Object other) =>
      other is StickerPackLink && other.url.toLowerCase() == url.toLowerCase();

  @override
  int get hashCode => url.toLowerCase().hashCode;
}

/// A pack of the user's network account (`GET /v3/image_pack/list`).
@immutable
class RemoteStickerPack {
  const RemoteStickerPack({
    required this.title,
    required this.link,
    this.emoji = false,
  });

  final String title;
  final StickerPackLink link;

  /// A custom emoji set rather than stickers.
  final bool emoji;

  static RemoteStickerPack? fromJson(Object? json) {
    if (json is! Map) return null;
    final bridged = json['fi.mau.bridged_pack'];
    final url = bridged is Map ? bridged['url'] : null;
    final link = StickerPackLink.parse(url is String ? url : null);
    if (link == null) return null;
    final name = json['display_name'];
    final usage = json['usage'];
    return RemoteStickerPack(
      title: name is String && name.trim().isNotEmpty ? name.trim() : link.name,
      link: link,
      emoji:
          usage is List &&
          usage.contains('emoticon') &&
          !usage.contains('sticker'),
    );
  }
}

/// Where an imported pack was stored (`RespImagePackSavedToRoom`).
@immutable
class ImportedStickerPack {
  const ImportedStickerPack({required this.roomId, required this.stateKeys});

  final String roomId;
  final List<String> stateKeys;

  String get stateKey => stateKeys.first;

  static ImportedStickerPack? fromJson(Object? json) {
    if (json is! Map) return null;
    final room = json['room_id'];
    final keys = json['state_keys'];
    final key = json['state_key'];
    final stateKeys = <String>[
      if (keys is List) ...keys.whereType<String>(),
      if ((keys is! List || keys.isEmpty) && key is String) key,
    ];
    if (room is! String || !room.startsWith('!') || stateKeys.isEmpty) {
      return null;
    }
    return ImportedStickerPack(roomId: room, stateKeys: stateKeys);
  }
}

/// A failed import, with a sentence for people (never an error code).
class StickerImportException implements Exception {
  const StickerImportException(this.message, {this.retryable = true});
  final String message;
  final bool retryable;

  @override
  String toString() => 'StickerImportException';
}

/// The bridges' image pack provisioning API (mautrix-go bridgev2
/// `/v3/image_pack/list`, `GET|POST /v3/image_pack/import?pack_url=`).
/// Listing and previewing change nothing; importing writes the pack into
/// the user's bridge space (where every Beeper client finds it) and the
/// library points at it. Requests go through the same route as bridge
/// contact search (hungryserv's `http_proxy`, UNVERIFIED on Beeper);
/// a route or bridge that does not answer gives a human message.
class StickerPackProvisioning {
  StickerPackProvisioning(
    this.client, {
    BridgeProvisioningTransport? transport,
    List<BridgeEndpoint>? bridges,
    bool Function(BridgeEndpoint bridge)? reaches,
    String? disabledReason,
  }) : _transport = transport,
       _bridges = bridges,
       _reaches = reaches,
       _disabledReason = disabledReason;

  factory StickerPackProvisioning.of(Client client) {
    final directory = BridgeDirectory.of(client);
    final base = directory.api?.transport;
    return StickerPackProvisioning(
      client,
      // An import uploads every sticker of the pack (a large one takes well
      // over the contact search's 20 s): same route, longer wait.
      transport: base is BeeperProvisioningTransport
          ? BeeperProvisioningTransport(
              httpClient: base.httpClient,
              homeserver: base.homeserver,
              userId: base.userId,
              accessToken: base.accessToken,
              overrideUrl: base.overrideUrl,
              timeout: importTimeout,
            )
          : base,
      reaches: directory.reaches,
      disabledReason: directory.disabledReason,
    );
  }

  static const importTimeout = Duration(minutes: 3);

  final Client client;
  final BridgeProvisioningTransport? _transport;
  final List<BridgeEndpoint>? _bridges;
  final bool Function(BridgeEndpoint bridge)? _reaches;
  final String? _disabledReason;

  /// The account's bridge for [network], or null.
  BridgeEndpoint? bridgeFor(String network) =>
      (_bridges ?? discoverBridges(client.rooms))
          .where((b) => b.network == network)
          .firstOrNull;

  Future<Object?> _send(
    String network,
    BridgeProvisioningRequest request, {
    required bool importing,
  }) async {
    final label = notionNetworkLabel(network);
    final transport = _transport;
    final bridge = bridgeFor(network);
    if (bridge == null) {
      throw StickerImportException(
        'No $label bridge is connected to this account.',
        retryable: false,
      );
    }
    if (transport == null || !(_reaches?.call(bridge) ?? true)) {
      throw StickerImportException(
        _disabledReason != null && transport == null
            ? 'Sticker import needs a Beeper account with a self-hosted $label bridge.'
            : 'ChatLoom can’t reach your $label bridge from this account.',
        retryable: false,
      );
    }
    try {
      return await transport.send(bridge, request);
    } on BridgeProvisioningException catch (e) {
      throw StickerImportException(
        _message(e, label, importing: importing),
        retryable: !e.unsupported,
      );
    }
  }

  static String _message(
    BridgeProvisioningException e,
    String label, {
    required bool importing,
  }) {
    if (e.unsupported) return 'Your $label bridge can’t import sticker packs.';
    if (e.status == 0) {
      return importing
          ? 'Your $label bridge didn’t answer in time. Try again in a moment.'
          : 'Your $label bridge didn’t answer. Check your connection and try again.';
    }
    if (e.errcode == 'M_NOT_FOUND') {
      final text = e.message?.toLowerCase() ?? '';
      if (importing && text.contains('space')) {
        return 'Your $label bridge has no space to keep imported packs in.';
      }
      if (text.contains('login')) {
        return 'Sign in to $label first.';
      }
      return 'This sticker pack doesn’t exist or isn’t available.';
    }
    if (e.status == 401 || e.status == 403) {
      return 'ChatLoom can’t reach your $label bridge right now.';
    }
    if (e.status == 404) {
      return 'Your $label bridge doesn’t offer sticker packs yet.';
    }
    return importing
        ? 'The sticker pack couldn’t be added. Try again.'
        : 'The sticker pack couldn’t be loaded. Try again.';
  }

  /// The user's installed packs on Telegram (stickers first).
  Future<List<RemoteStickerPack>> listPacks({String network = 'telegram'}) async {
    final json = await _send(
      network,
      const BridgeProvisioningRequest('GET', '/v3/image_pack/list'),
      importing: false,
    );
    final packs = [
      if (json is List)
        for (final entry in json) ?RemoteStickerPack.fromJson(entry),
    ];
    packs.sort((a, b) => (a.emoji ? 1 : 0).compareTo(b.emoji ? 1 : 0));
    return packs;
  }

  /// The pack's content without importing it.
  Future<ImagePackContent> preview(StickerPackLink link) async {
    final json = await _send(
      link.network,
      BridgeProvisioningRequest(
        'GET',
        '/v3/image_pack/import',
        query: {'pack_url': link.url},
      ),
      importing: false,
    );
    if (json is! Map) {
      throw const StickerImportException(
        'The sticker pack couldn’t be loaded. Try again.',
      );
    }
    try {
      return ImagePackContent.fromJson(json.cast<String, Object?>());
    } catch (_) {
      throw const StickerImportException(
        'The sticker pack couldn’t be loaded. Try again.',
      );
    }
  }

  /// Imports the pack into the bridge space and returns where it is.
  Future<ImportedStickerPack> import(StickerPackLink link) async {
    final json = await _send(
      link.network,
      BridgeProvisioningRequest(
        'POST',
        '/v3/image_pack/import',
        query: {'pack_url': link.url},
        body: const {},
      ),
      importing: true,
    );
    final imported = ImportedStickerPack.fromJson(json);
    if (imported == null) {
      throw const StickerImportException(
        'The sticker pack couldn’t be added. Try again.',
      );
    }
    return imported;
  }

  /// Imports [link] and installs it in the library. [preview] (already
  /// loaded content) is cached so the pack works before its state syncs;
  /// without it the state is read from the room, or the preview loaded.
  Future<StickerPackRef> install(
    StickerPackLink link, {
    String? title,
    ImagePackContent? preview,
    StickerLibrary? library,
  }) async {
    final lib = library ?? StickerLibrary.of(client);
    final imported = await import(link);
    final ref = StickerPackRef(
      roomId: imported.roomId,
      stateKey: imported.stateKey,
      packUrl: link.url,
      network: link.network,
      title: title ?? preview?.pack.displayName,
    );
    var content = preview;
    if (content == null &&
        lib.backend.packsOfRoom(imported.roomId)?[imported.stateKey] == null) {
      content = await _stateOrPreview(imported, link);
    }
    lib.addPack(ref, content: content);
    return ref;
  }

  /// Reads the imported state from the room (it may not have synced yet),
  /// else loads the preview. Null when neither works: the pack then shows
  /// once its state syncs.
  Future<ImagePackContent?> _stateOrPreview(
    ImportedStickerPack imported,
    StickerPackLink link,
  ) async {
    try {
      final parts = <String, StrippedStateEvent>{};
      for (final key in imported.stateKeys) {
        final content = await client.getRoomStateWithKey(
          imported.roomId,
          imagePackStateType,
          key,
        );
        parts[key] = StrippedStateEvent(
          type: imagePackStateType,
          content: content,
          senderId: '',
          stateKey: key,
        );
      }
      final combined = combineImagePackStates(parts);
      final content =
          combined[imported.stateKey] ?? combined.values.firstOrNull;
      if (content != null) return content;
    } catch (_) {
      // Not a member of the bridge space (yet): try the preview.
    }
    try {
      return await preview(link);
    } catch (_) {
      return null;
    }
  }
}

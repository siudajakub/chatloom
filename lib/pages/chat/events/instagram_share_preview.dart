// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/inline_reel_video.dart';
import 'package:chatloom/pages/chat/events/link_preview.dart';
import 'package:chatloom/pages/chat/events/reel_caption.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/personal/reel_metadata.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Link-media requests start only on explicit Play; Matrix-provided posters
/// respect the existing thumbnail preference.
class InstagramSharePreview extends StatefulWidget {
  final InstagramShare share;
  final Event? event;
  final Color? linkColor;
  const InstagramSharePreview({
    super.key,
    required this.share,
    this.event,
    this.linkColor,
  });
  @visibleForTesting
  static Future<Object?> Function(String url, bool download, int index)?
  debugRequest;
  @override
  State<InstagramSharePreview> createState() => _InstagramSharePreviewState();
}

class _InstagramSharePreviewState extends State<InstagramSharePreview> {
  bool _busy = false;
  bool _failed = false;
  List<Event> _assets = [];
  ReelMetadata? _metadata;
  int _generation = 0;

  BridgedLinkPreview? get _preview {
    for (final preview in BridgedLinkPreview.fromContent(
      widget.event?.content ?? {},
    )) {
      if (InstagramShare.fromUrl(preview.url)?.url == widget.share.url) {
        return preview;
      }
    }
    return null;
  }

  Widget? _poster() {
    final preview = _preview;
    final original = widget.event;
    if (original == null ||
        preview?.image == null ||
        !AppSettings.showThumbnailsInTimeline.value) {
      return null;
    }
    final event = Event(
      type: EventTypes.Message,
      room: original.room,
      eventId: '${original.eventId}/reel-poster',
      senderId: original.senderId,
      originServerTs: original.originServerTs,
      content: {
        'msgtype': MessageTypes.Image,
        'body': 'reel-preview.jpg',
        'url': preview!.image.toString(),
        'file': ?preview.imageEncryption,
      },
    );
    return MxcImage(event: event, fit: BoxFit.cover);
  }

  @override
  void didUpdateWidget(covariant InstagramSharePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.share.url != widget.share.url ||
        oldWidget.event?.eventId != widget.event?.eventId) {
      _generation++;
      _assets = [];
      _metadata = null;
      _busy = false;
      _failed = false;
    }
  }

  Future<void> _open() async {
    final original = widget.event;
    if (original == null || _busy || original.redacted) {
      return;
    }
    final generation = ++_generation;
    final client = original.room.client;
    final user = client.userID;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      Future<Object?> request(bool download, int index) {
        final custom = InstagramSharePreview.debugRequest;
        if (custom != null) {
          return custom(widget.share.url.toString(), download, index);
        }
        final bridges = discoverBridges(
          client.rooms,
        ).where((b) => b.network == 'instagram').toList();
        if (bridges.length != 1) {
          throw StateError('Instagram bridge unavailable');
        }
        final api = BridgeDirectory.of(client).api;
        if (api == null) {
          throw StateError('Instagram bridge unavailable');
        }
        final bridge = bridges.single;
        var transport = api.transport;
        if (transport is BeeperProvisioningTransport) {
          transport = BeeperProvisioningTransport(
            httpClient: transport.httpClient,
            homeserver: transport.homeserver,
            userId: transport.userId,
            accessToken: transport.accessToken,
            overrideUrl: transport.overrideUrl,
            timeout: const Duration(seconds: 75),
          );
        }
        return transport.send(
          bridge,
          BridgeProvisioningRequest(
            'POST',
            '/v3/chatloom/link_media',
            body: {
              'url': widget.share.url.toString(),
              'index': index,
              'download': download,
            },
          ),
        );
      }

      final metadataKey = Uri(
        scheme: 'chatloom-link',
        host: 'instagram',
        path: 'v2/${original.eventId}/${widget.share.url.path}',
      );
      final db = client.database;
      Object? response;
      final cached = await db.getFile(metadataKey);
      if (cached != null) {
        try {
          final envelope = jsonDecode(utf8.decode(cached));
          if (envelope is Map &&
              envelope['fetched_at'] is int &&
              DateTime.now().millisecondsSinceEpoch -
                      (envelope['fetched_at'] as int) <
                  const Duration(days: 1).inMilliseconds) {
            response = envelope['media'];
          }
        } catch (_) {
          await db.deleteFile(metadataKey);
        }
      }
      response ??= await request(false, 0);
      if (!mounted ||
          generation != _generation ||
          client.userID != user ||
          original.redacted) {
        return;
      }
      if (response is! Map || response['assets'] is! List) {
        throw StateError('Invalid media');
      }
      final metadata = ReelMetadata.fromInstagramResponse(
        widget.share,
        response,
        fallbackCaption: _preview?.description,
      );
      final metadataBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'media': response,
            'fetched_at': DateTime.now().millisecondsSinceEpoch,
          }),
        ),
      );
      if (metadataBytes.length < db.maxFileSize) {
        await db.storeFile(
          metadataKey,
          metadataBytes,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      final items = response['assets'] as List;
      if (items.isEmpty || items.length > 128) {
        throw StateError('Invalid media');
      }
      final assets = <Event>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item is! Map || !const ['image', 'video'].contains(item['type'])) {
          throw StateError('Invalid media');
        }
        final index = i;
        assets.add(
          _InstagramAsset(
            original: original,
            index: i,
            info: item,
            download: () async {
              if (client.userID != user || original.redacted) {
                throw StateError('Media access revoked');
              }
              await client.authorizeAttachmentAccess?.call(original, false);
              final result = await request(true, index);
              if (client.userID != user ||
                  original.redacted ||
                  result is! Map ||
                  result['data'] is! String ||
                  result['mime'] is! String) {
                throw StateError('Media unavailable');
              }
              final encoded = result['data'] as String;
              if (encoded.length > 90 * 1024 * 1024) {
                throw StateError('Media too large');
              }
              final bytes = base64Decode(encoded);
              if (bytes.isEmpty || bytes.length > 64 * 1024 * 1024) {
                throw StateError('Media too large');
              }
              return MatrixFile(
                bytes: bytes,
                name: item['type'] == 'video'
                    ? 'instagram.mp4'
                    : 'instagram.jpg',
                mimeType: result['mime'] as String,
              );
            },
          ),
        );
      }
      if (!mounted ||
          generation != _generation ||
          client.userID != user ||
          original.redacted) {
        return;
      }
      setState(() {
        _assets = assets;
        _metadata = metadata;
      });
      if (assets.first.messageType != MessageTypes.Video) {
        await showImageViewer(context, assets.first, mediaEvents: assets);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_assets.isEmpty &&
          _preview?.image != null &&
          AppSettings.showThumbnailsInTimeline.value)
        AspectRatio(
          aspectRatio: (_preview?.imageAspectRatio ?? 9 / 16).clamp(
            9 / 16,
            16 / 9,
          ),
          child: ClipRRect(
            borderRadius: NotionRadius.mdAll,
            child: NotionTapTarget(
              onTap: _busy ? null : _open,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _poster()!,
                  const Center(
                    child: Icon(
                      Icons.play_circle,
                      size: NotionSize.iconLg,
                      color: NotionMediaColors.onScrim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (_assets.isEmpty)
        Padding(
          padding: NotionBubble.padding,
          child: NotionButton.ghost(
            label: _failed
                ? 'Retry Instagram media'
                : widget.share.reel
                ? 'Play reel'
                : 'Download Instagram media',
            busy: _busy,
            onPressed: widget.event == null ? null : _open,
          ),
        ),
      if (_failed)
        const Padding(
          padding: NotionBubble.padding,
          child: Text(
            'Instagram media unavailable. Check access to this post.',
          ),
        ),
      if (_assets.isNotEmpty)
        if (_assets.first.messageType == MessageTypes.Video)
          InlineReelVideo(
            key: ValueKey(_assets.first.eventId),
            event: _assets.first,
            original: widget.event,
            poster: _poster(),
            playOnMount: true,
          )
        else
          ConversationMessageChromeTap(
            child: NotionTapTarget(
              onTap: () =>
                  showImageViewer(context, _assets.first, mediaEvents: _assets),
              child: AbsorbPointer(child: ImageBubble(_assets.first)),
            ),
          ),
      if (_assets.length > 1)
        Padding(
          padding: NotionBubble.padding,
          child: Text('${_assets.length} items · tap to view album'),
        ),
      if (_assets.length > 1)
        NotionButton.ghost(
          label: 'View album',
          onPressed: () =>
              showImageViewer(context, _assets.first, mediaEvents: _assets),
        ),
      ReelCaption(
        metadata:
            _metadata ??
            ReelMetadata(url: widget.share.url, caption: _preview?.description),
        linkColor: widget.linkColor,
      ),
    ],
  );
}

/// Local presentation adapter. Never sent or persisted as a Matrix message.
/// External media never enters the SDK downloader that attaches Matrix auth.
class _InstagramAsset extends Event {
  final Event original;
  final String? _owner;
  final Future<MatrixFile> Function() download;
  Future<MatrixFile>? _inflight;
  _InstagramAsset({
    required this.original,
    required int index,
    required Map info,
    required this.download,
  }) : _owner = original.room.client.userID,
       super(
         type: EventTypes.Message,
         eventId: '${original.eventId}/instagram/$index',
         senderId: original.senderId,
         originServerTs: original.originServerTs,
         room: original.room,
         content: {
           'msgtype': info['type'] == 'video'
               ? MessageTypes.Video
               : MessageTypes.Image,
           'body': info['type'] == 'video' ? 'instagram.mp4' : 'instagram.jpg',
           'url': 'mxc://chatloom-local.invalid/instagram',
           'chatloom.local_media': true,
           'info': {'w': info['width'], 'h': info['height']},
         },
       );
  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    if (original.redacted ||
        original.room.client.userID == null ||
        original.room.client.userID != _owner) {
      throw StateError('Media access revoked');
    }
    await original.room.client.authorizeAttachmentAccess?.call(
      original,
      getThumbnail,
    );

    final cacheKey = Uri(
      scheme: 'chatloom-media',
      host: 'instagram',
      path: eventId,
    );
    Future<MatrixFile> load() async {
      final db = original.room.client.database;
      final cached = await db.getFile(cacheKey);
      if (cached != null) {
        return MatrixFile(
          bytes: cached,
          name: body,
          mimeType: messageType == MessageTypes.Video
              ? 'video/mp4'
              : 'image/jpeg',
        );
      }
      if (fromLocalStoreOnly) {
        throw StateError('Not cached');
      }
      final file = await download();
      if (cacheAttachment && file.size < db.maxFileSize) {
        await db.storeFile(
          cacheKey,
          file.bytes,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      return file;
    }

    final future = _inflight ??= load();
    try {
      final file = await future;
      if (original.redacted || original.room.client.userID != _owner) {
        throw StateError('Media access revoked');
      }
      onDownloadProgress?.call(file.size);
      return file;
    } catch (_) {
      if (identical(_inflight, future)) {
        _inflight = null;
      }
      rethrow;
    }
  }
}

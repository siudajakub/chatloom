// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/video_player.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// All requests, including metadata, start only on an explicit tap.
class InstagramSharePreview extends StatefulWidget {
  final InstagramShare share;
  final Event? event;
  const InstagramSharePreview({super.key, required this.share, this.event});
  @override
  State<InstagramSharePreview> createState() => _InstagramSharePreviewState();
}

class _InstagramSharePreviewState extends State<InstagramSharePreview> {
  bool _busy = false;
  bool _failed = false;
  List<Event> _assets = [];
  int _generation = 0;
  @override
  void didUpdateWidget(covariant InstagramSharePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.share.url != widget.share.url ||
        oldWidget.event?.eventId != widget.event?.eventId) {
      _generation++;
      _assets = [];
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
      final url = widget.share.url.toString();
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
      Future<Object?> request(bool download, int index) => transport.send(
        bridge,
        BridgeProvisioningRequest(
          'POST',
          '/v3/chatloom/link_media',
          body: {'url': url, 'index': index, 'download': download},
        ),
      );
      final metadataKey = Uri(
        scheme: 'chatloom-link',
        host: 'instagram',
        path: '${original.eventId}/${widget.share.url.path}',
      );
      final db = client.database;
      Object? response;
      final cached = await db.getFile(metadataKey);
      if (cached != null) {
        try {
          response = jsonDecode(utf8.decode(cached));
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
      final metadataBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(response)),
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
      setState(() => _assets = assets);
      await showImageViewer(context, assets.first, mediaEvents: assets);
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
      if (_assets.isEmpty)
        Padding(
          padding: NotionBubble.padding,
          child: NotionButton.ghost(
            label: _failed
                ? 'Retry Instagram media'
                : widget.share.reel
                ? 'Download reel'
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
        NotionTapTarget(
          onTap: () =>
              showImageViewer(context, _assets.first, mediaEvents: _assets),
          child: AbsorbPointer(
            child: _assets.first.messageType == MessageTypes.Video
                ? EventVideoPlayer(_assets.first)
                : ImageBubble(_assets.first),
          ),
        ),
      if (_assets.length > 1)
        Padding(
          padding: NotionBubble.padding,
          child: Text('${_assets.length} items · tap to view album'),
        ),
      Padding(
        padding: NotionBubble.padding,
        child: NotionButton.ghost(
          label: 'Open in Instagram',
          onPressed: () =>
              UrlLauncher(context, widget.share.url.toString()).launchUrl(),
        ),
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

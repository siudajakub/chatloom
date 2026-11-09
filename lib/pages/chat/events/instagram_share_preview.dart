// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/inline_reel_video.dart';
import 'package:chatloom/pages/chat/events/link_preview.dart';
import 'package:chatloom/pages/chat/events/reel_caption.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/personal/media/instagram_media.dart';
import 'package:chatloom/personal/reel_metadata.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
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
        oldWidget.event?.eventId != widget.event?.eventId ||
        oldWidget.event?.room.id != widget.event?.room.id ||
        !identical(oldWidget.event?.room.client, widget.event?.room.client)) {
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

      final post = await loadInstagramPost(
        original: original,
        url: widget.share.url,
        request: () => request(false, 0),
      );
      if (!mounted ||
          generation != _generation ||
          client.userID != user ||
          original.redacted) {
        return;
      }
      final metadata = ReelMetadata.fromInstagramResponse(
        widget.share,
        post.response,
        fallbackCaption: _preview?.description,
      );
      final items = post.assets;
      final assets = <Event>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (!const ['image', 'video'].contains(item['type'])) {
          throw StateError('Invalid media');
        }
        final index = i;
        assets.add(
          InstagramMediaAsset(
            original: original,
            url: widget.share.url,
            index: i,
            info: item,
            request: () => request(true, index),
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

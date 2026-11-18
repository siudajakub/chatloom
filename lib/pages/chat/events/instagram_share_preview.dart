// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/video_player.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/personal/media/instagram_media.dart';
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
        oldWidget.event?.eventId != widget.event?.eventId ||
        oldWidget.event?.room.id != widget.event?.room.id ||
        !identical(oldWidget.event?.room.client, widget.event?.room.client)) {
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
      final items = await loadInstagramMetadata(
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
      final assets = <Event>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
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

  /// A shared reel before it is loaded: its vertical 9:16 frame with a
  /// play button. Nothing is requested until the tap.
  Widget _reelPlaceholder(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final frame = EventVideoPlayer.reelFrame(
        maxWidth: constraints.maxWidth,
        maxHeight: ConversationMedia.maxHeightOf(context, constraints),
      );
      return ConversationMessageChromeTap(
        child: Material(
          key: const ValueKey('instagram-reel-placeholder'),
          color: context.notion.colors.surface,
          borderRadius: NotionRadius.mdAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.event == null || _busy ? null : _open,
            child: SizedBox.fromSize(
              size: frame,
              child: Center(
                child: _busy
                    ? const NotionDelayedSpinner()
                    : Semantics(
                        button: true,
                        label: _failed ? 'Retry reel' : 'Play reel',
                        child: const DecoratedBox(
                          decoration: ShapeDecoration(
                            color: NotionMediaColors.scrim,
                            shape: CircleBorder(),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(NotionSpace.sm),
                            child: Icon(
                              Icons.play_arrow_outlined,
                              color: NotionMediaColors.onScrim,
                              size: NotionSize.iconLg,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final reel = widget.share.reel;
    final video =
        _assets.isNotEmpty && _assets.first.messageType == MessageTypes.Video;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_assets.isEmpty && reel)
          _reelPlaceholder(context)
        else if (_assets.isEmpty)
          Padding(
            padding: NotionBubble.padding,
            child: NotionButton.ghost(
              label: _failed
                  ? 'Retry Instagram media'
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
          ConversationMessageChromeTap(
            child: NotionTapTarget(
              onTap: () =>
                  showImageViewer(context, _assets.first, mediaEvents: _assets),
              child: AbsorbPointer(
                child: video
                    ? EventVideoPlayer(_assets.first)
                    : ImageBubble(_assets.first),
              ),
            ),
          ),
        if (_assets.length > 1)
          Padding(
            padding: NotionBubble.padding,
            child: Text('${_assets.length} items · tap to view album'),
          ),
        // A loaded video keeps its link in the player's menu; posts,
        // stories and anything not loaded keep the button here.
        if (!video)
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
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/inline_loop_video.dart';
import 'package:chatloom/pages/chat/events/outgoing_upload_progress.dart';
import 'package:chatloom/pages/chat/events/sticker_event.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/media/gallery_batch.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Place of one row in a run of photos/videos drawn as one album.
class MediaAlbumSlot {
  const MediaAlbumSlot._({required this.members, required this.lead});

  /// The album, oldest first (reading order of the grid).
  final List<Event> members;

  /// This row draws the album (its newest message); the other members draw
  /// nothing but keep their row, so list indexes and scroll targets stay.
  final bool lead;

  /// Index (in the list the slots were made from) of the message older than
  /// the album; the lead groups with it instead of its own hidden members.
  int get olderIndexOffset => members.length;
}

/// Telegram/Messenger albums: consecutive photos and videos one sender sent
/// together become one grid bubble. Pure and O(n) over the list built once
/// per list build.
abstract final class MediaAlbums {
  /// Largest album; a longer run starts a new one.
  static const maxItems = 10;

  /// Longest gap between two members.
  static const maxGap = Duration(seconds: 30);

  /// May [event] be part of an album at all.
  static bool _media(Event event) {
    if (event.redacted) return false;
    if (event.type != EventTypes.Message) return false;
    if (event.messageType != MessageTypes.Image &&
        event.messageType != MessageTypes.Video) {
      return false;
    }
    if (event.status.isError) return false;
    // A sticker sent as an image floats alone at sticker size.
    if (StickerEvents.isImageSticker(event)) return false;
    if (event.inReplyToEventId(includingFallback: false) != null) return false;
    final relation = event.content.tryGetMap<String, Object?>('m.relates_to');
    if (relation?['rel_type'] == RelationshipTypes.thread) return false;
    if (event.messageType == MessageTypes.Video) {
      if (RoundVideoDescriptor.fromContent(event.content) != null) return false;
      if (InlineLoopVideo.applies(event)) return false;
    }
    final policy = RoundMediaPolicy.fromContent(event.content);
    // View-once media is its own "Tap to view" bubble, never a grid tile.
    return policy.canPlay && policy.viewOnceMode == null;
  }

  /// One sender's neighbours within [maxGap], or of one ChatLoom multi-pick
  /// ([MediaAlbumBatch]) however long its uploads took; two different picks
  /// stay two albums.
  static bool _adjacent(Event newer, Event older) {
    final newerBatch = MediaAlbumBatch.idOf(newer);
    final olderBatch = MediaAlbumBatch.idOf(older);
    if (newerBatch != null && olderBatch != null && newerBatch != olderBatch) {
      return false;
    }
    return identical(newer.room.client, older.room.client) &&
        newer.room.id == older.room.id &&
        newer.senderId == older.senderId &&
        ((newerBatch != null && newerBatch == olderBatch) ||
            newer.originServerTs.difference(older.originServerTs).abs() <=
                maxGap) &&
        newer.originServerTs.toLocal().day ==
            older.originServerTs.toLocal().day;
  }

  /// Album slots for [events] (newest first, as the reversed timeline).
  /// [standalone] keeps an event out of albums as a hidden member (it has
  /// reactions, thread replies or carries the read marker); it may still
  /// lead one, since the lead keeps its own footer.
  static List<MediaAlbumSlot?> of(
    List<Event> events, {
    bool Function(Event event)? standalone,
  }) {
    final slots = List<MediaAlbumSlot?>.filled(events.length, null);
    var i = 0;
    while (i < events.length) {
      final lead = events[i];
      if (!_media(lead)) {
        i++;
        continue;
      }
      // Walk older messages while they join the lead's run.
      var end = i;
      while (end + 1 < events.length &&
          end - i + 1 < maxItems &&
          _media(events[end + 1]) &&
          _adjacent(events[end], events[end + 1]) &&
          // Only the newest member may carry a caption.
          events[end + 1].fileDescription == null &&
          !(standalone?.call(events[end + 1]) ?? false)) {
        end++;
      }
      if (end > i) {
        final members = List<Event>.unmodifiable(
          events.sublist(i, end + 1).reversed,
        );
        slots[i] = MediaAlbumSlot._(members: members, lead: true);
        for (var j = i + 1; j <= end; j++) {
          slots[j] = MediaAlbumSlot._(members: members, lead: false);
        }
      }
      i = end + 1;
    }
    return slots;
  }

  /// Rows of the grid for [count] tiles: rows of up to three, a shorter
  /// first row, and four as two pairs.
  static List<int> rows(int count) {
    if (count <= 0) return const [];
    if (count <= 3) return [count];
    if (count == 4) return const [2, 2];
    final rest = count % 3;
    return [if (rest != 0) rest, for (var i = 0; i < count ~/ 3; i++) 3];
  }
}

/// The album bubble content: a grid of thumbnails; a tap opens the viewer at
/// that item (it pages across the chat's media as usual, or across
/// [viewerEvents]). At most [MediaAlbums.maxItems] tiles; the last one then
/// counts the rest ("+5"), which the viewer still pages through.
class MediaAlbumGrid extends StatelessWidget {
  const MediaAlbumGrid({
    super.key,
    required this.events,
    required this.borderRadius,
    this.timelineFor,
    this.viewerEvents,
    this.maxWidth = NotionBubble.mediaMaxWidth,
  });

  /// Oldest first.
  final List<Event> events;
  final BorderRadius borderRadius;
  final Timeline? Function(Event event)? timelineFor;

  /// What the viewer pages through instead of the chat's media (a gallery
  /// message's own items, whose events are not in the timeline).
  final List<Event>? viewerEvents;
  final double maxWidth;

  /// Space between tiles.
  static const double gap = 2;

  /// Height of a single-tile row relative to the width.
  static const double wideRowAspect = .62;

  @override
  Widget build(BuildContext context) {
    final shown = events.length > MediaAlbums.maxItems
        ? events.sublist(0, MediaAlbums.maxItems)
        : events;
    final rows = MediaAlbums.rows(shown.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          constraints.hasBoundedWidth ? constraints.maxWidth : maxWidth,
          maxWidth,
        );
        double rowHeight(int columns) => columns == 1
            ? width * wideRowAspect
            : (width - gap * (columns - 1)) / columns;
        final natural =
            rows.fold<double>(0, (sum, c) => sum + rowHeight(c)) +
            gap * (rows.length - 1);
        final maxHeight = ConversationMedia.maxHeightOf(context, constraints);
        final scale = natural > maxHeight && natural > 0
            ? maxHeight / natural
            : 1.0;
        var index = 0;
        final children = <Widget>[];
        for (final columns in rows) {
          final height = rowHeight(columns) * scale;
          final tileWidth = (width - gap * (columns - 1)) / columns;
          final tiles = <Widget>[];
          for (var c = 0; c < columns; c++) {
            final event = shown[index++];
            tiles.add(
              _AlbumTile(
                event: event,
                width: tileWidth,
                height: height,
                timeline: timelineFor?.call(event),
                viewerEvents: viewerEvents,
                more: index == shown.length ? events.length - shown.length : 0,
              ),
            );
          }
          children.add(
            SizedBox(
              height: height,
              child: Row(spacing: gap, children: tiles),
            ),
          );
        }
        return Semantics(
          label: 'Album, ${events.length} items',
          child: ClipRRect(
            borderRadius: borderRadius,
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: gap,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.event,
    required this.width,
    required this.height,
    required this.timeline,
    this.viewerEvents,
    this.more = 0,
  });

  final Event event;
  final double width;
  final double height;
  final Timeline? timeline;
  final List<Event>? viewerEvents;

  /// Items after this (last) tile that the grid does not show.
  final int more;

  @override
  Widget build(BuildContext context) {
    final video = event.messageType == MessageTypes.Video;
    final blurHash =
        event.infoMap.tryGet<String>('xyz.amorgan.blurhash') ??
        'LEHV6nWB2yk8pyo0adR*.7kCMdnj';
    Widget placeholder(BuildContext context) => BlurHash(
      blurhash: blurHash,
      width: width,
      height: height,
      fit: BoxFit.cover,
    );
    final thumbnail =
        AppSettings.showThumbnailsInTimeline.value &&
        (!video || event.hasThumbnail);
    final uploading = isOutgoingUpload(event);
    final duration = event.infoMap.tryGet<int>('duration');
    return SizedBox(
      width: width,
      height: height,
      // A double tap on a tile reacts to the album; a single tap opens it.
      child: ConversationMessageChromeTap(
        child: NotionTapTarget(
          onTap: uploading
              ? null
              : () => showImageViewer(
                  context,
                  event,
                  timeline: timeline,
                  mediaEvents: viewerEvents,
                ),
          child: Hero(
            tag: event.eventId,
            createRectTween: NotionMediaHero.rectTween,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumbnail)
                  MxcImage(
                    event: event,
                    cacheKey: event.transactionId ?? event.eventId,
                    cacheName: event.room.id,
                    isThumbnail: true,
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                    placeholder: placeholder,
                  )
                else
                  placeholder(context),
                if (uploading)
                  Center(
                    child: OutgoingUploadOverlay(
                      progress: uploadProgressOf(event),
                    ),
                  )
                else if (video)
                  Center(
                    child: DecoratedBox(
                      decoration: const ShapeDecoration(
                        color: NotionMediaColors.scrim,
                        shape: CircleBorder(),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(NotionSpace.xs),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: NotionMediaColors.onScrim,
                          size: NotionSize.iconMd,
                          semanticLabel: duration == null
                              ? 'Video'
                              : 'Video, ${NotionMediaPlaybackControls.formatTime(Duration(milliseconds: duration))}',
                        ),
                      ),
                    ),
                  ),
                if (more > 0)
                  ColoredBox(
                    color: NotionMediaColors.scrim,
                    child: Center(
                      child: Text(
                        '+$more',
                        semanticsLabel: '$more more',
                        style: context.notion.typography.headline.copyWith(
                          color: NotionMediaColors.onScrim,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

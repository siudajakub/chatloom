// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'message_download_content.dart';

/// An MSC4274 gallery message ([GalleryContent]) in its media bubble: the
/// photos and videos as one album grid (a tap opens the viewer, which pages
/// through the gallery's own items), then its audio and files as download
/// rows, then a line for the entries ChatLoom cannot show. Nothing is
/// dropped silently. The caller draws the caption below.
class GalleryMessage extends StatelessWidget {
  const GalleryMessage(
    this.event, {
    super.key,
    required this.gallery,
    required this.borderRadius,
    required this.textColor,
    required this.linkColor,
  });

  final Event event;
  final GalleryContent gallery;
  final BorderRadius borderRadius;
  final Color textColor;
  final Color linkColor;

  static bool _visual(Event item) =>
      item.messageType == MessageTypes.Image ||
      item.messageType == MessageTypes.Video;

  /// The line for entries that cannot be shown, or null.
  static String? noticeFor(GalleryContent gallery) {
    if (gallery.malformed || gallery.items.isEmpty) {
      return 'This album could not be shown.';
    }
    final missing = gallery.items.where((item) => !item.supported).length;
    if (missing == 0) return null;
    return missing == 1
        ? '1 item of this album cannot be shown.'
        : '$missing items of this album cannot be shown.';
  }

  @override
  Widget build(BuildContext context) {
    final items = GalleryContent.itemEvents(event);
    final visual = [
      for (final item in items)
        if (_visual(item)) item,
    ];
    final notice = noticeFor(gallery);
    final rows = <Widget>[
      for (final item in items)
        if (!_visual(item))
          Padding(
            padding: NotionBubble.padding,
            child: MessageDownloadContent(
              item,
              textColor: textColor,
              linkColor: linkColor,
            ),
          ),
      if (notice != null)
        Padding(
          padding: NotionBubble.padding,
          child: Text(
            notice,
            style: context.notion.typography.footnote.copyWith(
              color: textColor,
            ),
          ),
        ),
    ];
    final grid = visual.isEmpty
        ? null
        : MediaAlbumGrid(
            events: visual,
            viewerEvents: visual,
            borderRadius: borderRadius,
          );
    if (rows.isEmpty && grid != null) return grid;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: NotionBubble.mediaMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [?grid, ...rows],
      ),
    );
  }
}

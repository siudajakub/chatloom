// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// Photos and videos picked together go out as separate messages, in order
/// (no bridge accepts an MSC4274 gallery, see `GalleryContent`), and each
/// carries this marker: one album id, its place and the album's size. Bridges
/// and other clients ignore it; ChatLoom draws the messages as one album
/// however long each upload took (`MediaAlbums`).
///
/// Content: `"pl.personal.chat.album": {"id": "<uuid>", "index": 0, "count": 3}`.
abstract final class MediaAlbumBatch {
  static const key = 'pl.personal.chat.album';

  /// The marker of item [index] of [count] in album [id].
  static Map<String, Object?> content({
    required String id,
    required int index,
    required int count,
  }) => {
    key: {'id': id, 'index': index, 'count': count},
  };

  /// The album id [event] was sent with, or null.
  static String? idOf(Event event) {
    final marker = event.content[key];
    if (marker is! Map) return null;
    final id = marker['id'];
    return id is String && id.isNotEmpty ? id : null;
  }
}

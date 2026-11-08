// SPDX-License-Identifier: AGPL-3.0-or-later

import '../stickers/sticker_media_cache.dart';
import 'avatar_cache.dart';
import 'cache_budget.dart';
import 'media_prefetcher.dart';
import 'protected_matrix_database.dart';
import 'video_file_cache.dart';

enum MediaCacheCategory {
  media('Photos, voice notes & small videos'),
  video('Large videos & reels'),
  avatar('Avatars'),
  sticker('Stickers & GIF previews');

  const MediaCacheCategory(this.label);
  final String label;
}

class MediaCacheUsage {
  const MediaCacheUsage(this.bytes, {required this.outgoingBytes});
  final Map<MediaCacheCategory, int?> bytes;
  final int? outgoingBytes;
  bool get complete => bytes.values.every((value) => value != null);
  int get knownBytes =>
      bytes.values.fold(0, (sum, value) => sum + (value ?? 0));
}

/// Coordinates only replaceable downloaded media. SQLCipher history,
/// encryption keys, the durable outbox and SDK cache:// retry copies are
/// outside the settings actions.
class MediaCacheControls {
  MediaCacheControls({
    required this.databases,
    Future<VideoFileCache?> Function()? video,
    Future<StickerMediaCache?> Function()? avatar,
    Future<StickerMediaCache?> Function()? sticker,
  }) : _video = video ?? VideoFileCache.shared,
       _avatar = avatar ?? AvatarCache.shared,
       _sticker = sticker ?? StickerMediaCache.shared;

  final List<ProtectedMatrixDatabase> databases;
  final Future<VideoFileCache?> Function() _video;
  final Future<StickerMediaCache?> Function() _avatar, _sticker;

  Future<MediaCacheUsage> usage() async {
    int? media, outgoing;
    try {
      media = 0;
      outgoing = 0;
      for (final database in databases.toSet()) {
        final value = await database.mediaCacheUsage();
        media = media! + value.downloaded;
        outgoing = outgoing! + value.outgoing;
      }
    } catch (_) {
      media = outgoing = null;
    }
    Future<int?> measured(Future<int?> Function() read) async {
      try {
        return await read();
      } catch (_) {
        return null;
      }
    }

    // One scan per explicit refresh, never in a build or a sync callback.
    return MediaCacheUsage({
      MediaCacheCategory.media: media,
      MediaCacheCategory.video: await measured(
        () async => (await _video())?.usageBytes(),
      ),
      MediaCacheCategory.avatar: await measured(
        () async => (await _avatar())?.usageBytes(),
      ),
      MediaCacheCategory.sticker: await measured(
        () async => (await _sticker())?.usageBytes(),
      ),
    }, outgoingBytes: outgoing);
  }

  Future<void> applyBudget(MediaCacheBudget budget) async {
    await budget.save();
    for (final database in databases.toSet()) {
      await database.setMediaCacheBudget(budget.mediaBytes);
    }
    await (await _video())?.setBudget(budget.videoBytes);
    await (await _avatar())?.setBudget(budget.avatarBytes);
    await (await _sticker())?.setBudget(budget.stickerBytes);
  }

  Future<void> clear(MediaCacheCategory category) async {
    switch (category) {
      case MediaCacheCategory.media:
        for (final database in databases.toSet()) {
          MediaPrefetcher.cacheCleared(database);
          await database.clearDownloadedMedia();
        }
      case MediaCacheCategory.video:
        final cache = await _video();
        if (cache == null) throw StateError('video_cache_unavailable');
        await cache.clear();
      case MediaCacheCategory.avatar:
        // Revokes avatar loads started before the action as well as the
        // file cache's own inflight requests.
        AvatarCache.cancelPending();
        final cache = await _avatar();
        if (cache == null) throw StateError('avatar_cache_unavailable');
        await cache.clear();
      case MediaCacheCategory.sticker:
        final cache = await _sticker();
        if (cache == null) throw StateError('sticker_cache_unavailable');
        await cache.clear();
    }
  }
}

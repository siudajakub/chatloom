// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/personal/media/instagram_media.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show isMetaShare;

/// A reel, post or story shared from Instagram or Facebook: the bridge's
/// own video (share metadata or link caption) or media loaded from a shared
/// link. Shared reels use the full-screen vertical player.
bool isSharedReel(Event event) =>
    event is InstagramMediaAsset ||
    (!event.redacted && isMetaShare(event.content));

/// Public link of a shared reel for "Open in Instagram", or null. Only an
/// Instagram/Facebook host is ever returned.
Uri? sharedReelLink(Event event) {
  final source = event is InstagramMediaAsset ? event.original : event;
  if (source.redacted) return null;
  final external = source.content['external_url'];
  if (external is String &&
      external.length <= 2048 &&
      isMetaShare({'external_url': external})) {
    return Uri.tryParse(external.trim());
  }
  return InstagramShare.fromText(source.body)?.url;
}

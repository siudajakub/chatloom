// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/avatar_cache.dart';
import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:matrix/matrix.dart';

const notificationAvatarDimension = 128;

extension NotificationAvatarExtension on Client {
  Future<Uint8List?> tryDownloadNotificationAvatar(Uri? avatar) async {
    if (avatar == null) return null;
    try {
      // The in-app avatar cache first: the picture the inbox already shows
      // is on disk, so a notification never waits on a bridge's media.
      final cached = await AvatarCache.loadAvatar(
        this,
        avatar,
        width: notificationAvatarDimension,
        height: notificationAvatarDimension,
        isThumbnail: true,
        animated: false,
        thumbnailMethod: ThumbnailMethod.crop,
      ).timeout(const Duration(seconds: 3));
      // AvatarCache already handles unavailable cache and missing thumbnails.
      // A second thumbnail/original chain would repeat a failed request and
      // bypass its rate-limit handling. Rounding also caps the bitmap decode.
      return await convertToCircularImage(cached, notificationAvatarDimension);
    } on TimeoutException {
      return null;
    } catch (e, s) {
      Logs().e('Unable to get avatar picture', e, s);
      return null;
    }
  }
}

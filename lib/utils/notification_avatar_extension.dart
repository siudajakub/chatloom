// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;

import 'matrix_sdk_extensions/flutter_matrix_dart_sdk_database/builder.dart';

const notificationAvatarDimension = 128;

/// Center-cropped circular PNG of [size] pixels.
Future<Uint8List> _roundedSquare(Uint8List bytes, int size) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    final side = image.width < image.height ? image.width : image.height;
    final source = ui.Rect.fromLTWH(
      (image.width - side) / 2,
      (image.height - side) / 2,
      side.toDouble(),
      side.toDouble(),
    );
    final target = ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..clipPath(ui.Path()..addOval(target))
      ..drawImageRect(
        image,
        source,
        target,
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
    final rounded = await recorder.endRecording().toImage(size, size);
    try {
      final data = await rounded.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      rounded.dispose();
    }
  } finally {
    image.dispose();
  }
}

extension NotificationAvatarExtension on Client {
  Future<Uint8List?> tryDownloadNotificationAvatar(Uri? avatar) async {
    if (avatar == null) return null;
    try {
      try {
        return await downloadMxcCached(
          avatar,
          thumbnailMethod: ThumbnailMethod.crop,
          width: notificationAvatarDimension,
          height: notificationAvatarDimension,
          animated: false,
          isThumbnail: true,
          rounded: true,
        ).timeout(const Duration(seconds: 3));
      } on MatrixException {
        // Some bridge and remote media has no thumbnail; scale the original
        // (a full-size bitmap can exceed Android's notification limits).
        final original = await downloadMxcCached(
          avatar,
        ).timeout(const Duration(seconds: 3));
        return await _roundedSquare(original, notificationAvatarDimension);
      }
    } catch (e, s) {
      Logs().e('Unable to get avatar picture', e, s);
      return null;
    }
  }

  /// Keep in sync with `createAttachment()` in iOS Notification Extension
  /// This loads the avatar for a room and also stores it in a temporary
  /// directory so the Notification Service Extension can access it later.
  Future<String?> getIosNotificationAvatar(Uri? roomAvatar) async {
    if (roomAvatar == null) return null;

    final directory = await getFileStorageLocation();
    if (directory == null) return null;

    final host = roomAvatar.host.replaceAll('.', '_');
    final rawPath = roomAvatar.pathSegments.join('_');
    final fileName = 'notification_${host}_$rawPath.jpg';
    final cachedFile = File(path.join(directory.path, fileName));

    if (!await cachedFile.exists()) {
      final bytes = await tryDownloadNotificationAvatar(roomAvatar);
      if (bytes == null) return null;
      await cachedFile.writeAsBytes(bytes);
    }

    return cachedFile.path;
  }
}

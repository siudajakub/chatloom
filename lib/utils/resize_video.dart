// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/pages/chat/recording_output_cleanup.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:cross_file/cross_file.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

extension ResizeImage on XFile {
  /// The video to send with its size and duration. With [compress] (the
  /// send dialog's switch) it is re-encoded first. The re-encoded copy and
  /// the thumbnail the native codec writes are plaintext files: they are
  /// deleted as soon as their bytes are read.
  Future<MatrixVideoFile> getVideoInfo({bool compress = true}) async {
    MediaInfo? mediaInfo;
    String? destinationPath;
    try {
      if (PlatformInfos.isMobile || PlatformInfos.isMacOS) {
        if (compress) {
          final result = await LightCompressor().compressVideo(
            path: path,
            videoQuality: VideoQuality.medium,
            android: AndroidConfig(isSharedStorage: false),
            ios: IOSConfig(saveInGallery: false),
            video: Video(videoName: name, targetSizeMb: 5),
          );
          if (result is OnFailure) {
            throw result.message;
          }
          if (result is OnSuccess && result.destinationPath != path) {
            destinationPath = result.destinationPath;
          }
        }
        mediaInfo = await LightCompressor().getMediaInfo(
          destinationPath ?? path,
        );
      }
    } catch (e, s) {
      Logs().w('Error while fetching video media info', e, s);
    }

    final compressed = destinationPath;
    try {
      return MatrixVideoFile(
        bytes: compressed != null
            ? await XFile(compressed).readAsBytes()
            : await readAsBytes(),
        name: name,
        mimeType: compressed != null ? lookupMimeType(compressed) : mimeType,
        width: mediaInfo?.width,
        height: mediaInfo?.height,
        duration: mediaInfo?.duration?.inMilliseconds,
      );
    } finally {
      if (compressed != null) await _deleteCodecOutput(compressed);
    }
  }

  Future<MatrixImageFile?> getVideoThumbnail() async {
    if (!PlatformInfos.isMobile) return null;

    String? thumbnailPath;
    try {
      thumbnailPath = await LightCompressor().getVideoThumbnail(path);
      final bytes = await XFile(thumbnailPath).readAsBytes();
      return MatrixImageFile(bytes: bytes, name: name);
    } catch (e, s) {
      Logs().w('Error while compressing video', e, s);
    } finally {
      if (thumbnailPath != null && thumbnailPath != path) {
        await _deleteCodecOutput(thumbnailPath);
      }
    }
    return null;
  }

  /// Removes a file the codec wrote for this send (never the picked video).
  Future<void> _deleteCodecOutput(String output) async {
    if (output == path) return;
    try {
      await cleanupRecordingOutput(ownedNativePath: output);
    } catch (e) {
      Logs().w('Could not remove a temporary video file', e.runtimeType);
    }
  }
}

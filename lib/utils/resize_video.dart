// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/pages/chat/recording_output_cleanup.dart';
import 'package:chatloom/personal/media/media_preparation_exception.dart';
import 'package:chatloom/personal/media/media_quality.dart';
import 'package:chatloom/personal/media/photo_encoder.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

/// A video picked for sending whose bytes are not read yet (MD-05): the
/// bubble shows at once with the file's size, and the bytes are read only
/// when its job prepares it ([PrepareVideo.prepareVideo]).
class PendingVideoFile extends MatrixVideoFile {
  final int declaredSize;

  PendingVideoFile({
    required super.name,
    required this.declaredSize,
    super.mimeType,
  }) : super(bytes: Uint8List(0));

  @override
  int get size => declaredSize;
}

/// One video is compressed at a time (memory, the hardware codec): picking
/// ten clips keeps at most one prepared copy in memory.
Future<void> _videoTail = Future<void>.value();

/// Allows synthetic codec-channel tests on the Linux build host.
@visibleForTesting
bool? debugVideoTranscodeSupported;

/// The handle of one video's preparation, so the "×" on its bubble can
/// stop it (MD-17): the codec is cancelled when this video holds it,
/// otherwise it never starts.
class VideoPrepareJob {
  bool _cancelled = false;
  bool _running = false;

  bool get cancelled => _cancelled;

  Future<void> cancel() async {
    _cancelled = true;
    if (_running) await LightCompressor().cancelCompression();
  }
}

class VideoPrepareCancelled implements Exception {
  const VideoPrepareCancelled();
}

extension PrepareVideo on XFile {
  /// The video to send and its thumbnail, by [MediaQuality]'s profile:
  ///
  /// - the source is probed first (size, rotation, bitrate, frame rate);
  /// - with [compress] it is re-encoded by [profile]: 720p30 H.264 at
  ///   ~2.5 Mbit/s by default, 1080p30 at ~5 Mbit/s for HD, unless it is
  ///   already that lean ([VideoPlan]); a compressor failure leaves the
  ///   send retryable instead of uploading the original without consent;
  /// - width/height are the displayed size (a portrait clip stored rotated
  ///   is announced portrait), with the duration;
  /// - the thumbnail is the first frame at ≤ 800 px JPEG with a blurhash;
  /// - the size is checked against [maxUploadSize] before any bytes are
  ///   read, and only the file actually sent is read.
  ///
  /// The re-encoded copy and the thumbnail the codec writes are plaintext
  /// files: they are deleted as soon as their bytes are read.
  Future<(MatrixVideoFile, MatrixImageFile?)> prepareVideo({
    required bool compress,
    required int maxUploadSize,
    VideoPrepareJob? job,
    MediaProfile profile = MediaProfile.standard,
  }) {
    final run = _videoTail.then(
      (_) => _prepareVideo(compress, maxUploadSize, job, profile),
    );
    _videoTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<(MatrixVideoFile, MatrixImageFile?)> _prepareVideo(
    bool compress,
    int maxUploadSize,
    VideoPrepareJob? job,
    MediaProfile profile,
  ) async {
    if (job?.cancelled ?? false) throw const VideoPrepareCancelled();
    final native =
        (debugVideoTranscodeSupported ??
            PlatformInfos.supportsVideoTranscode) &&
        path.isNotEmpty;
    final sourceSize = await length();
    if (!compress && sourceSize > maxUploadSize) {
      throw FileTooBigMatrixException(sourceSize, maxUploadSize);
    }
    MediaInfo? source;
    if (native) {
      try {
        source = await LightCompressor().getMediaInfo(path);
      } catch (e) {
        Logs().w('Video could not be probed', e.runtimeType);
      }
    }
    if (job?.cancelled ?? false) throw const VideoPrepareCancelled();
    if (compress &&
        sourceSize > MediaQuality.videoSmallBytes &&
        (!native ||
            source == null ||
            (source.width ?? 0) <= 0 ||
            (source.height ?? 0) <= 0)) {
      throw const MediaPreparationException();
    }
    final plan = compress && source != null
        ? VideoPlan.decide(
            width: source.width,
            height: source.height,
            durationMs: source.duration?.inMilliseconds,
            bytes: sourceSize,
            bitrate: source.bitrate,
            frameRate: source.frameRate,
            mimeType: source.mimeType ?? mimeType ?? lookupMimeType(path),
            profile: profile,
          )
        : VideoPlan.keep;
    String? output;
    var info = source;
    try {
      if (!plan.skip) {
        output = await _compress(plan, job);
        final outputSize = await XFile(output).length();
        if (outputSize <= 0 || outputSize >= sourceSize) {
          throw const MediaPreparationException();
        }
        try {
          info = await LightCompressor().getMediaInfo(output);
        } catch (_) {
          // The source's dimensions would incorrectly advertise 4K
          // after a 720p encode. Keep the planned stored frame size.
          info = MediaInfo(
            width: plan.width,
            height: plan.height,
            duration: source?.duration,
            rotation: source?.rotation,
            mimeType: 'video/mp4',
          );
        }
      }
      if (job?.cancelled ?? false) throw const VideoPrepareCancelled();
      final sendPath = output ?? path;
      final sendSize = output == null
          ? sourceSize
          : await XFile(output).length();
      if (sendSize > maxUploadSize) {
        throw FileTooBigMatrixException(sendSize, maxUploadSize);
      }
      final (width, height) = displaySize(
        info?.width,
        info?.height,
        info?.rotation,
      );
      final thumbnail = native ? await _thumbnail(sendPath) : null;
      if (job?.cancelled ?? false) throw const VideoPrepareCancelled();
      final bytes = output == null
          ? await readAsBytes()
          : await XFile(output).readAsBytes();
      if (job?.cancelled ?? false) throw const VideoPrepareCancelled();
      return (
        MatrixVideoFile(
          bytes: bytes,
          name: output == null ? name : _mp4Name(name),
          mimeType: output == null
              ? (mimeType ?? lookupMimeType(path))
              : 'video/mp4',
          width: width,
          height: height,
          duration: (info?.duration ?? source?.duration)?.inMilliseconds,
        ),
        thumbnail,
      );
    } finally {
      if (output != null) await _deleteCodecOutput(output);
    }
  }

  /// The re-encoded copy's path. Failure never uploads the original.
  Future<String> _compress(VideoPlan plan, VideoPrepareJob? job) async {
    job?._running = true;
    try {
      final result = await LightCompressor().compressVideo(
        path: path,
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(isSharedStorage: false),
        ios: IOSConfig(saveInGallery: false),
        audio: plan.profile == MediaProfile.economy
            ? AudioConfig(bitrate: plan.profile.videoAudioBitrate)
            : null,
        // A lean source would otherwise fail; the plan already decided.
        isMinBitrateCheckEnabled: false,
        video: Video(
          // Unique: macOS writes `<name>.mp4` into the temporary directory.
          videoName: 'chatloom-${DateTime.now().microsecondsSinceEpoch}',
          videoWidth: plan.width,
          videoHeight: plan.height,
          targetSizeMb: plan.targetSizeMb,
          videoFps: plan.fps,
        ),
      );
      if (result is OnCancelled || (job?.cancelled ?? false)) {
        if (result is OnSuccess && result.destinationPath != path) {
          await _deleteCodecOutput(result.destinationPath);
        }
        throw const VideoPrepareCancelled();
      }
      if (result is OnSuccess && result.destinationPath != path) {
        return result.destinationPath;
      }
      throw const MediaPreparationException();
    } on VideoPrepareCancelled {
      rethrow;
    } on MediaPreparationException {
      rethrow;
    } catch (e) {
      if (job?.cancelled ?? false) throw const VideoPrepareCancelled();
      Logs().w('Video compression failed', e.runtimeType);
      throw const MediaPreparationException();
    } finally {
      job?._running = false;
    }
  }

  Future<MatrixImageFile?> _thumbnail(String videoPath) async {
    String? thumbnailPath;
    try {
      thumbnailPath = await LightCompressor().getVideoThumbnail(
        videoPath,
        quality: 90,
      );
      final frame = await XFile(thumbnailPath).readAsBytes();
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      // The codec's full-resolution frame, shrunk like a photo thumbnail.
      final small = await encodePhoto(
        MatrixImageFileResizeArguments(
          bytes: frame,
          maxDimension: MediaQuality.thumbnailMaxSide,
          fileName: '$base.thumbnail.jpg',
          calcBlurhash: true,
        ),
      );
      // An unreadable frame is optional; never attach the full-size source
      // frame as a thumbnail when the resizer cannot process it.
      if (small == null ||
          small.width > MediaQuality.thumbnailMaxSide ||
          small.height > MediaQuality.thumbnailMaxSide) {
        return null;
      }
      return MatrixImageFile(
        bytes: small.bytes,
        name: '$base.thumbnail.jpg',
        mimeType: small.mimeType ?? 'image/jpeg',
        width: small.width,
        height: small.height,
        blurhash: small.blurhash,
      );
    } catch (e) {
      Logs().w('Video thumbnail failed', e.runtimeType);
      return null;
    } finally {
      if (thumbnailPath != null && thumbnailPath != path) {
        await _deleteCodecOutput(thumbnailPath);
      }
    }
  }

  static String _mp4Name(String name) {
    final dot = name.lastIndexOf('.');
    return '${dot > 0 ? name.substring(0, dot) : name}.mp4';
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

// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import '../media/media_access.dart';

/// Validated, physically cropped media. Keep its lease open until the encrypted
/// pending-media store has committed both video and thumbnail successfully.
class PreparedRoundMedia {
  final ManagedMediaFile managedFile;
  final String? thumbnailPath;
  final int durationMs;
  final int width;
  final int height;
  final int sizeBytes;
  final String videoCodec;
  final String audioCodec;
  final bool cornersSanitized;
  final bool fastStart;

  const PreparedRoundMedia({
    required this.managedFile,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.videoCodec,
    required this.audioCodec,
    required this.cornersSanitized,
    required this.fastStart,
    this.thumbnailPath,
  });

  String get path => managedFile.file.path;
  Future<Uint8List> readBytes() => managedFile.file.readAsBytes();
  Future<Uint8List?> readThumbnailBytes() async =>
      thumbnailPath == null ? null : File(thumbnailPath!).readAsBytes();
  Future<void> close() => managedFile.close();

  /// Native output is accepted only with its verified descriptor. This also
  /// prevents an accidental ordinary-video path being labelled as a round.
  factory PreparedRoundMedia.fromNative(
    Map<Object?, Object?> result,
    ManagedMediaFile lease, {
    required int maxBytes,
    required int maxDurationMs,
    required int maxSide,
  }) {
    final width = result['width'];
    final height = result['height'];
    final duration = result['durationMs'];
    final size = result['sizeBytes'];
    final outputPath = result['path'];
    final thumb = result['thumbnailPath'];
    if (width is! int ||
        height is! int ||
        duration is! int ||
        size is! int ||
        width <= 0 ||
        width > maxSide ||
        width != height ||
        duration < 800 ||
        duration > maxDurationMs ||
        size <= 0 ||
        size > maxBytes ||
        result['videoCodec'] != 'h264' ||
        result['audioCodec'] != 'aac' ||
        result['cornersSanitized'] != true ||
        result['fastStart'] != true ||
        outputPath != lease.file.path ||
        (thumb != null && thumb != '${lease.writableDirectory}/thumb.jpg')) {
      throw const RoundCaptureException('invalid_output');
    }
    return PreparedRoundMedia(
      managedFile: lease,
      thumbnailPath: thumb as String?,
      durationMs: duration,
      width: width,
      height: height,
      sizeBytes: size,
      videoCodec: 'h264',
      audioCodec: 'aac',
      cornersSanitized: true,
      fastStart: true,
    );
  }

  @override
  String toString() => 'PreparedRoundMedia(protected lease)';
}

class RoundCaptureException implements Exception {
  final String code;
  const RoundCaptureException(this.code);
  @override
  String toString() => 'RoundCaptureException($code)';
}

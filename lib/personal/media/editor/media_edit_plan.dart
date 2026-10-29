// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Pure decisions of the media editor (`photo_editor_page.dart`,
/// `video_editor_page.dart`), kept free of the editor packages so they can be
/// unit-tested without a device codec.

/// What an edited photo is saved as: an opaque photo as JPEG q92 (visually
/// lossless; an edited 12 MP photo as PNG was ~20 MB, MD-20), a photo with
/// transparency as PNG. The send pipeline re-encodes it by the chosen
/// [MediaProfile] afterwards, like any picked photo.
enum EditedPhotoFormat {
  jpeg('image/jpeg', 'jpg'),
  png('image/png', 'png');

  final String mimeType;
  final String extension;
  const EditedPhotoFormat(this.mimeType, this.extension);

  static EditedPhotoFormat of({required bool hasAlpha}) =>
      hasAlpha ? png : jpeg;
}

/// JPEG quality of an edited photo before the send pipeline's own encode.
const int editedPhotoJpegQuality = 92;

/// The longest side an edited photo keeps (a 48 MP 8064 px photo is capped;
/// 12 MP phone photos keep their full size).
const double editedPhotoMaxSide = 4096;

/// The shortest clip the trim handles allow.
const Duration minTrimLength = Duration(seconds: 1);

/// `photo.jpg` edited as PNG becomes `photo.png`; a name without an
/// extension gains one.
String editedFileName(String original, String extension) {
  final dot = original.lastIndexOf('.');
  final base = dot > 0 ? original.substring(0, dot) : original;
  return '${base.isEmpty ? 'edited' : base}.$extension';
}

/// The crop of an edited video in source pixels, as the editor reports it.
@immutable
class VideoCrop {
  final int x, y, width, height;

  /// Clockwise quarter turns applied after the crop.
  final int quarterTurns;
  final bool flipX, flipY;

  const VideoCrop({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.quarterTurns = 0,
    this.flipX = false,
    this.flipY = false,
  });

  /// The size the video is shown at after the crop and rotation.
  Size get outputSize => quarterTurns.isOdd
      ? Size(height.toDouble(), width.toDouble())
      : Size(width.toDouble(), height.toDouble());

  @override
  bool operator ==(Object other) =>
      other is VideoCrop &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.quarterTurns == quarterTurns &&
      other.flipX == flipX &&
      other.flipY == flipY;

  @override
  int get hashCode =>
      Object.hash(x, y, width, height, quarterTurns, flipX, flipY);
}

/// What the video editor's Done asks for, reduced to what is rendered.
@immutable
class VideoEditPlan {
  final Duration duration;

  /// The kept span; null ends mean the clip's own start or end.
  final Duration? start, end;
  final VideoCrop? crop;
  final bool muted;

  const VideoEditPlan({
    required this.duration,
    this.start,
    this.end,
    this.crop,
    this.muted = false,
  });

  /// Trim ends closer than this to the clip's own start/end are no trim:
  /// the editor's trim bar snaps to frames, not to exactly zero.
  static const Duration _slack = Duration(milliseconds: 50);

  Duration get keptStart =>
      start == null || start! <= _slack ? Duration.zero : start!;

  Duration get keptEnd => end == null || end! >= duration - _slack
      ? duration
      : (end! < keptStart ? keptStart : end!);

  Duration get keptLength => keptEnd - keptStart;

  bool get trimmed => keptStart > Duration.zero || keptEnd < duration;

  bool get cropped => crop != null;

  /// Nothing to render: Done then keeps the picked file as it is.
  bool get isUnchanged => !trimmed && !cropped && !muted;

  /// The render's start/end, or null for "from the start" / "to the end",
  /// so an untrimmed side is never cut a frame short.
  Duration? get renderStart => keptStart > Duration.zero ? keptStart : null;
  Duration? get renderEnd => keptEnd < duration ? keptEnd : null;
}

/// `0:07`, `1:05`, `1:02:03`, from whole seconds (rounded down, so a 59.6 s
/// clip never reads one minute).
String formatClipLength(Duration duration) {
  final total = duration.isNegative ? 0 : duration.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

/// One selection tick when a trim handle reaches a bound (the clip's start,
/// its end, or the shortest allowed length), never once per frame while it
/// rests there.
class TrimEdgeTracker {
  final Duration duration;
  final Duration minLength;
  bool _atStart = false, _atEnd = false, _atMin = false;

  TrimEdgeTracker({required this.duration, this.minLength = minTrimLength});

  static const Duration _slack = Duration(milliseconds: 60);

  /// Whether this update newly touched a bound.
  bool update(Duration start, Duration end) {
    final atStart = start <= _slack;
    final atEnd = end >= duration - _slack;
    final atMin = end - start <= minLength + _slack;
    final hit =
        (atStart && !_atStart) || (atEnd && !_atEnd) || (atMin && !_atMin);
    _atStart = atStart;
    _atEnd = atEnd;
    _atMin = atMin;
    return hit;
  }

  /// A new drag starts from the bounds the span already touches.
  void reset(Duration start, Duration end) {
    _atStart = start <= _slack;
    _atEnd = end >= duration - _slack;
    _atMin = end - start <= minLength + _slack;
  }
}

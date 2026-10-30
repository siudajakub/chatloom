// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui';

import 'package:chatloom/personal/media/media_quality.dart';
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

/// The step `pro_image_editor`'s trim bar reports while a handle moves: it
/// rounds the span down to whole seconds (only the drag's end is exact).
const Duration trimBarStep = Duration(seconds: 1);

/// The longest side the video editor's stage works at. The editor paints a
/// transparent PNG of this size behind the video (and decodes another one
/// in Crop): a 4K source at full size costs ~33 MB per image. The crop it
/// reports is scaled back to the source ([VideoCrop.toSource]).
const double videoStageMaxSide = 1920;

/// The stage size for a video shown at [resolution] (rotation applied):
/// the same aspect, the long side at most [videoStageMaxSide].
Size videoStageSize(Size resolution) {
  final longSide = resolution.longestSide;
  if (longSide <= videoStageMaxSide) return resolution;
  final scale = videoStageMaxSide / longSide;
  return Size(
    math.max(1, (resolution.width * scale).roundToDouble()),
    math.max(1, (resolution.height * scale).roundToDouble()),
  );
}

/// An edit that must re-encode is rendered straight at the HD send
/// profile's ceiling (1080p30), so an HD send can keep it as it is
/// ([VideoPlan] skips a 1080p30 MP4 under 6.5 Mbit/s): one encode instead
/// of two, and an encode every phone supports (a 4K60 H.264 encode is not).
const int editedVideoMaxSide = MediaQuality.videoHdMaxSide;
const int editedVideoMaxFps = MediaQuality.videoMaxFps;

/// Above the HD target (5 Mbit/s) so the standard profile's own encode
/// still starts from a clean picture, under the HD skip (6.5 Mbit/s with
/// the audio).
const int editedVideoBitrate = 5500 * 1000;

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

  /// This crop, made on a stage [factor] times smaller than [source] (see
  /// [videoStageSize]), in the source's pixels and inside its frame.
  VideoCrop toSource(double factor, Size source) {
    if (factor == 1) return this;
    final sourceWidth = math.max(1, source.width.round());
    final sourceHeight = math.max(1, source.height.round());
    final left = (x * factor).round().clamp(0, sourceWidth - 1);
    final top = (y * factor).round().clamp(0, sourceHeight - 1);
    return VideoCrop(
      x: left,
      y: top,
      width: (width * factor).round().clamp(1, sourceWidth - left),
      height: (height * factor).round().clamp(1, sourceHeight - top),
      quarterTurns: quarterTurns,
      flipX: flipX,
      flipY: flipY,
    );
  }

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

  /// Whether the render has to decode and encode the picture: a crop does,
  /// and so does a later start (Media3 cannot start a copy between key
  /// frames). Only the end trimmed, or only the sound removed, the samples
  /// can be copied as they are.
  bool get reencodes => cropped || renderStart != null;
}

/// How an edit is rendered, before the send pipeline compresses it by the
/// chosen profile like any picked video.
@immutable
class VideoRenderTarget {
  /// The uniform scale of the (cropped) frame; null keeps its size.
  final double? scale;

  /// The video bitrate; null leaves it to the encoder, or lets Media3 copy
  /// the samples when nothing has to be re-encoded.
  final int? bitrate;

  /// Frames above this rate are dropped; null keeps the source's rate.
  final int? maxFrameRate;

  /// The size the result is shown at (crop, rotation and scale applied).
  final Size outputSize;

  const VideoRenderTarget({
    required this.outputSize,
    this.scale,
    this.bitrate,
    this.maxFrameRate,
  });

  /// [source] is the shown resolution (rotation applied), [sourceBitrate]
  /// in bit/s (0 when unknown). [keepQuality]: the video goes out as a file,
  /// so a re-encode keeps the source's size and bitrate; above 1080p it
  /// drops to 30 fps (a 4K60 H.264 encode is what many phones reject).
  factory VideoRenderTarget.of(
    VideoEditPlan plan, {
    required Size source,
    required int sourceBitrate,
    bool keepQuality = false,
  }) {
    final frame = plan.crop?.outputSize ?? source;
    // Copied, not encoded: the send profile's own encode is the only one.
    if (!plan.reencodes) return VideoRenderTarget(outputSize: frame);
    if (keepQuality) {
      return VideoRenderTarget(
        outputSize: frame,
        bitrate: sourceBitrate > 0 ? sourceBitrate : null,
        maxFrameRate: frame.longestSide > editedVideoMaxSide
            ? editedVideoMaxFps
            : null,
      );
    }
    return VideoRenderTarget.hd(
      plan,
      source: source,
      sourceBitrate: sourceBitrate,
    );
  }

  /// The HD send profile's ceiling: 1080p30 at most [editedVideoBitrate].
  /// Also the second try when the device's encoder rejects a full-quality
  /// render.
  factory VideoRenderTarget.hd(
    VideoEditPlan plan, {
    required Size source,
    required int sourceBitrate,
  }) {
    final frame = plan.crop?.outputSize ?? source;
    final longSide = frame.longestSide;
    final scale = longSide > editedVideoMaxSide
        ? editedVideoMaxSide / longSide
        : null;
    return VideoRenderTarget(
      outputSize: scale == null ? frame : frame * scale,
      scale: scale,
      bitrate: sourceBitrate > 0
          ? math.min(sourceBitrate, editedVideoBitrate)
          : editedVideoBitrate,
      maxFrameRate: editedVideoMaxFps,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VideoRenderTarget &&
      other.scale == scale &&
      other.bitrate == bitrate &&
      other.maxFrameRate == maxFrameRate &&
      other.outputSize == outputSize;

  @override
  int get hashCode => Object.hash(scale, bitrate, maxFrameRate, outputSize);
}

/// [message] without file paths, URIs or media file names: a source's
/// file name can carry a contact's or a chat's name, and native errors
/// quote the paths they failed on. A path is any word with a `/` (absolute
/// or relative) and runs to the next `:`, `,`, quote or bracket, spaces
/// included (file names have them); a bare name with a media extension
/// takes its whole segment, since where a spaced name starts is unknown.
/// MIME types (`video/avc`, `audio/mp4a-latm`) stay.
String redactMediaPaths(String message) => message
    .replaceAll(_uri, '<path>')
    .replaceAll(_pathWord, '<path>')
    .replaceAllMapped(_mediaName, (match) => '${match[1]}<path>');

final _uri = RegExp(r'''[a-zA-Z][a-zA-Z0-9+.-]*://[^\n,;'"()\[\]]*''');

/// A word with a slash, from where the word starts, unless it is a MIME
/// type.
final _pathWord = RegExp(
  r'''(?<![^\s'"(\[=,:;])'''
  r'''(?!(?:video|audio|image|application|text)/[\w.+-]+(?![^\s,;:'"()\[\]]))'''
  r'''[^\s'"()\[\],;:]*/[^\n,;:'"()\[\]]*''',
);

final _mediaName = RegExp(
  r'''(\s*)[^\n:,;'"()\[\]]*?\.'''
  r'''(?:mp4|m4v|mov|3gp|3g2|mkv|webm|avi|jpe?g|png|gif|webp|heic|heif|'''
  r'''mp3|m4a|aac|ogg|oga|opus|wav|flac|amr)(?!\w)''',
  caseSensitive: false,
);

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

  /// The resolution of the reported span: a bound is touched within one
  /// step of it. [trimBarStep] for the package's trim bar, whose readout
  /// never reaches a clip end that falls between whole seconds.
  final Duration step;
  bool _atStart = false, _atEnd = false, _atMin = false;

  TrimEdgeTracker({
    required this.duration,
    this.minLength = minTrimLength,
    this.step = const Duration(milliseconds: 60),
  });

  bool _isAtStart(Duration start) => start < step;
  bool _isAtEnd(Duration end) => end > duration - step;
  bool _isAtMin(Duration start, Duration end) => end - start < minLength + step;

  /// Whether this update newly touched a bound.
  bool update(Duration start, Duration end) {
    final atStart = _isAtStart(start);
    final atEnd = _isAtEnd(end);
    final atMin = _isAtMin(start, end);
    final hit =
        (atStart && !_atStart) || (atEnd && !_atEnd) || (atMin && !_atMin);
    _atStart = atStart;
    _atEnd = atEnd;
    _atMin = atMin;
    return hit;
  }

  /// A new drag starts from the bounds the span already touches.
  void reset(Duration start, Duration end) {
    _atStart = _isAtStart(start);
    _atEnd = _isAtEnd(end);
    _atMin = _isAtMin(start, end);
  }
}

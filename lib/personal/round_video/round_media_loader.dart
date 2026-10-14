// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:personal_core/personal_core.dart';

import '../media/media_access.dart';

typedef RoundAttachmentDownload =
    Future<MatrixFile> Function(
      Event event, {
      required bool cacheAttachment,
      void Function(int)? onDownloadProgress,
    });

typedef RoundThumbnailDownload =
    Future<MatrixFile> Function(
      Event event, {
      void Function(int)? onDownloadProgress,
    });

class RoundMediaUnavailable implements Exception {
  final String reason;
  const RoundMediaUnavailable(this.reason);
  @override
  String toString() => 'RoundMediaUnavailable';
}

class RoundMediaCancellation {
  bool _cancelled = false;
  final bool Function()? sourceValid;
  RoundMediaCancellation({this.sourceValid});
  bool get valid => !_cancelled && (sourceValid?.call() ?? true);
  void cancel() => _cancelled = true;
}

/// All playback bytes come through Matrix SDK decryption, never a raw MXC URL.
/// Limited media is rejected before thumbnail, cache or download access.
class RoundMediaLoader {
  static const maxMediaBytes = 64 * 1024 * 1024;
  static const maxThumbnailBytes = 2 * 1024 * 1024;
  final RoundAttachmentDownload _download;
  final RoundThumbnailDownload _thumbnail;
  final Future<MediaAccess> Function() _access;
  static Future<MediaAccess>? _sharedAccess;

  RoundMediaLoader({
    RoundAttachmentDownload? download,
    RoundThumbnailDownload? thumbnailDownload,
    Future<MediaAccess> Function()? mediaAccess,
  }) : _download = download ?? _sdkDownload,
       _thumbnail = thumbnailDownload ?? _sdkThumbnail,
       _access = mediaAccess ?? _defaultAccess;

  static Future<MatrixFile> _sdkDownload(
    Event event, {
    required bool cacheAttachment,
    void Function(int)? onDownloadProgress,
  }) => event.downloadAndDecryptAttachment(
    cacheAttachment: cacheAttachment,
    onDownloadProgress: onDownloadProgress,
  );

  static Future<MatrixFile> _sdkThumbnail(
    Event event, {
    void Function(int)? onDownloadProgress,
  }) => event.downloadAndDecryptAttachment(
    getThumbnail: true,
    cacheAttachment: false,
    onDownloadProgress: onDownloadProgress,
  );

  static Future<MediaAccess> _defaultAccess() {
    final existing = _sharedAccess;
    if (existing != null) return existing;
    late final Future<MediaAccess> opening;
    opening =
        (() async {
          final temp = await getTemporaryDirectory();
          return MediaAccess.open(
            directory: Directory('${temp.path}/personal_round'),
          );
        })().catchError((Object error, StackTrace stack) {
          if (identical(_sharedAccess, opening)) _sharedAccess = null;
          Error.throwWithStackTrace(error, stack);
        });
    return _sharedAccess = opening;
  }

  static int? _declaredSize(Object? size, int limit) {
    if (size == null) return null;
    if (size is! int || size < 0) {
      throw const RoundMediaUnavailable('invalidMediaSize');
    }
    _boundBytes(size, limit);
    return size;
  }

  static void _boundBytes(int bytes, int limit) {
    if (bytes < 0 || bytes > limit) {
      throw const RoundMediaUnavailable('mediaSizeLimit');
    }
  }

  static RoundMediaPolicy policyFor(Event event) =>
      RoundMediaPolicy.fromContent(event.content);
  static bool isRound(Event event) =>
      event.type == EventTypes.Message &&
      RoundVideoDescriptor.fromContent(
            event.content,
            redacted: event.redacted,
          ) !=
          null;

  static void _guard(
    Event event,
    RoundMediaCancellation? cancellation, {
    bool voice = false,
  }) {
    if (cancellation?.valid == false) {
      throw const RoundMediaUnavailable('cancelled');
    }
    if (event.redacted ||
        (voice
            ? event.type != EventTypes.Message ||
                  event.messageType != MessageTypes.Audio
            : !isRound(event))) {
      throw const RoundMediaUnavailable('sourceUnavailable');
    }
    final policy = policyFor(event);
    if (!policy.canPlay) {
      throw RoundMediaUnavailable(policy.placeholderReason!);
    }
  }

  Future<Uint8List?> thumbnail(
    Event event, {
    RoundMediaCancellation? cancellation,
  }) async {
    _guard(event, cancellation);
    if (!policyFor(event).canPersist || !event.hasThumbnail) return null;
    _declaredSize(event.thumbnailInfoMap['size'], maxThumbnailBytes);
    RoundMediaUnavailable? failedProgress;
    final file = await _thumbnail(
      event,
      onDownloadProgress: (bytes) {
        try {
          _guard(event, cancellation);
          _boundBytes(bytes, maxThumbnailBytes);
        } on RoundMediaUnavailable catch (error) {
          failedProgress = error;
          rethrow;
        }
      },
    );
    // Scanners/local cache may not publish progress. Always check final bytes;
    // a download adapter swallowing a progress exception cannot bypass a limit.
    if (failedProgress != null) throw failedProgress!;
    _guard(event, cancellation);
    _boundBytes(file.bytes.lengthInBytes, maxThumbnailBytes);
    return file.bytes.isEmpty ? null : file.bytes;
  }

  Future<RoundLoadedMedia> load(
    Event event, {
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) => _load(event, cancellation: cancellation, onProgress: onProgress);

  Future<RoundLoadedMedia> loadVoice(
    Event event, {
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) => _load(
    event,
    voice: true,
    cancellation: cancellation,
    onProgress: onProgress,
  );

  Future<RoundLoadedMedia> _load(
    Event event, {
    bool voice = false,
    RoundMediaCancellation? cancellation,
    void Function(double?)? onProgress,
  }) async {
    _guard(event, cancellation, voice: voice);
    final policy = policyFor(event);
    final rawSize = event.infoMap['size'];
    final size = _declaredSize(rawSize, maxMediaBytes);
    RoundMediaUnavailable? failedProgress;
    final file = await _download(
      event,
      cacheAttachment: policy.canPersist,
      onDownloadProgress: (bytes) {
        try {
          _guard(event, cancellation, voice: voice);
          _boundBytes(bytes, maxMediaBytes);
        } on RoundMediaUnavailable catch (error) {
          failedProgress = error;
          rethrow;
        }
        onProgress?.call(
          size != null && size > 0 ? (bytes / size).clamp(0.0, 1.0) : null,
        );
      },
    );
    if (failedProgress != null) throw failedProgress!;
    _guard(event, cancellation, voice: voice);
    _boundBytes(file.bytes.lengthInBytes, maxMediaBytes);
    if (file.bytes.isEmpty) throw const RoundMediaUnavailable('emptyMedia');
    if (kIsWeb) {
      return RoundLoadedMedia.web(
        Uri.dataFromBytes(file.bytes, mimeType: file.mimeType),
      );
    }
    final access = await _access();
    _guard(event, cancellation, voice: voice);
    final extension = !voice
        ? '.mp4'
        : switch (file.mimeType.toLowerCase()) {
            'audio/ogg' => '.ogg',
            'audio/mpeg' => '.mp3',
            'audio/wav' => '.wav',
            'audio/mp4' => '.m4a',
            _ => '.bin',
          };
    final lease = await access.create(file.bytes, extension: extension);
    try {
      _guard(event, cancellation, voice: voice);
      return RoundLoadedMedia.native(lease);
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }
}

class RoundLoadedMedia {
  final ManagedMediaFile? lease;
  final Uri? dataUri;
  bool _closed = false;
  RoundLoadedMedia.native(ManagedMediaFile file) : lease = file, dataUri = null;
  RoundLoadedMedia.web(Uri uri) : dataUri = uri, lease = null;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await lease?.close();
  }

  @override
  String toString() => 'RoundLoadedMedia(managed)';
}

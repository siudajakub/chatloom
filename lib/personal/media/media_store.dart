// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chatloom/personal/media/media_access.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';

/// Where a one-tap "Save" puts a file on Android (Telegram, WhatsApp):
/// photos in `Pictures/ChatLoom`, videos in `Movies/ChatLoom`, everything
/// else in `Download/ChatLoom`. Photos and videos show up in Google Photos.
enum MediaStoreCollection {
  images('Pictures/ChatLoom'),
  video('Movies/ChatLoom'),
  downloads('Download/ChatLoom');

  const MediaStoreCollection(this.relativePath);

  /// Folder under shared storage (MediaStore `RELATIVE_PATH`).
  final String relativePath;

  /// The inline confirmation after a save.
  String get savedMessage => switch (this) {
    images || video => 'Saved to gallery',
    downloads => 'Saved to Downloads',
  };

  /// Menu label of the one-tap save.
  String get actionLabel => switch (this) {
    images || video => 'Save to gallery',
    downloads => 'Save to Downloads',
  };
}

/// Android MediaStore export through `MediaStorePlugin.kt`: no storage
/// permission on Android 10+ (Pixel 8: Android 14+). The decrypted bytes
/// go straight into the user's chosen collection; nothing else is written,
/// except that a large file passes through one short-lived private
/// [MediaAccess] lease (deleted right after the copy) instead of the method
/// channel, which would copy it several times in memory.
abstract final class MediaStore {
  static const channel = MethodChannel('pl.personal.chat/media_store');

  /// Larger files go through a private lease path instead of the channel.
  static const int inlineBytesLimit = 8 * 1024 * 1024;

  /// Collection for a file with [mimeType] (sniffed from [name] when the
  /// event did not say). MediaStore rejects a MIME type outside the
  /// collection, so only real `image/*` / `video/*` types go to the gallery.
  static MediaStoreCollection collectionFor({
    required String? mimeType,
    String? name,
  }) {
    final type = _effectiveMime(mimeType, name);
    if (type.startsWith('image/')) return MediaStoreCollection.images;
    if (type.startsWith('video/')) return MediaStoreCollection.video;
    return MediaStoreCollection.downloads;
  }

  static String _effectiveMime(String? mimeType, String? name) {
    final given = mimeType?.trim().toLowerCase() ?? '';
    if (given.isNotEmpty && given != 'application/octet-stream') return given;
    return (name == null ? null : lookupMimeType(name)) ?? given;
  }

  /// Saves [file] into its collection. Returns the collection, or null when
  /// this device has no MediaStore export (Android 9 and older, missing
  /// plugin): the caller then offers the system "Save as" dialog. Throws on
  /// a real failure (storage full, MediaStore error).
  static Future<MediaStoreCollection?> save(
    MatrixFile file, {
    @visibleForTesting
    Future<ManagedMediaFile> Function(Uint8List bytes, String extension)? lease,
  }) async {
    final collection = collectionFor(mimeType: file.mimeType, name: file.name);
    final displayName = exportFileName(file.name, file.mimeType);
    final mimeType = switch (collection) {
      MediaStoreCollection.downloads => _downloadsMime(file),
      _ => _effectiveMime(file.mimeType, file.name),
    };
    final arguments = <String, Object?>{
      'displayName': displayName,
      'mimeType': mimeType,
      'collection': collection.name,
    };
    ManagedMediaFile? leased;
    try {
      if (file.bytes.lengthInBytes > inlineBytesLimit) {
        leased = await (lease ?? _defaultLease)(
          file.bytes,
          fileExtension(displayName),
        );
        arguments['path'] = leased.file.path;
      } else {
        arguments['bytes'] = file.bytes;
      }
      final saved = await channel.invokeMethod<bool>(
        'saveToCollection',
        arguments,
      );
      return saved == true ? collection : null;
    } on MissingPluginException {
      return null;
    } finally {
      await leased?.close();
    }
  }

  static String _downloadsMime(MatrixFile file) {
    final type = _effectiveMime(file.mimeType, file.name);
    return type.isEmpty ? 'application/octet-stream' : type;
  }

  static Future<ManagedMediaFile> _defaultLease(
    Uint8List bytes,
    String extension,
  ) async {
    final access = await MediaAccess.open(
      directory: Directory(
        '${(await getTemporaryDirectory()).path}/personal_media',
      ),
    );
    return access.create(bytes, extension: extension);
  }
}

/// [name] with an extension that matches [mimeType] (bridges often send
/// "photo" or a caption-free body without one), safe as a file name. The
/// system save dialogs and MediaStore both use it.
String exportFileName(String? name, String? mimeType) {
  var base = (name ?? '').split(RegExp(r'[\\/]')).last.trim();
  base = base.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_');
  if (base.isEmpty || base == '.' || base == '..') base = 'file';
  if (base.length > 120) base = base.substring(base.length - 120);
  final dot = base.lastIndexOf('.');
  final hasExtension = dot > 0 && dot < base.length - 1;
  if (hasExtension) return base;
  final extension = mimeType == null || mimeType.isEmpty
      ? null
      : extensionFromMime(mimeType);
  if (extension == null || extension.isEmpty) return base;
  return '$base.$extension';
}

/// Lower-case extension of [name] (with the dot) that a [MediaAccess] lease
/// accepts, `.bin` otherwise.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '.bin';
  final extension = name.substring(dot).toLowerCase();
  return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension) ? extension : '.bin';
}

/// The user's real `~/Downloads` for a macOS save panel. In the App Sandbox
/// `HOME` is the app container (`~/Library/Containers/<id>/Data`), whose
/// Downloads is only a link; the panel starts in the real folder.
String? macDownloadsDirectory(String? home) {
  if (home == null || home.isEmpty) return null;
  final container = home.indexOf('/Library/Containers/');
  final real = container > 0 ? home.substring(0, container) : home;
  return '$real/Downloads';
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

import 'sticker_library.dart';
import 'sticker_pack_import.dart';

/// Where the account's own pack lives. Production uses
/// [MatrixOwnPackBackend]; tests use a fake.
abstract interface class OwnPackBackend {
  /// The account data type holding the pack and its content, or null
  /// content when there is no pack yet.
  (String, Map<String, Object?>?) read();
  Future<void> write(String type, Map<String, Object?> content);

  /// Uploads [bytes] to the media repository (unencrypted, like every
  /// sticker pack: account data is not end-to-end encrypted either).
  Future<Uri> upload(Uint8List bytes, String filename, String mimetype);
}

class MatrixOwnPackBackend implements OwnPackBackend {
  MatrixOwnPackBackend(this.client, {this.library});
  final Client client;
  final StickerLibrary? library;

  /// The stable type when the account already has it (the library reads it
  /// first), else the unstable one most Matrix apps read.
  @override
  (String, Map<String, Object?>?) read() {
    for (final type in [userImagePackType, unstableUserImagePackType]) {
      final content = client.accountData[type]?.content;
      if (content != null && content['images'] is Map) return (type, content);
    }
    return (unstableUserImagePackType, null);
  }

  @override
  Future<void> write(String type, Map<String, Object?> content) async {
    final userId = client.userID;
    if (userId == null) throw StateError('Not signed in');
    await client.setAccountData(userId, type, content);
    // Shown at once; the sync echo replaces it with the same content.
    client.accountData[type] = BasicEvent(type: type, content: content);
    library?.refresh();
  }

  @override
  Future<Uri> upload(Uint8List bytes, String filename, String mimetype) =>
      client.uploadContent(bytes, filename: filename, contentType: mimetype);
}

/// One image the user picked for their pack.
@immutable
class OwnStickerInput {
  const OwnStickerInput({required this.bytes, required this.name, this.emoji});

  final Uint8List bytes;

  /// The file name (its stem becomes the shortcode).
  final String name;

  /// The emoji it stands for (search and suggestions), optional.
  final String? emoji;
}

/// What an upload batch did.
@immutable
class OwnPackAddResult {
  const OwnPackAddResult({
    this.added = 0,
    this.duplicates = 0,
    this.failed = const [],
    this.cancelled = false,
  });

  final int added;

  /// Already in the pack (same image), skipped.
  final int duplicates;

  /// Inputs not added, with a sentence each.
  final List<(OwnStickerInput, String)> failed;
  final bool cancelled;
}

/// Hash kept with each image to find duplicates (ignored by other apps).
const ownStickerHashKey = 'pl.personal.chat.sha256';

/// The account's own sticker pack (MSC2545 user pack, `m.image_pack` or
/// `im.ponies.user_emotes` account data), made from the user's images:
/// each one is uploaded to the media repository once and listed in the
/// pack, which syncs to every device and shows in other Matrix apps.
/// Every change re-reads the newest pack before writing, so it merges with
/// what another device stored.
class OwnStickerPackEditor {
  OwnStickerPackEditor(
    this.backend, {
    this.retryDelay = const Duration(seconds: 1),
  });

  factory OwnStickerPackEditor.of(Client client, {StickerLibrary? library}) =>
      OwnStickerPackEditor(
        MatrixOwnPackBackend(
          client,
          library: library ?? StickerLibrary.of(client),
        ),
      );

  final OwnPackBackend backend;
  final Duration retryDelay;

  static const maxBytes = 2 * 1024 * 1024;

  /// Account data stays well under the ~64 KB event limit.
  static const maxStickers = 150;
  static const maxContentChars = 60 * 1024;
  static const uploadAttempts = 3;
  static const defaultName = 'My stickers';
  static const _mimes = {'image/png', 'image/webp', 'image/gif', 'image/jpeg'};

  /// The pack as stored now (images in order), or null.
  ImagePackContent? get pack {
    final content = backend.read().$2;
    if (content == null) return null;
    try {
      return ImagePackContent.fromJson(content);
    } catch (_) {
      return null;
    }
  }

  String get name => pack?.pack.displayName?.trim().isNotEmpty == true
      ? pack!.pack.displayName!.trim()
      : defaultName;

  /// The images in order: (shortcode, raw image JSON).
  List<(String, Map<String, Object?>)> get images {
    final images = backend.read().$2?['images'];
    if (images is! Map) return const [];
    return [
      for (final entry in images.entries)
        if (entry.key is String && entry.value is Map)
          (entry.key as String, (entry.value as Map).cast<String, Object?>()),
    ];
  }

  /// Uploads [inputs] one after another and adds them in one write. Images
  /// that fail (not an image, too large, upload failed after retries) are
  /// reported, the others are kept. [cancelled] stops before the next
  /// upload; what was uploaded is still added. [onProgress] gets (done,
  /// total).
  Future<OwnPackAddResult> add(
    List<OwnStickerInput> inputs, {
    String? packName,
    bool Function()? cancelled,
    void Function(int done, int total)? onProgress,
  }) async {
    final known = {for (final (_, image) in images) ?_hashOf(image)};
    final failed = <(OwnStickerInput, String)>[];
    final entries = <(OwnStickerInput, Map<String, Object?>)>[];
    var duplicates = 0;
    var done = 0;
    var stopped = false;
    final room = maxStickers - images.length;
    for (final input in inputs) {
      if (cancelled?.call() ?? false) {
        stopped = true;
        break;
      }
      onProgress?.call(done, inputs.length);
      done++;
      final hash = sha256.convert(input.bytes).toString();
      if (!known.add(hash)) {
        duplicates++;
        continue;
      }
      if (entries.length >= room) {
        failed.add((input, 'Your pack is full ($maxStickers stickers).'));
        continue;
      }
      final checked = _check(input);
      if (checked.$2 != null) {
        failed.add((input, checked.$2!));
        continue;
      }
      final (mimetype, width, height) = checked.$1!;
      final Uri url;
      try {
        url = await _upload(input, mimetype);
      } on StickerImportException catch (e) {
        failed.add((input, e.message));
        continue;
      }
      final emoji = input.emoji?.trim();
      entries.add((
        input,
        {
          'url': url.toString(),
          'body': emoji != null && emoji.isNotEmpty ? emoji : _stem(input.name),
          'info': {
            'mimetype': mimetype,
            'size': input.bytes.length,
            'w': width,
            'h': height,
            ownStickerHashKey: hash,
          },
          'usage': ['sticker'],
        },
      ));
    }
    onProgress?.call(done, inputs.length);
    if (entries.isNotEmpty) {
      await _update((content) {
        final images = _imagesOf(content);
        for (final (input, image) in entries) {
          images[_uniqueShortcode(_stem(input.name), images)] = image;
        }
        content['images'] = images;
        final meta = _metaOf(content);
        final name = packName?.trim();
        if (name != null && name.isNotEmpty) meta['display_name'] = name;
        meta['display_name'] ??= defaultName;
        content['pack'] = meta;
      });
    }
    return OwnPackAddResult(
      added: entries.length,
      duplicates: duplicates,
      failed: failed,
      cancelled: stopped,
    );
  }

  /// Removes the stickers of [shortcodes].
  Future<void> remove(Iterable<String> shortcodes) {
    final gone = shortcodes.toSet();
    return _update((content) {
      final images = _imagesOf(content)
        ..removeWhere((key, _) => gone.contains(key));
      content['images'] = images;
    });
  }

  /// Puts a removed sticker back (Undo), at its place in [order].
  Future<void> restore(
    String shortcode,
    Map<String, Object?> image, {
    List<String> order = const [],
  }) => _update((content) {
    final images = _imagesOf(content);
    images[shortcode] = _copy(image);
    content['images'] = {
      for (final key in order)
        if (images.containsKey(key)) key: images[key],
      for (final entry in images.entries)
        if (!order.contains(entry.key)) entry.key: entry.value,
    };
  });

  /// Puts the stickers in [order] (shortcodes); others keep their place at
  /// the end (added meanwhile on another device).
  Future<void> reorder(List<String> order) => _update((content) {
    final images = _imagesOf(content);
    content['images'] = {
      for (final key in order)
        if (images.containsKey(key)) key: images[key],
      for (final entry in images.entries)
        if (!order.contains(entry.key)) entry.key: entry.value,
    };
  });

  Future<void> rename(String name) => _update((content) {
    final meta = _metaOf(content);
    final trimmed = name.trim();
    meta['display_name'] = trimmed.isEmpty ? defaultName : trimmed;
    content['pack'] = meta;
  });

  /// Sets the emoji of one sticker (its body).
  Future<void> setEmoji(String shortcode, String emoji) => _update((content) {
    final images = _imagesOf(content);
    final image = images[shortcode];
    if (image is! Map) return;
    final trimmed = emoji.trim();
    images[shortcode] = {
      ...image.cast<String, Object?>(),
      'body': trimmed.isEmpty ? shortcode : trimmed,
    };
    content['images'] = images;
  });

  Future<void> _update(
    void Function(Map<String, Object?> content) change,
  ) async {
    final (type, current) = backend.read();
    final content = _copy(current ?? const {});
    change(content);
    if (jsonEncode(content).length > maxContentChars) {
      throw const StickerImportException(
        'Your pack is too large to store. Remove some stickers first.',
        retryable: false,
      );
    }
    try {
      await backend.write(type, content);
    } catch (e, s) {
      Logs().d('Own sticker pack not stored', e, s);
      throw const StickerImportException(
        'Your pack couldn’t be saved. Check your connection and try again.',
      );
    }
  }

  Future<Uri> _upload(OwnStickerInput input, String mimetype) async {
    Object? last;
    for (var attempt = 0; attempt < uploadAttempts; attempt++) {
      try {
        return await backend.upload(input.bytes, input.name, mimetype);
      } on FileTooBigMatrixException {
        throw const StickerImportException(
          'This image is larger than your server accepts.',
          retryable: false,
        );
      } catch (e) {
        last = e;
        if (attempt + 1 < uploadAttempts && retryDelay > Duration.zero) {
          await Future.delayed(retryDelay * (attempt + 1));
        }
      }
    }
    Logs().d('Own sticker upload failed', last);
    throw const StickerImportException(
      'Upload failed. Check your connection and try again.',
    );
  }

  /// (mimetype, width, height) or a sentence why it can't be a sticker.
  static ((String, int, int)?, String?) _check(OwnStickerInput input) {
    if (input.bytes.isEmpty) return (null, 'This file is empty.');
    if (input.bytes.length > maxBytes) {
      return (null, 'Stickers can be up to 2 MB.');
    }
    final mimetype = lookupMimeType(input.name, headerBytes: input.bytes);
    if (mimetype == null || !_mimes.contains(mimetype)) {
      return (null, 'Use a PNG, WebP, GIF or JPEG image.');
    }
    try {
      final info = img
          .findDecoderForData(input.bytes)
          ?.startDecode(input.bytes);
      if (info == null || info.width <= 0 || info.height <= 0) {
        return (null, 'This image couldn’t be read.');
      }
      return ((mimetype, info.width, info.height), null);
    } catch (_) {
      return (null, 'This image couldn’t be read.');
    }
  }

  static String? _hashOf(Map<String, Object?> image) {
    final info = image['info'];
    final hash = info is Map ? info[ownStickerHashKey] : null;
    return hash is String ? hash : null;
  }

  static String _stem(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  static String _uniqueShortcode(String stem, Map<String, Object?> taken) {
    var slug = stem
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (slug.isEmpty) slug = 'sticker';
    if (slug.length > 32) slug = slug.substring(0, 32);
    var key = slug;
    for (var i = 2; taken.containsKey(key); i++) {
      key = '${slug}_$i';
    }
    return key;
  }

  static Map<String, Object?> _imagesOf(Map<String, Object?> content) {
    final images = content['images'];
    return images is Map ? _copy(images) : <String, Object?>{};
  }

  static Map<String, Object?> _metaOf(Map<String, Object?> content) {
    final meta = content['pack'];
    return meta is Map
        ? _copy(meta)
        : <String, Object?>{
            'usage': ['sticker'],
          };
  }

  static Map<String, Object?> _copy(Map value) => {
    for (final entry in value.entries) '${entry.key}': _copyValue(entry.value),
  };

  static Object? _copyValue(Object? value) => switch (value) {
    final Map m => _copy(m),
    final List l => [for (final e in l) _copyValue(e)],
    _ => value,
  };
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'encrypted_media_cache.dart';
import 'protected_matrix_database.dart';

/// One in-progress load per database, account, source and storage policy.
/// Completed futures are removed: the encrypted database owns the 24h lifetime,
/// including when a timeline widget remains mounted for longer than a day.
final _loads = Expando<Map<Object, Future<Uint8List>>>();

class _Source {
  final Event original;
  final DatabaseApi database;
  final String? owner;
  final Uri? server;
  final int generation;

  _Source(this.original)
    : database = original.room.client.database,
      owner = original.room.client.userID,
      server = original.room.client.baseUri,
      generation = _cacheGeneration(original.room.client.database);

  static int _cacheGeneration(DatabaseApi database) =>
      database is ProtectedMatrixDatabase ? database.mediaCacheGeneration : 0;

  void check({bool checkGeneration = true}) {
    final client = original.room.client;
    if (owner == null ||
        client.userID != owner ||
        client.baseUri != server ||
        !identical(client.database, database) ||
        (checkGeneration && _cacheGeneration(database) != generation) ||
        original.redacted ||
        !RoundMediaPolicy.fromContent(original.content).canPlay) {
      throw StateError('Media access revoked');
    }
  }

  Future<void> authorize(bool thumbnail) async {
    check();
    await original.room.client.authorizeAttachmentAccess?.call(
      original,
      thumbnail,
    );
    check();
  }

  bool get canPersist =>
      RoundMediaPolicy.fromContent(original.content).canPersist;

  Uri key(Uri url, {int? index}) => Uri(
    scheme: index == null ? 'chatloom-link' : 'chatloom-media',
    host: 'instagram',
    // Versioned: old full-quality payloads must not shadow compressed media.
    path:
        '/v2/${sha256.convert(utf8.encode(jsonEncode([owner, server?.toString(), original.room.id, original.eventId, url.toString(), index])))}',
  );

  Future<Uint8List> load(
    Uri key, {
    required Future<Uint8List> Function() download,
    required bool localOnly,
    required bool persist,
  }) async {
    check();
    final canStore = persist && canPersist;
    final loads = _loads[database] ??= {};
    final identity = (key, generation, localOnly, canStore);
    Future<Uint8List> read() async {
      // Protected/ephemeral sources cannot reuse a previously storable copy.
      final cached = canPersist ? await database.getFile(key) : null;
      check();
      if (cached != null) return cached;
      if (localOnly) throw StateError('Not cached');
      final bytes = await download();
      check();
      if (canStore && canPersist) {
        await database.storeFile(
          key,
          bytes,
          DateTime.now().millisecondsSinceEpoch,
        );
        check();
      }
      return bytes;
    }

    final future = loads[identity] ??= read();
    try {
      final bytes = await future;
      check();
      return bytes;
    } finally {
      if (identical(loads[identity], future)) loads.remove(identity);
    }
  }
}

Future<List<Map>> loadInstagramMetadata({
  required Event original,
  required Uri url,
  required Future<Object?> Function() request,
}) async {
  final source = _Source(original);
  await source.authorize(false);
  final key = source.key(url);
  List<Map> parse(Object? response) {
    if (response is! Map || response['assets'] is! List) {
      throw StateError('Invalid media');
    }
    final items = response['assets'] as List;
    if (items.isEmpty ||
        items.length > 128 ||
        items.any(
          (item) =>
              item is! Map || !const ['image', 'video'].contains(item['type']),
        )) {
      throw StateError('Invalid media');
    }
    return items.cast<Map>();
  }

  final bytes = await source.load(
    key,
    localOnly: false,
    persist: true,
    download: () async {
      final response = await request();
      parse(response);
      return Uint8List.fromList(utf8.encode(jsonEncode(response)));
    },
  );
  try {
    return parse(jsonDecode(utf8.decode(bytes)));
  } catch (_) {
    // A damaged entry must not permanently prevent an explicit retry.
    await source.database.deleteFile(key);
    rethrow;
  }
}

/// Local viewer adapter, never a Matrix timeline message or SDK HTTP download.
/// Its downloaded bytes stay in the account's bounded encrypted media cache.
class InstagramMediaAsset extends Event {
  final Event original;
  final _Source _source;
  final Uri _cacheKey;
  final Future<Object?> Function() request;

  InstagramMediaAsset({
    required this.original,
    required Uri url,
    required int index,
    required Map info,
    required this.request,
  }) : _source = _Source(original),
       _cacheKey = _Source(original).key(url, index: index),
       super(
         type: EventTypes.Message,
         eventId: '${original.eventId}/instagram/$index',
         senderId: original.senderId,
         originServerTs: original.originServerTs,
         room: original.room,
         content: {
           ...original.content,
           'msgtype': info['type'] == 'video'
               ? MessageTypes.Video
               : MessageTypes.Image,
           'body': info['type'] == 'video' ? 'instagram.mp4' : 'instagram.jpg',
           'url': 'mxc://chatloom-local.invalid/instagram',
           'chatloom.local_media': true,
           'info': {
             ...?original.content.tryGetMap<String, Object?>('info'),
             'w': info['width'],
             'h': info['height'],
           },
         }..remove('file'),
       );

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) async {
    // A mounted adapter may outlive Clear cache. Freeze a fresh generation for
    // this attempt while retaining the adapter's original account binding.
    _source.check(checkGeneration: false);
    final source = _Source(original);
    await source.authorize(getThumbnail);
    final bytes = await source.load(
      _cacheKey,
      localOnly: fromLocalStoreOnly,
      persist: cacheAttachment,
      download: () async {
        final result = await request();
        if (result is! Map ||
            result['data'] is! String ||
            result['mime'] !=
                (messageType == MessageTypes.Video
                    ? 'video/mp4'
                    : 'image/jpeg')) {
          throw StateError('Media unavailable');
        }
        final encoded = result['data'] as String;
        if (encoded.length > 90 * 1024 * 1024) {
          throw StateError('Media too large');
        }
        final bytes = base64Decode(encoded);
        if (bytes.isEmpty ||
            bytes.length > EncryptedMediaCache.instagramMaxFileSize) {
          throw StateError('Media too large');
        }
        return bytes;
      },
    );
    await source.authorize(getThumbnail);
    onDownloadProgress?.call(bytes.length);
    return MatrixFile(
      bytes: bytes,
      name: body,
      mimeType: messageType == MessageTypes.Video ? 'video/mp4' : 'image/jpeg',
    );
  }
}

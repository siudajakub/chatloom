import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/personal/media/media_access.dart';
import 'package:fluffychat/personal/round_video/round_media_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/multipart_request_progress.dart';
// The isolated player harness pins this official platform test port directly.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('database must not be accessed');
}

class _TemporaryPort extends PathProviderPlatform {
  final String directory;
  int calls = 0;
  _TemporaryPort(this.directory);
  @override
  Future<String?> getTemporaryPath() async {
    if (++calls == 1) throw StateError('synthetic temporary directory failure');
    return directory;
  }
}

Event _sizedEvent({int size = 4, int? thumbnailSize}) => _event(
  extra: {
    'info': {
      'fi.mau.telegram.round_message': true,
      'mimetype': 'video/mp4',
      'size': size,
      if (thumbnailSize != null) ...{
        'thumbnail_url': 'mxc://example.invalid/thumbnail',
        'thumbnail_info': {'size': thumbnailSize, 'mimetype': 'image/jpeg'},
      },
    },
  },
);

Event _event({Map<String, dynamic> extra = const {}, Object marker = true}) {
  final client = Client('round loader fixture', database: _UnusedDatabase());
  return Event(
    content: {
      'msgtype': 'm.video',
      'body': 'video_note.mp4',
      'info': {
        'fi.mau.telegram.round_message': marker,
        'duration': 2500,
        'mimetype': 'video/mp4',
        'size': 4,
      },
      ...extra,
    },
    type: EventTypes.Message,
    eventId: r'$round',
    senderId: '@fixture:example.invalid',
    originServerTs: DateTime.utc(2026),
    room: Room(id: '!fixture:example.invalid', client: client),
  );
}

MatrixFile _file() => MatrixFile(
  bytes: Uint8List.fromList([1, 2, 3, 4]),
  name: 'fixture.mp4',
  mimeType: 'video/mp4',
);

// Use the real asynchronous SDK stream path, not a synchronous callback fake.
Future<Object?> _streamFailure(Future<Object?> Function() action) async {
  final done = Completer<Object?>();
  final uncaught = <Object>[];
  runZonedGuarded(() async {
    try {
      await action().timeout(const Duration(seconds: 1));
      done.complete(null);
    } catch (error) {
      done.complete(error);
    }
  }, (error, stack) => uncaught.add(error));
  final error = await done.future;
  expect(
    uncaught,
    isEmpty,
    reason: 'Progress errors must stay in the download',
  );
  return error;
}

void main() {
  test(
    'SDK byte stream collects chunks and reports cumulative progress',
    () async {
      final progress = <int>[];
      final bytes = await http.ByteStream(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
      ).toBytesWithProgress(progress.add);
      expect(bytes, [1, 2, 3, 4]);
      expect(progress, [2, 4]);
      expect(
        await http.ByteStream(const Stream.empty()).toBytesWithProgress(null),
        isEmpty,
      );
    },
  );

  test(
    'SDK progress failure cancels stream and fails the download future',
    () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(stream.close);
      final failure = StateError('synthetic progress failure');
      final error = await _streamFailure(() {
        final download = http.ByteStream(stream.stream).toBytesWithProgress((
          _,
        ) {
          throw failure;
        });
        stream.add([1]);
        return download;
      });
      expect(error, same(failure));
      expect(cancelled, isTrue);
    },
  );

  test('SDK stream errors fail once without returning partial media', () async {
    final failure = StateError('synthetic stream failure');
    final error = await _streamFailure(
      () => http.ByteStream(
        Stream<List<int>>.error(failure),
      ).toBytesWithProgress(null),
    );
    expect(error, same(failure));
  });

  for (final thumbnail in [false, true]) {
    for (final reason in ['cancelled', 'sourceUnavailable', 'mediaSizeLimit']) {
      test(
        'async SDK ${thumbnail ? 'thumbnail' : 'media'} handles $reason',
        () async {
          final cancellation = RoundMediaCancellation();
          final event = _sizedEvent(thumbnailSize: 4);
          var cancelled = false;
          var leases = 0;
          final stream = StreamController<List<int>>(
            onCancel: () => cancelled = true,
          );
          addTearDown(stream.close);
          Future<MatrixFile> download(void Function(int)? progress) async {
            final bytes = http.ByteStream(
              stream.stream,
            ).toBytesWithProgress(progress);
            if (reason == 'cancelled') cancellation.cancel();
            if (reason == 'sourceUnavailable') {
              event.content['msgtype'] = 'm.text';
            }
            stream.add(
              Uint8List(
                reason == 'mediaSizeLimit'
                    ? (thumbnail
                              ? RoundMediaLoader.maxThumbnailBytes
                              : RoundMediaLoader.maxMediaBytes) +
                          1
                    : 1,
              ),
            );
            return MatrixFile(
              bytes: await bytes,
              name: 'fixture.mp4',
              mimeType: 'video/mp4',
            );
          }

          final loader = RoundMediaLoader(
            download: (event, {required cacheAttachment, onDownloadProgress}) =>
                download(onDownloadProgress),
            thumbnailDownload: (event, {onDownloadProgress}) =>
                download(onDownloadProgress),
            mediaAccess: () async {
              leases++;
              throw StateError('failed download must not create a lease');
            },
          );
          final error = await _streamFailure(
            () => thumbnail
                ? loader.thumbnail(event, cancellation: cancellation)
                : loader.load(event, cancellation: cancellation),
          );
          expect(
            error,
            isA<RoundMediaUnavailable>().having(
              (e) => e.reason,
              'reason',
              reason,
            ),
          );
          expect(cancelled, isTrue);
          expect(leases, 0);
        },
      );
    }
  }

  test(
    'declared media/thumbnail limits reject before the SDK adapter',
    () async {
      var downloads = 0, thumbnails = 0;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              downloads++;
              return _file();
            },
        thumbnailDownload: (event, {onDownloadProgress}) async {
          thumbnails++;
          return _file();
        },
      );
      await expectLater(
        loader.load(_sizedEvent(size: RoundMediaLoader.maxMediaBytes + 1)),
        throwsA(
          isA<RoundMediaUnavailable>().having(
            (e) => e.reason,
            'reason',
            'mediaSizeLimit',
          ),
        ),
      );
      await expectLater(
        loader.thumbnail(
          _sizedEvent(thumbnailSize: RoundMediaLoader.maxThumbnailBytes + 1),
        ),
        throwsA(
          isA<RoundMediaUnavailable>().having(
            (e) => e.reason,
            'reason',
            'mediaSizeLimit',
          ),
        ),
      );
      expect(downloads, 0);
      expect(thumbnails, 0);
    },
  );

  test(
    'media progress aborts over-limit transfer and latches swallowed exceptions',
    () async {
      var continued = false;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              onDownloadProgress!(RoundMediaLoader.maxMediaBytes + 1);
              continued = true;
              return _file();
            },
      );
      await expectLater(
        loader.load(_event()),
        throwsA(isA<RoundMediaUnavailable>()),
      );
      expect(continued, isFalse);
      final swallowing = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              try {
                onDownloadProgress!(RoundMediaLoader.maxMediaBytes + 1);
              } catch (_) {}
              return _file();
            },
      );
      await expectLater(
        swallowing.load(_event()),
        throwsA(isA<RoundMediaUnavailable>()),
      );
    },
  );

  test('thumbnail progress aborts at 2 MiB', () async {
    var continued = false;
    final loader = RoundMediaLoader(
      thumbnailDownload: (event, {onDownloadProgress}) async {
        onDownloadProgress!(RoundMediaLoader.maxThumbnailBytes + 1);
        continued = true;
        return _file();
      },
    );
    await expectLater(
      loader.thumbnail(_sizedEvent(thumbnailSize: 4)),
      throwsA(isA<RoundMediaUnavailable>()),
    );
    expect(continued, isFalse);
  });

  test(
    'no-progress SDK/scanner response still rejects oversized final bytes before lease',
    () async {
      var leases = 0;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async =>
                MatrixFile(
                  bytes: Uint8List(RoundMediaLoader.maxMediaBytes + 1),
                  name: 'fixture.mp4',
                  mimeType: 'video/mp4',
                ),
        thumbnailDownload: (event, {onDownloadProgress}) async => MatrixFile(
          bytes: Uint8List(RoundMediaLoader.maxThumbnailBytes + 1),
          name: 'fixture.jpg',
          mimeType: 'image/jpeg',
        ),
        mediaAccess: () async {
          leases++;
          throw StateError('oversized media cannot create a lease');
        },
      );
      await expectLater(
        loader.load(_event()),
        throwsA(isA<RoundMediaUnavailable>()),
      );
      await expectLater(
        loader.thumbnail(_sizedEvent(thumbnailSize: 4)),
        throwsA(isA<RoundMediaUnavailable>()),
      );
      expect(leases, 0);
    },
  );

  test(
    'cancellation during progress aborts media and thumbnail adapters',
    () async {
      final cancellation = RoundMediaCancellation();
      var continued = false;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              onDownloadProgress!(1);
              cancellation.cancel();
              onDownloadProgress(2);
              continued = true;
              return _file();
            },
      );
      await expectLater(
        loader.load(_event(), cancellation: cancellation),
        throwsA(isA<RoundMediaUnavailable>()),
      );
      expect(continued, isFalse);
      final thumbnailCancellation = RoundMediaCancellation();
      final thumbnail = RoundMediaLoader(
        thumbnailDownload: (event, {onDownloadProgress}) async {
          thumbnailCancellation.cancel();
          onDownloadProgress!(1);
          continued = true;
          return _file();
        },
      );
      await expectLater(
        thumbnail.thumbnail(
          _sizedEvent(thumbnailSize: 4),
          cancellation: thumbnailCancellation,
        ),
        throwsA(isA<RoundMediaUnavailable>()),
      );
      expect(continued, isFalse);
    },
  );

  test('failed shared temporary access can retry successfully', () async {
    final directory = await Directory.systemTemp.createTemp(
      'round_access_retry_fixture_',
    );
    final original = PathProviderPlatform.instance;
    final port = _TemporaryPort(directory.path);
    PathProviderPlatform.instance = port;
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final loader = RoundMediaLoader(
      download: (event, {required cacheAttachment, onDownloadProgress}) async =>
          _file(),
    );
    await expectLater(loader.load(_event()), throwsStateError);
    final media = await loader.load(_event());
    expect(port.calls, 2);
    expect(await media.lease!.file.exists(), isTrue);
    await media.close();
  });

  test('limited thumbnail never reaches SDK or cache', () async {
    var thumbnails = 0;
    final loader = RoundMediaLoader(
      thumbnailDownload: (event, {onDownloadProgress}) async {
        thumbnails++;
        return _file();
      },
    );
    await expectLater(
      loader.thumbnail(_event(extra: {'view_once': true})),
      throwsA(isA<RoundMediaUnavailable>()),
    );
    expect(thumbnails, 0);
  });

  test('protected normal media does not preload thumbnail', () async {
    var thumbnails = 0;
    final loader = RoundMediaLoader(
      thumbnailDownload: (event, {onDownloadProgress}) async {
        thumbnails++;
        return _file();
      },
    );
    expect(
      await loader.thumbnail(_event(extra: {'protected_content': true})),
      isNull,
    );
    expect(thumbnails, 0);
  });

  test(
    'limited and malformed media are blocked before download or lease',
    () async {
      var downloads = 0;
      var leases = 0;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              downloads++;
              return _file();
            },
        mediaAccess: () async {
          leases++;
          throw StateError('unexpected lease');
        },
      );
      for (final extra in <Map<String, dynamic>>[
        {'view_once': true},
        {'ttl_seconds': 15},
        {'view_once': 'true'},
        {
          'pl.personal.chat.telegram.media_policy': {
            'version': 1,
            'transfer_allowed': false,
            'reason': 'time_limited',
            'ttl_seconds': 15,
            'view_once': false,
            'protected_content': null,
            'lazy_supported': false,
          },
        },
      ]) {
        await expectLater(
          loader.load(_event(extra: extra)),
          throwsA(isA<RoundMediaUnavailable>()),
        );
      }
      expect(downloads, 0);
      expect(leases, 0);
    },
  );

  test('strict marker does not infer round from a string', () async {
    final loader = RoundMediaLoader(
      download: (event, {required cacheAttachment, onDownloadProgress}) async {
        fail('ordinary video must not be downloaded by round loader');
      },
    );
    await expectLater(
      loader.load(_event(marker: 'true')),
      throwsA(isA<RoundMediaUnavailable>()),
    );
  });

  test('cancel after download prevents creating plaintext lease', () async {
    final download = Completer<MatrixFile>();
    final cancellation = RoundMediaCancellation();
    var leases = 0;
    final loader = RoundMediaLoader(
      download: (event, {required cacheAttachment, onDownloadProgress}) =>
          download.future,
      mediaAccess: () async {
        leases++;
        throw StateError('unexpected lease');
      },
    );
    final pending = loader.load(_event(), cancellation: cancellation);
    cancellation.cancel();
    download.complete(_file());
    await expectLater(pending, throwsA(isA<RoundMediaUnavailable>()));
    expect(leases, 0);
  });

  test(
    'source invalidation during download does not reach codec lease',
    () async {
      final download = Completer<MatrixFile>();
      var valid = true;
      final loader = RoundMediaLoader(
        download: (event, {required cacheAttachment, onDownloadProgress}) =>
            download.future,
        mediaAccess: () async => throw StateError('unexpected lease'),
      );
      final pending = loader.load(
        _event(),
        cancellation: RoundMediaCancellation(sourceValid: () => valid),
      );
      valid = false;
      download.complete(_file());
      await expectLater(pending, throwsA(isA<RoundMediaUnavailable>()));
    },
  );

  test(
    'protected normal playback bypasses cache and holds lease until close',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'round_loader_fixture_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final access = await MediaAccess.open(directory: directory);
      bool? cached;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              cached = cacheAttachment;
              return _file();
            },
        mediaAccess: () async => access,
      );
      final media = await loader.load(
        _event(extra: {'protected_content': true}),
      );
      expect(cached, isFalse);
      expect(await media.lease!.file.exists(), isTrue);
      final path = media.lease!.file.path;
      await media.close();
      expect(await File(path).exists(), isFalse);
      await media.close();
    },
  );
}

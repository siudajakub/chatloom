// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/personal/media/instagram_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  final files = <Uri, (Uint8List, DateTime)>{};
  DateTime now = DateTime.utc(2026, 11, 8);
  int reads = 0, writes = 0;

  @override
  int get maxFileSize => 10 * 1000 * 1000;

  @override
  Future<Uint8List?> getFile(Uri key) async {
    reads++;
    final row = files[key];
    return row != null && now.difference(row.$2) < const Duration(days: 1)
        ? row.$1
        : null;
  }

  @override
  Future<void> storeFile(Uri key, Uint8List bytes, int time) async {
    writes++;
    files[key] = (bytes, now);
  }

  @override
  Future<bool> deleteFile(Uri key) async => files.remove(key) != null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client(DatabaseApi db) : super('Instagram fixture', database: db) {
    homeserver = Uri.parse('https://example.invalid');
  }

  String? account = '@owner:example.invalid';
  @override
  String? get userID => account;
}

const _info = {'type': 'video', 'width': 720, 'height': 1280};
final _url = Uri.parse('https://www.instagram.com/reel/Fixture/');

Object _response([int length = 3]) => {
  'mime': 'video/mp4',
  'data': base64Encode(Uint8List(length)..fillRange(0, length, 7)),
};

void main() {
  late _Database db;
  late _Client client;
  late Event original;
  var requests = 0;

  setUp(() {
    db = _Database();
    client = _Client(db);
    original = Event(
      type: EventTypes.Message,
      room: Room(id: '!fixture:example.invalid', client: client),
      eventId: r'$reel',
      senderId: '@sender:example.invalid',
      originServerTs: DateTime.utc(2026),
      content: {'msgtype': MessageTypes.Text, 'body': _url.toString()},
    );
    requests = 0;
  });

  InstagramMediaAsset asset({
    Uri? url,
    int index = 0,
    Future<Object?> Function()? request,
  }) => InstagramMediaAsset(
    original: original,
    url: url ?? _url,
    index: index,
    info: _info,
    request:
        request ??
        () async {
          requests++;
          return _response();
        },
  );

  test('reopen and rebuilt adapter reuse the account database', () async {
    final first = asset();
    expect((await first.downloadAndDecryptAttachment()).bytes, [7, 7, 7]);
    await first.downloadAndDecryptAttachment();
    await asset().downloadAndDecryptAttachment();
    expect(requests, 1);
    expect(db.writes, 1);
    expect(db.reads, 3, reason: 'completed futures do not retain media');
  });

  test(
    'payload above the SDK 10 MB limit still reaches encrypted cache',
    () async {
      final media = asset(
        request: () async {
          requests++;
          return _response(10 * 1000 * 1000 + 1);
        },
      );
      expect(
        (await media.downloadAndDecryptAttachment()).size,
        greaterThan(db.maxFileSize),
      );
      await media.downloadAndDecryptAttachment();
      expect(requests, 1);
      expect(db.writes, 1);
    },
  );

  test('concurrent adapters share one read, request and store', () async {
    final pending = Completer<Object?>();
    Future<Object?> request() {
      requests++;
      return pending.future;
    }

    final loads = List.generate(
      8,
      (_) => asset(request: request).downloadAndDecryptAttachment(),
    );
    pending.complete(_response());
    await Future.wait(loads);
    expect(requests, 1);
    expect(db.reads, 1);
    expect(db.writes, 1);
  });

  test('same mounted adapter downloads after absolute 24h expiry', () async {
    final media = asset();
    await media.downloadAndDecryptAttachment();
    db.now = db.now.add(const Duration(hours: 23));
    await media.downloadAndDecryptAttachment();
    expect(requests, 1);
    db.now = db.now.add(const Duration(hours: 1));
    await media.downloadAndDecryptAttachment();
    expect(requests, 2);
  });

  test('local-only miss never starts or joins a download', () async {
    final pending = Completer<Object?>();
    final media = asset(request: () => pending.future);
    final online = media.downloadAndDecryptAttachment();
    await expectLater(
      media.downloadAndDecryptAttachment(fromLocalStoreOnly: true),
      throwsStateError,
    );
    pending.complete(_response());
    await online;
    await media.downloadAndDecryptAttachment(fromLocalStoreOnly: true);
  });

  test('failed request releases the shared flight for retry', () async {
    final media = asset(
      request: () async {
        requests++;
        if (requests == 1) throw StateError('offline fixture');
        return _response();
      },
    );
    await expectLater(media.downloadAndDecryptAttachment(), throwsStateError);
    await media.downloadAndDecryptAttachment();
    expect(requests, 2);
  });

  test('URL, album index and account cannot collide', () async {
    await asset().downloadAndDecryptAttachment();
    await asset(index: 1).downloadAndDecryptAttachment();
    await asset(
      url: Uri.parse('https://www.instagram.com/reel/Other/'),
    ).downloadAndDecryptAttachment();
    client.account = '@other:example.invalid';
    await asset().downloadAndDecryptAttachment();
    expect(requests, 4);
    expect(db.files, hasLength(4));
    for (final key in db.files.keys) {
      expect(key.toString(), isNot(contains('Fixture')));
      expect(key.toString(), isNot(contains('owner')));
    }
  });

  test('old adapter and late download reject account change', () async {
    final pending = Completer<Object?>();
    final media = asset(request: () => pending.future);
    final load = media.downloadAndDecryptAttachment();
    final rejected = expectLater(load, throwsStateError);
    // Let authorization finish and the request begin.
    await Future<void>.delayed(Duration.zero);
    client.account = '@other:example.invalid';
    pending.complete(_response());
    await rejected;
    expect(db.writes, 0);
    await expectLater(media.downloadAndDecryptAttachment(), throwsStateError);
  });

  test('protected media is playable but never cached', () async {
    original.content['protected_content'] = true;
    final media = asset();
    await media.downloadAndDecryptAttachment();
    await media.downloadAndDecryptAttachment();
    expect(requests, 2);
    expect(db.writes, 0);
    expect(db.reads, 0);
    expect(media.content['protected_content'], isTrue);
  });

  test(
    'redaction during download rejects bytes before cache or playback',
    () async {
      final pending = Completer<Object?>();
      final started = Completer<void>();
      final media = asset(
        request: () {
          started.complete();
          return pending.future;
        },
      );
      final load = media.downloadAndDecryptAttachment();
      final rejected = expectLater(load, throwsStateError);
      await started.future;
      original.setRedactionEvent(
        Event(
          type: EventTypes.Redaction,
          room: original.room,
          eventId: r'$redaction',
          senderId: '@owner:example.invalid',
          originServerTs: DateTime.utc(2026),
          content: {},
        ),
      );
      pending.complete(_response());
      await rejected;
      expect(db.writes, 0);
    },
  );

  test('limited media cannot trigger a download', () async {
    original.content['com.beeper.disappearing'] = {'timer': 60};
    await expectLater(asset().downloadAndDecryptAttachment(), throwsStateError);
    expect(requests, 0);
  });

  test(
    'cacheAttachment false never persists or retains successful bytes',
    () async {
      final media = asset();
      await media.downloadAndDecryptAttachment(cacheAttachment: false);
      await media.downloadAndDecryptAttachment(cacheAttachment: false);
      expect(requests, 2);
      expect(db.writes, 0);
    },
  );

  test('access gate runs on cache hits too', () async {
    final media = asset();
    await media.downloadAndDecryptAttachment();
    client.authorizeAttachmentAccess = (_, _) async =>
        throw StateError('revoked fixture');
    await expectLater(media.downloadAndDecryptAttachment(), throwsStateError);
    expect(requests, 1);
  });

  test(
    'metadata reused without extending saved time; expires in 24h',
    () async {
      Future<List<Map>> load() => loadInstagramMetadata(
        original: original,
        url: _url,
        request: () async {
          requests++;
          return {
            'assets': [_info],
          };
        },
      );
      expect(await load(), [_info]);
      db.now = db.now.add(const Duration(hours: 23));
      await load();
      expect(requests, 1);
      expect(db.writes, 1);
      db.now = db.now.add(const Duration(hours: 1));
      await load();
      expect(requests, 2);
    },
  );

  test('malformed response is not cached', () async {
    await expectLater(
      asset(
        request: () async => {
          'mime': 'text/html',
          'data': base64Encode([1]),
        },
      ).downloadAndDecryptAttachment(),
      throwsStateError,
    );
    expect(db.writes, 0);
    await expectLater(
      loadInstagramMetadata(
        original: original,
        url: _url,
        request: () async => {'assets': []},
      ),
      throwsStateError,
    );
    expect(db.writes, 0);
  });
}

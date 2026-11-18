// SPDX-License-Identifier: AGPL-3.0-or-later
// Save of a whole album or gallery message: which items, the one
// confirmation, unique names in the chosen folder. Synthetic events only.
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/media/album_save.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Client extends Client {
  _Client() : super('album save fixture', database: _NoDatabase());
  @override
  String get userID => '@me:example.invalid';
}

void main() {
  final room = Room(id: '!album:example.invalid', client: _Client());

  Event media(String id, String type) => Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    status: EventStatus.synced,
    originServerTs: DateTime.utc(2026, 1, 1, 12),
    content: {
      'msgtype': type,
      'body': '$id.bin',
      'url': 'mxc://example.invalid/$id',
    },
  );

  Event gallery(List<String> types) => Event(
    room: room,
    eventId: r'$gallery',
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    status: EventStatus.synced,
    originServerTs: DateTime.utc(2026, 1, 1, 12),
    content: {
      'msgtype': 'm.gallery',
      'body': 'Album',
      'itemtypes': [
        for (var i = 0; i < types.length; i++)
          {
            'itemtype': types[i],
            'body': 'i$i',
            'url': 'mxc://example.invalid/i$i',
          },
      ],
    },
  );

  MatrixFile file(String name) =>
      MatrixFile(bytes: Uint8List.fromList([1, 2, 3]), name: name);

  group('albumSaveEvents', () {
    test('an album lead saves every member, a lone photo only itself', () {
      final members = [
        media('a', MessageTypes.Image),
        media('b', MessageTypes.Image),
        media('c', MessageTypes.Video),
      ];
      expect(albumSaveEvents(members.last, members), members);
      expect(albumSaveEvents(members.last, null), isEmpty);
      expect(albumSaveEvents(members.first, [members.first]), isEmpty);
    });

    test('a gallery message saves its photos and videos', () {
      final events = albumSaveEvents(
        gallery([MessageTypes.Image, MessageTypes.Video, MessageTypes.File]),
        null,
      );
      expect(events.map((e) => e.messageType), [
        MessageTypes.Image,
        MessageTypes.Video,
      ]);
    });
  });

  group('albumSaveLabel', () {
    final photos = [
      media('a', MessageTypes.Image),
      media('b', MessageTypes.Image),
      media('c', MessageTypes.Image),
    ];
    test('names the count and the platform', () {
      expect(albumSaveLabel(photos, android: true), 'Save 3 photos to gallery');
      expect(albumSaveLabel(photos, android: false), 'Save 3 photos…');
      expect(
        albumSaveLabel([
          ...photos,
          media('v', MessageTypes.Video),
        ], android: false),
        'Save 4 items…',
      );
    });
  });

  group('saveAlbumItems', () {
    final events = [
      media('a', MessageTypes.Image),
      media('b', MessageTypes.Image),
      media('c', MessageTypes.Image),
    ];

    test('saves all three, one at a time, with one confirmation', () async {
      final order = <String>[];
      final result = await saveAlbumItems(
        events: events,
        fetch: (e, i) async {
          order.add('fetch ${e.eventId}');
          return file(e.eventId);
        },
        store: (f) async {
          order.add('store ${f.name}');
          return true;
        },
      );
      expect(order, [
        'fetch a', 'store a', 'fetch b', 'store b', 'fetch c', 'store c', //
      ]);
      expect(result.message, 'Saved 3 photos');
    });

    test('counts a failed item and keeps going', () async {
      final result = await saveAlbumItems(
        events: events,
        fetch: (e, i) async =>
            e.eventId == 'b' ? throw Exception('boom') : file(e.eventId),
        store: (f) async => true,
      );
      expect(result.saved, 2);
      expect(result.message, 'Saved 2 of 3 items');
    });

    test('a blocked item (null) is not saved', () async {
      final result = await saveAlbumItems(
        events: events,
        fetch: (e, i) async => e.eventId == 'a' ? null : file(e.eventId),
        store: (f) async => true,
      );
      expect(result.photos, 2);
      expect(result.failed, 1);
    });

    test('a dismissed folder picker stops quietly', () async {
      final result = await saveAlbumItems(
        events: events,
        fetch: (e, i) async => file(e.eventId),
        store: (f) async => throw const AlbumSaveCancelled(),
      );
      expect(result.cancelled, isTrue);
      expect(result.message, isNull);
    });

    test('mixed and total-failure messages', () async {
      expect(
        const AlbumSaveResult(photos: 2, videos: 1).message,
        'Saved 2 photos and 1 video',
      );
      expect(const AlbumSaveResult(videos: 1).message, 'Saved 1 video');
      expect(
        const AlbumSaveResult(failed: 3).message,
        'Could not save the files.',
      );
    });
  });

  group('names and folder', () {
    test('uniqueExportName numbers clashes', () {
      final taken = {'a.jpg', 'a (1).jpg', 'noext'};
      expect(uniqueExportName('b.jpg', taken.contains), 'b.jpg');
      expect(uniqueExportName('a.jpg', taken.contains), 'a (2).jpg');
      expect(uniqueExportName('noext', taken.contains), 'noext (1)');
    });

    test('AlbumFolderSink asks once and never overwrites', () async {
      final dir = Directory.systemTemp.createTempSync('album_save_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      var asked = 0;
      final sink = AlbumFolderSink(() async {
        asked++;
        return dir.path;
      });
      await sink.write(file('photo.jpg'));
      await sink.write(file('photo.jpg'));
      await sink.write(file('photo.jpg'));
      expect(asked, 1);
      expect(
        dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort(),
        ['photo (1).jpg', 'photo (2).jpg', 'photo.jpg'],
      );
    });

    test('AlbumFolderSink cancels when no folder is chosen', () {
      final sink = AlbumFolderSink(() async => null);
      expect(sink.write(file('x.jpg')), throwsA(isA<AlbumSaveCancelled>()));
    });
  });
}

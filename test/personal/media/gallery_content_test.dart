// SPDX-License-Identifier: AGPL-3.0-or-later
// MSC4274 gallery parsing, item events, forwarding and the multi-pick album
// marker. Synthetic events only; nothing is downloaded or sent.
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/personal/media/gallery_batch.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Client extends Client {
  _Client() : super('gallery fixture', database: _NoDatabase());
  @override
  String get userID => '@me:example.invalid';
}

Map<String, Object?> _image(String id, {bool encrypted = false}) => {
  'itemtype': MessageTypes.Image,
  'body': '$id.jpg',
  'info': {'mimetype': 'image/jpeg', 'w': 400, 'h': 300, 'size': 1000},
  if (encrypted)
    'file': {'url': 'mxc://example.invalid/$id', 'v': 'v2'}
  else
    'url': 'mxc://example.invalid/$id',
};

void main() {
  final client = _Client();
  final room = Room(id: '!gallery:example.invalid', client: client);

  Event event(
    String id,
    Map<String, Object?> content, {
    String sender = '@anna:example.invalid',
    DateTime? at,
    EventStatus status = EventStatus.synced,
  }) => Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: sender,
    status: status,
    originServerTs: at ?? DateTime.utc(2026, 1, 1, 12),
    content: content,
  );

  group('GalleryContent.parse', () {
    test('reads MSC4274 itemtypes with a caption (Rust SDK form)', () {
      final gallery = GalleryContent.parse({
        'msgtype': 'dm.filament.gallery',
        'body': 'Holiday',
        'itemtypes': [
          _image('a'),
          {
            'itemtype': MessageTypes.Video,
            'body': 'b.mp4',
            'url': 'mxc://example.invalid/b',
          },
        ],
      })!;
      expect(gallery.caption, 'Holiday');
      expect(gallery.malformed, isFalse);
      expect(
        [for (final i in gallery.items) i.type],
        [MessageTypes.Image, MessageTypes.Video],
      );
      expect(gallery.items.every((i) => i.visual), isTrue);
    });

    test('reads gomuks "items" with msgtype, preferring itemtypes', () {
      final gomuks = GalleryContent.parse({
        'msgtype': 'm.gallery',
        'body': '',
        'items': [
          {'msgtype': MessageTypes.File, 'body': 'a.pdf', 'url': 'mxc://x/a'},
        ],
      })!;
      expect(gomuks.caption, isNull);
      expect(gomuks.items.single.type, MessageTypes.File);
      expect(gomuks.items.single.supported, isTrue);
      expect(gomuks.items.single.visual, isFalse);

      final both = GalleryContent.parse({
        'msgtype': 'dm.filament.gallery',
        'body': '',
        'itemtypes': [_image('a')],
        'items': [
          {'msgtype': MessageTypes.File, 'body': 'x', 'url': 'mxc://x/x'},
        ],
      })!;
      expect(both.items.single.type, MessageTypes.Image);
    });

    test('keeps entries it cannot show, so none is dropped silently', () {
      final gallery = GalleryContent.parse({
        'msgtype': 'dm.filament.gallery',
        'body': 'x',
        'itemtypes': [
          _image('a'),
          'not a map',
          {'itemtype': 'm.location', 'body': 'Here', 'url': 'mxc://x/l'},
          {'itemtype': MessageTypes.Image, 'body': 'no media'},
        ],
      })!;
      expect(gallery.items, hasLength(4));
      expect(
        [for (final i in gallery.items) i.supported],
        [true, false, false, false],
      );
    });

    test('a missing item list is malformed; other msgtypes are no gallery', () {
      expect(
        GalleryContent.parse({
          'msgtype': 'dm.filament.gallery',
          'body': 'Only text',
        })!.malformed,
        isTrue,
      );
      expect(
        GalleryContent.parse({'msgtype': MessageTypes.Image, 'body': 'x'}),
        isNull,
      );
    });
  });

  group('GalleryContent.itemEvents', () {
    test('each supported item is an ordinary media event of its own', () {
      final gallery = event(r'$g', {
        'msgtype': 'dm.filament.gallery',
        'body': 'Trip',
        'com.beeper.view_limited': true,
        'itemtypes': [
          _image('a', encrypted: true),
          {'itemtype': 'm.location', 'body': 'Here'},
          {
            'itemtype': MessageTypes.Video,
            'url': 'mxc://example.invalid/v',
            'filename': 'clip.mp4',
          },
        ],
      }, status: EventStatus.sending);
      final items = GalleryContent.itemEvents(gallery);
      expect(
        [for (final e in items) e.eventId],
        [r'$g/gallery/0', r'$g/gallery/2'],
      );
      expect([for (final e in items) e.index], [0, 2]);
      expect(items.first.messageType, MessageTypes.Image);
      expect(items.first.content.containsKey('itemtype'), isFalse);
      expect(items.first.content['file'], isA<Map>());
      // A nameless item still has a body (the SDK reads it everywhere).
      expect(items.last.body, 'clip.mp4');
      // The gallery's protection travels with each item.
      expect(items.first.content['com.beeper.view_limited'], isTrue);
      // Never a sending copy the SDK could mark failed and store.
      expect(items.first.status, EventStatus.sent);
      expect(items.first.senderId, gallery.senderId);
      // Built once per event and content.
      expect(identical(GalleryContent.itemEvents(gallery), items), isTrue);
    });

    test('the caption drops a reply fallback; an empty body is no caption', () {
      final reply = event(r'$r', {
        'msgtype': 'dm.filament.gallery',
        'body': '> <@bob:example.invalid> hi\n\nLook',
        'itemtypes': [_image('a')],
      });
      expect(GalleryContent.of(reply)!.caption, 'Look');
      final bare = event(r'$b', {
        'msgtype': 'dm.filament.gallery',
        'body': '  ',
        'itemtypes': [_image('a')],
      });
      expect(GalleryContent.of(bare)!.caption, isNull);
    });
  });

  group('GalleryContent.forwardContents', () {
    test('a gallery forwards as its items with the caption on the last', () {
      final out = GalleryContent.forwardContents({
        'msgtype': 'dm.filament.gallery',
        'body': 'Holiday',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$x'},
        },
        'itemtypes': [_image('a'), 'broken', _image('b', encrypted: true)],
      });
      expect(out, hasLength(2));
      expect(
        [for (final c in out) c['msgtype']],
        [MessageTypes.Image, MessageTypes.Image],
      );
      expect(out.first['body'], 'a.jpg');
      expect(out.last['body'], 'Holiday');
      expect(out.last['filename'], 'b.jpg');
      expect(out.last['file'], isA<Map>());
      expect(out.any((c) => c.containsKey('m.relates_to')), isFalse);
      expect(out.any((c) => c.containsKey('itemtype')), isFalse);
    });

    test('anything else, or a gallery with nothing to forward, is kept', () {
      final text = {'msgtype': MessageTypes.Text, 'body': 'hi'};
      expect(GalleryContent.forwardContents(text), [text]);
      final empty = {
        'msgtype': 'dm.filament.gallery',
        'body': 'x',
        'itemtypes': ['broken'],
      };
      expect(GalleryContent.forwardContents(empty), [empty]);
    });
  });

  test('previews read "Album" with the caption', () {
    final captioned = event(r'$p1', {
      'msgtype': 'dm.filament.gallery',
      'body': 'Holiday\nphotos',
      'itemtypes': [_image('a')],
    });
    expect(personalPreviewLabel(captioned), 'Album: Holiday photos');
    final bare = event(r'$p2', {
      'msgtype': 'm.gallery',
      'body': '',
      'itemtypes': [_image('a')],
    });
    expect(personalPreviewLabel(bare), 'Album');
  });

  group('MediaAlbumBatch', () {
    Event photo(String id, DateTime at, {String? batch, int index = 0}) =>
        event(id, {
          'msgtype': MessageTypes.Image,
          'body': 'photo.jpg',
          'url': 'mxc://example.invalid/$id',
          'info': {'w': 400, 'h': 300},
          if (batch != null)
            ...MediaAlbumBatch.content(id: batch, index: index, count: 3),
        }, at: at);

    test('marker content round-trips', () {
      final marked = photo(r'$m', DateTime.utc(2026), batch: 'pick-1');
      expect(MediaAlbumBatch.idOf(marked), 'pick-1');
      expect(marked.content[MediaAlbumBatch.key], {
        'id': 'pick-1',
        'index': 0,
        'count': 3,
      });
      expect(MediaAlbumBatch.idOf(photo(r'$n', DateTime.utc(2026))), isNull);
    });

    test('one pick stays one album however long its uploads took', () {
      final t = DateTime.utc(2026, 1, 1, 12);
      final a = photo(r'$a', t, batch: 'pick');
      final b = photo(
        r'$b',
        t.add(const Duration(minutes: 3)),
        batch: 'pick',
        index: 1,
      );
      final c = photo(
        r'$c',
        t.add(const Duration(minutes: 5)),
        batch: 'pick',
        index: 2,
      );
      final slots = MediaAlbums.of([c, b, a]);
      expect(slots.first!.lead, isTrue);
      expect(
        [for (final e in slots.first!.members) e.eventId],
        [r'$a', r'$b', r'$c'],
      );
    });

    test('two picks sent close together stay two albums', () {
      final t = DateTime.utc(2026, 1, 1, 12);
      final first = [
        photo(r'$a1', t, batch: 'one'),
        photo(r'$a2', t.add(const Duration(seconds: 1)), batch: 'one'),
      ];
      final second = [
        photo(r'$b1', t.add(const Duration(seconds: 2)), batch: 'two'),
        photo(r'$b2', t.add(const Duration(seconds: 3)), batch: 'two'),
      ];
      final slots = MediaAlbums.of([...second.reversed, ...first.reversed]);
      expect(slots[0]!.members, hasLength(2));
      expect(slots[2]!.lead, isTrue);
      expect(slots[2]!.members, hasLength(2));
    });

    test('unmarked photos keep the time rule (incoming bridged albums)', () {
      final t = DateTime.utc(2026, 1, 1, 12);
      final near = [
        photo(r'$n2', t.add(const Duration(seconds: 2))),
        photo(r'$n1', t),
      ];
      expect(MediaAlbums.of(near).first!.members, hasLength(2));
      final far = [
        photo(r'$f2', t.add(const Duration(minutes: 2))),
        photo(r'$f1', t),
      ];
      expect(MediaAlbums.of(far), [null, null]);
    });
  });
}

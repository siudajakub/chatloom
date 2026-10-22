// SPDX-License-Identifier: AGPL-3.0-or-later
// Sticker library data model (ST-07): ordering, caps, sync/local split,
// merge of concurrent edits, pack resolution and search. Offline, fictional.
import 'dart:convert';

import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

void main() {
  late FakeStickerBackend backend;
  late StickerLibrary library;
  setUp(() {
    backend = FakeStickerBackend();
    library = fakeLibrary(backend);
  });
  tearDown(() => library.dispose());

  group('items', () {
    test('pack images keep the bridge tag and drop decoration', () {
      final item = StickerItem.fromPackImage(
        ImagePackImageContent.fromJson(packImage('a')),
        shortcode: 'FictionalPack_smile',
        packKey: 'pack',
      );
      expect(item.info['fi.mau.bridged_sticker'], isA<Map>());
      expect(item.info.containsKey('xyz.amorgan.blurhash'), isFalse);
      expect(item.emoji, '😀');
      expect(item.bridged?.packUrl, 'https://t.me/addstickers/FictionalPack');
      final again = StickerItem.fromJson(item.toJson(), StickerKind.sticker)!;
      expect(again, item);
      expect(again.shortcode, 'FictionalPack_smile');
      expect(again.packKey, 'pack');
    });

    test('events: stickers, GIFs and video stickers are recognised', () {
      final room = ConversationRoom(ConversationClient(), '!r:example.invalid');
      Event event(String type, Map<String, Object?> content) => Event(
        type: type,
        content: content,
        room: room,
        eventId: r'$e',
        senderId: '@anna:example.invalid',
        originServerTs: DateTime.utc(2026),
      );
      final sticker = StickerItem.fromEvent(
        event(EventTypes.Sticker, packImage('s')),
      );
      expect(sticker?.kind, StickerKind.sticker);
      final gif = StickerItem.fromEvent(
        event(EventTypes.Message, {
          'msgtype': MessageTypes.Video,
          'body': 'gif.mp4',
          'url': 'mxc://example.invalid/g',
          'info': {'mimetype': 'video/mp4', 'fi.mau.gif': true},
        }),
      );
      expect(gif?.kind, StickerKind.gif);
      expect(gif?.isVideo, isTrue);
      final videoSticker = StickerItem.fromEvent(
        event(EventTypes.Message, {
          'msgtype': MessageTypes.Video,
          'body': '😀',
          'url': 'mxc://example.invalid/v',
          'info': {
            'mimetype': 'video/webm',
            'fi.mau.gif': true,
            'fi.mau.telegram.animated_sticker': true,
          },
        }),
      );
      expect(videoSticker?.kind, StickerKind.sticker);
      expect(videoSticker?.isVideo, isTrue);
      final imageGif = StickerItem.fromEvent(
        event(EventTypes.Message, {
          'msgtype': MessageTypes.Image,
          'body': 'a.gif',
          'url': 'mxc://example.invalid/i',
          'info': {'mimetype': 'image/gif'},
        }),
      );
      expect(imageGif?.kind, StickerKind.gif);
      final photo = StickerItem.fromEvent(
        event(EventTypes.Message, {
          'msgtype': MessageTypes.Image,
          'body': 'a.jpg',
          'url': 'mxc://example.invalid/p',
          'info': {'mimetype': 'image/jpeg'},
        }),
      );
      expect(photo, isNull);
      expect(
        StickerItem.fromEvent(
          event(EventTypes.Sticker, {
            'body': '😀',
            'file': {'url': 'mxc://example.invalid/enc', 'key': {}},
            'info': {'mimetype': 'image/webp'},
          }),
        )?.encrypted,
        isTrue,
      );
    });

    test('emoji helpers', () {
      expect(isEmojiOnly('😀'), isTrue);
      expect(isEmojiOnly('❤️'), isTrue);
      expect(isEmojiOnly('hi 😀'), isFalse);
      expect(isEmojiOnly('123'), isFalse);
      expect(normalizeEmoji('❤️'), normalizeEmoji('❤'));
      expect(normalizeEmoji('👍🏽'), '👍');
    });
  });

  group('lists', () {
    test('recents: newest first, unique, 30 kept and 20 shown', () {
      for (var i = 0; i < 35; i++) {
        library.useSticker(sticker('s$i'));
      }
      library.useSticker(sticker('s3'));
      final all = library.list(StickerList.recentStickers);
      expect(all, hasLength(30));
      expect(all.first.key, 'mxc://example.invalid/s3');
      expect(all.where((s) => s.key.endsWith('/s3')), hasLength(1));
      expect(library.recentStickers, hasLength(20));
    });

    test('a favourite leaves the recents and is not re-added by use', () {
      final a = sticker('a');
      library.useSticker(a);
      expect(library.toggleFavourite(a), isTrue);
      expect(library.isFavourite(a), isTrue);
      expect(library.isRecent(a), isFalse);
      library.useSticker(a);
      expect(library.isRecent(a), isFalse);
      expect(library.toggleFavourite(a), isFalse);
      expect(library.favourites, isEmpty);
    });

    test('restore puts an item back at its old place', () {
      final a = sticker('a'), b = sticker('b'), c = sticker('c');
      library
        ..addFavourite(a)
        ..addFavourite(b)
        ..addFavourite(c);
      final removed = library.favourites.firstWhere((f) => f == b);
      library.removeFavourite(b);
      library.restore(StickerList.favouriteStickers, removed);
      expect(library.favourites.map((f) => f.key.split('/').last), [
        'c',
        'b',
        'a',
      ]);
    });
  });

  group('storage', () {
    test('synced and device-only items go to their events', () async {
      library
        ..useSticker(sticker('plain'))
        ..useSticker(sticker('private', encrypted: true))
        ..saveGif(videoGif('g'));
      final publicPack = StickerItem.fromJson({
        ...sticker('pack', encrypted: true).toJson(),
        'info': {
          'mimetype': 'image/webp',
          'fi.mau.bridged_sticker': {
            'network': 'telegram',
            'id': '1',
            'pack_url': 'https://t.me/addstickers/FictionalPack',
          },
        },
      }, StickerKind.sticker)!;
      library.addFavourite(publicPack);
      await library.flush();
      final stickers = backend.synced[stickerLibraryType]!;
      final recent = (stickers['recent'] as List).cast<Map>();
      expect(recent.map((r) => r['url']), ['mxc://example.invalid/plain']);
      expect((stickers['favourites'] as List), hasLength(1));
      final local = backend.local[stickerLocalType]!;
      final localRecent = (local['sticker_recent'] as List).cast<Map>();
      expect(localRecent.single['file'], isA<Map>());
      // The private file's key never reaches synced account data.
      expect(jsonEncode(backend.synced), isNot(contains('fixture-key-private')));
      // A public pack sticker's key may sync (it is public media).
      expect(jsonEncode(backend.synced), contains('fixture-key-pack'));
      expect((backend.synced[gifLibraryType]!['saved'] as List), hasLength(1));
      // The library reads back the same state.
      final again = fakeLibrary(backend);
      addTearDown(again.dispose);
      expect(again.recentStickers.map((s) => s.key.split('/').last), [
        'private',
        'plain',
      ]);
      expect(again.savedGifs, hasLength(1));
    });

    test('only changed events are written', () async {
      library.saveGif(imageGif('g'));
      await library.flush();
      expect(backend.writes, [gifLibraryType]);
    });

    test('changes from another device merge with pending ones', () async {
      final a = sticker('a'), b = sticker('b');
      // The echo of this device's write arrives after the response.
      backend.echo = false;
      library.addFavourite(a);
      // Another device added B and a pack before this one stored A.
      backend.remote(stickerLibraryType, {
        'packs': [
          {'room_id': '!space:example.invalid', 'state_key': 'Other'},
        ],
        'favourites': [
          {...b.toJson(), 'ts': 500},
        ],
      });
      expect(library.favourites.map((f) => f.key), [a.key, b.key]);
      expect(library.doc.packs.single.stateKey, 'Other');
      await library.flush();
      await library.flush();
      // Stored again on top of the other device's version.
      final written = backend.written[stickerLibraryType]!;
      expect((written['favourites'] as List), hasLength(2));
      expect((written['packs'] as List), hasLength(1));
      expect(library.pendingCount, 0);
      expect(library.favourites.map((f) => f.key), [a.key, b.key]);
    });

    test('a pack order merges with packs added elsewhere', () async {
      StickerPackRef ref(String key) =>
          StickerPackRef(roomId: '!space:example.invalid', stateKey: key);
      library
        ..addPack(ref('one'))
        ..addPack(ref('two'));
      await library.flush();
      expect(library.doc.packs.map((p) => p.stateKey), ['two', 'one']);
      library.reorderPacks([ref('one').key, ref('two').key]);
      backend.remote(stickerLibraryType, {
        ...backend.synced[stickerLibraryType]!,
        'packs': [
          ref('three').toJson(),
          ...(backend.synced[stickerLibraryType]!['packs'] as List),
        ],
      });
      expect(library.doc.packs.map((p) => p.stateKey), ['one', 'two', 'three']);
    });

    test('a failed write stays pending and visible, then retries', () async {
      backend.failWrites = Exception('offline');
      library.addFavourite(sticker('a'));
      await library.flush();
      expect(library.favourites, hasLength(1));
      expect(library.pendingCount, 1);
      backend.failWrites = null;
      await library.flush();
      expect(library.pendingCount, 0);
      expect(
        (backend.synced[stickerLibraryType]!['favourites'] as List),
        hasLength(1),
      );
    });

    test('a synced event stays under the account data budget', () {
      var doc = StickerLibraryDoc.empty;
      for (var i = 0; i < 60; i++) {
        final big = StickerItem.fromJson({
          'url': 'mxc://example.invalid/${'x' * 900}$i',
          'body': '😀',
          'info': {'mimetype': 'image/webp'},
          'ts': i,
        }, StickerKind.sticker)!;
        doc = AddItemOp(StickerList.favouriteStickers, big).apply(doc);
        doc = UseItemOp(
          StickerList.recentStickers,
          StickerItem.fromJson({...big.toJson(), 'url': '${big.url}r'},
              StickerKind.sticker)!,
        ).apply(doc);
      }
      final json = jsonEncode(doc.stickersJson());
      expect(json.length, lessThanOrEqualTo(syncedEventBudget));
      // The recents go first.
      final out = doc.stickersJson();
      expect(
        (out['recent'] as List).length,
        lessThan((out['favourites'] as List).length),
      );
    });
  });

  group('packs', () {
    const space = '!space:example.invalid';
    test('installed packs resolve from room state, then the cache', () {
      backend.rooms[space] = {
        'FictionalPack': pack('Fictional pack', {
          'FictionalPack_smile': packImage('a'),
          'FictionalPack_laugh': packImage('b', emoji: '😂'),
        }, url: 'https://t.me/addstickers/FictionalPack'),
      };
      library.addPack(
        const StickerPackRef(roomId: space, stateKey: 'FictionalPack'),
      );
      library.addPack(
        const StickerPackRef(roomId: space, stateKey: 'NotSynced'),
        content: pack('Cached pack', {'c': packImage('c', tagged: false)}),
      );
      library.addPack(
        const StickerPackRef(roomId: space, stateKey: 'Missing'),
      );
      final packs = library.packs;
      expect(packs.map((p) => p.title), ['Cached pack', 'Fictional pack']);
      expect(packs.last.stickers, hasLength(2));
      expect(packs.last.packUrl, 'https://t.me/addstickers/FictionalPack');
      expect(
        library.packByUrl('https://t.me/addstickers/fictionalpack')?.title,
        'Fictional pack',
      );
      expect(library.isInstalled('t.me/addstickers/FictionalPack'), isTrue);
      expect(library.packOf(packs.last.stickers.first)?.title, 'Fictional pack');
    });

    test('packs enabled elsewhere can be hidden and shown again', () {
      backend.rooms['!other:example.invalid'] = {
        '': pack('Other app pack', {'o': packImage('o', tagged: false)}),
      };
      backend.elsewhere.add(('!other:example.invalid', ''));
      backend.user = pack('Mine', {'m': packImage('m', tagged: false)});
      expect(library.packs.map((p) => p.source), [
        StickerPackSource.enabledElsewhere,
        StickerPackSource.user,
      ]);
      final other = library.packs.first;
      library.removePack(other);
      expect(library.packs.map((p) => p.title), ['Mine']);
      library.restorePack(other);
      expect(library.packs, hasLength(2));
    });

    test('emoticon-only images are not stickers', () {
      final content = ImagePackContent.fromJson({
        'images': {
          'emote': {
            'url': 'mxc://example.invalid/e',
            'usage': ['emoticon'],
          },
          'sticker': {'url': 'mxc://example.invalid/s'},
        },
        'pack': {
          'usage': ['emoticon', 'sticker'],
        },
      });
      final pack = StickerPack.fromContent(
        content,
        key: 'k',
        source: StickerPackSource.room,
      );
      expect(pack.stickers.map((s) => s.shortcode), ['sticker']);
    });
  });

  group('search', () {
    setUp(() {
      backend.rooms['!space:example.invalid'] = {
        'FictionalPack': pack('Cats and dogs', {
          'FictionalPack_grin': packImage('a'),
          'FictionalPack_heart': packImage('b', emoji: '❤️'),
          'FictionalPack_thumb': packImage('c', emoji: '👍'),
        }),
      };
      library.addPack(
        const StickerPackRef(
          roomId: '!space:example.invalid',
          stateKey: 'FictionalPack',
        ),
      );
    });

    test('by emoji (variation selectors ignored)', () {
      expect(library.search('❤').map((s) => s.emoji), ['❤️']);
      expect(library.search('😀'), hasLength(1));
    });

    test('by word through the emoji keywords', () {
      expect(library.search('happy').map((s) => s.emoji), contains('😀'));
      expect(library.search('love').map((s) => s.emoji), contains('❤️'));
    });

    test('by shortcode and by pack title', () {
      expect(library.search('thumb').single.emoji, '👍');
      expect(library.search('dogs'), hasLength(3));
      expect(library.search('nothing-like-this'), isEmpty);
    });
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Matrix room packs (MSC2545 pack rooms, wave 11): links, preview by state
// or peek, join before adding, packs of joined rooms. Fictional rooms only.
import 'package:chatloom/personal/stickers/room_sticker_packs.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_pack_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

class _Backend implements RoomPackBackend {
  final aliases = <String, String>{};
  final joined = <String, Map<String, ImagePackContent>>{};
  final world = <String, List<StrippedStateEvent>>{};
  final remote = <String, Map<String, ImagePackContent>>{};
  final joins = <(String, List<String>)>[];

  @override
  Future<String> resolveAlias(String alias) async =>
      aliases[alias] ??
      (throw MatrixException.fromJson({'errcode': 'M_NOT_FOUND'}));

  @override
  Map<String, ImagePackContent>? joinedPacks(String roomId) => joined[roomId];

  @override
  String? roomName(String roomId) => 'Fictional pack room';

  @override
  Future<List<StrippedStateEvent>> peekState(String roomId) async =>
      world[roomId] ??
      (throw MatrixException.fromJson({'errcode': 'M_FORBIDDEN'}));

  @override
  Future<String> join(String target, List<String> via) async {
    joins.add((target, via));
    final roomId = aliases[target] ?? target;
    joined[roomId] = remote[roomId] ?? const {};
    return roomId;
  }
}

StrippedStateEvent _packState(String key, Map<String, Object?> content) =>
    StrippedStateEvent(
      type: 'im.ponies.room_emotes',
      content: content,
      senderId: '@someone:example.invalid',
      stateKey: key,
    );

void main() {
  group('links', () {
    test('matrix.to, matrix: URIs and bare identifiers', () {
      final cases = {
        'https://matrix.to/#/#fictional-packs:example.invalid':
            '#fictional-packs:example.invalid',
        'https://matrix.to/#/%23fictional-packs%3Aexample.invalid':
            '#fictional-packs:example.invalid',
        'matrix.to/#/!abc123:example.invalid?via=example.invalid&via=other.invalid':
            '!abc123:example.invalid',
        r'https://matrix.to/#/!abc123:example.invalid/$event?via=example.invalid':
            '!abc123:example.invalid',
        'matrix:r/fictional-packs:example.invalid':
            '#fictional-packs:example.invalid',
        'matrix:roomid/abc123:example.invalid?via=example.invalid':
            '!abc123:example.invalid',
        '#fictional-packs:example.invalid': '#fictional-packs:example.invalid',
      };
      for (final entry in cases.entries) {
        expect(
          RoomPackLink.parse(entry.key)?.target,
          entry.value,
          reason: entry.key,
        );
      }
      expect(
        RoomPackLink.parse(
          'matrix.to/#/!abc123:example.invalid?via=example.invalid&via=other.invalid',
        )!.via,
        ['example.invalid', 'other.invalid'],
      );
      expect(RoomPackLink.parse('#fictional:example.invalid')!.isAlias, isTrue);
    });

    test('not a room: users, other sites, sticker links, junk', () {
      for (final raw in [
        'https://matrix.to/#/@someone:example.invalid',
        'matrix:u/someone:example.invalid',
        'https://t.me/addstickers/FictionalPack',
        'https://example.invalid/#/#room:example.invalid',
        '#no-server',
        'cats',
        '',
        null,
      ]) {
        expect(RoomPackLink.parse(raw), isNull, reason: '$raw');
      }
    });
  });

  group('loader', () {
    late _Backend backend;
    late RoomPackLoader loader;
    final pack1 = pack('Fictional room pack', {
      'smile': packImage('r1', tagged: false),
      'wave': packImage('r2', tagged: false),
    });
    setUp(() {
      backend = _Backend();
      loader = RoomPackLoader(backend);
    });

    test('a joined room previews from its state', () async {
      backend.aliases['#packs:example.invalid'] = '!packs:example.invalid';
      backend.joined['!packs:example.invalid'] = {'main': pack1};
      final preview = await loader.preview(
        RoomPackLink.parse('#packs:example.invalid')!,
      );
      expect(preview.joined, isTrue);
      expect(preview.stickerPacks.single.title, 'Fictional room pack');
      expect(preview.stickerPacks.single.stickers, hasLength(2));
    });

    test('a public room is peeked (split packs joined, name read)', () async {
      backend.world['!public:example.invalid'] = [
        StrippedStateEvent(
          type: EventTypes.RoomName,
          content: {'name': 'Fictional public packs'},
          senderId: '@someone:example.invalid',
          stateKey: '',
        ),
        _packState('main', pack1.toJson()),
        StrippedStateEvent(
          type: 'm.room.topic',
          content: {'topic': 'x'},
          senderId: '@someone:example.invalid',
          stateKey: '',
        ),
      ];
      final preview = await loader.preview(
        RoomPackLink.parse('!public:example.invalid')!,
      );
      expect(preview.joined, isFalse);
      expect(preview.roomName, 'Fictional public packs');
      expect(preview.stickerPacks.single.stickers, hasLength(2));
    });

    test('a private room needs a join; adding joins it once', () async {
      final link = RoomPackLink.parse(
        'matrix.to/#/!private:example.invalid?via=example.invalid',
      )!;
      final preview = await loader.preview(link);
      expect(preview.joined, isFalse);
      expect(preview.stickerPacks, isEmpty);
      backend.remote['!private:example.invalid'] = {'main': pack1};
      final joined = await loader.join(link);
      expect(backend.joins.single.$1, '!private:example.invalid');
      expect(backend.joins.single.$2, ['example.invalid']);
      expect(joined.stickerPacks.single.title, 'Fictional room pack');

      final library = fakeLibrary(FakeStickerBackend());
      addTearDown(library.dispose);
      final stickerPack = joined.stickerPacks.single;
      await loader.add(joined, stickerPack, library: library, link: link);
      await loader.add(joined, stickerPack, library: library, link: link);
      expect(library.doc.packs, hasLength(1), reason: 'idempotent');
      expect(library.doc.packs.single.roomId, '!private:example.invalid');
      expect(library.doc.packs.single.stateKey, 'main');
      // Usable at once from the cached content.
      expect(library.packs.single.stickers, hasLength(2));
      expect(backend.joins, hasLength(1));
    });

    test('adding a peeked pack joins first', () async {
      backend.world['!public:example.invalid'] = [
        _packState('main', pack1.toJson()),
      ];
      backend.remote['!public:example.invalid'] = {'main': pack1};
      final link = RoomPackLink.parse('!public:example.invalid')!;
      final preview = await loader.preview(link);
      final library = fakeLibrary(FakeStickerBackend());
      addTearDown(library.dispose);
      await loader.add(
        preview,
        preview.stickerPacks.single,
        library: library,
        link: link,
      );
      expect(backend.joins, hasLength(1));
      expect(library.packs.single.title, 'Fictional room pack');
    });

    test('an unknown alias is a sentence', () async {
      await expectLater(
        loader.preview(RoomPackLink.parse('#missing:example.invalid')!),
        throwsA(
          isA<StickerImportException>().having(
            (e) => e.message,
            'message',
            'This room doesn’t exist.',
          ),
        ),
      );
    });
  });

  test('packs of joined rooms the library does not show yet', () {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!group:example.invalid');
    room.state(
      'im.ponies.room_emotes',
      pack('Fictional group pack', {
        'a': packImage('g1', tagged: false),
      }).toJson(),
      key: 'group',
    );
    final library = fakeLibrary(FakeStickerBackend());
    addTearDown(library.dispose);
    final found = packsInJoinedRooms(client, library);
    expect(found.single.$2.title, 'Fictional group pack');
    library.addPack(found.single.$1, content: found.single.$3);
    expect(packsInJoinedRooms(client, library), isEmpty);
    expect(library.packs.single.source, StickerPackSource.installed);
  });
}

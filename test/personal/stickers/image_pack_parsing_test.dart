// SPDX-License-Identifier: AGPL-3.0-or-later
// Vendored SDK patch (ST-04): stable MSC2545 image packs and packs a mautrix
// bridge split into parts. Offline fixtures, fictional ids.
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';

Map<String, Object?> _image(String id) => {
  'url': 'mxc://example.invalid/$id',
  'body': '😀',
};

void main() {
  late ConversationClient client;
  late ConversationRoom room;
  setUp(() {
    client = ConversationClient();
    room = ConversationRoom(client, '!chat:example.invalid');
  });

  test('stable room packs are read next to unstable ones', () {
    room.state(unstableImagePackStateType, {
      'images': {'old': _image('old')},
    });
    room.state(imagePackStateType, {
      'images': {'new': _image('new')},
      'pack': {'display_name': 'Stable'},
    }, key: 'stable');
    final packs = room.getImagePacks();
    expect(packs.keys, containsAll(['room', 'stable']));
    expect(packs['stable']!.images.keys, ['new']);
    expect(packs['stable']!.pack.displayName, 'Stable');
  });

  test('split bridge packs are joined without the part suffix', () {
    Map<String, Object?> part(int index, Map<String, Object?> images) => {
      'images': images,
      'pack': {
        'display_name': 'Fictional pack (part ${index + 1})',
        'fi.mau.bridged_pack': {
          'network': 'telegram',
          'url': 'https://t.me/addstickers/FictionalPack',
        },
      },
      'fi.mau.combined_pack_key': 'FictionalPack',
      'fi.mau.combined_pack_index': index,
      'fi.mau.combined_pack_count': 2,
    };
    room.state(
      imagePackStateType,
      part(1, {'b': _image('b')}),
      key: 'FictionalPack.001',
    );
    room.state(
      imagePackStateType,
      part(0, {'a': _image('a')}),
      key: 'FictionalPack',
    );
    final packs = roomImagePacks(room);
    expect(packs.keys, ['FictionalPack']);
    final pack = packs['FictionalPack']!;
    expect(pack.images.keys, ['a', 'b']);
    expect(pack.pack.displayName, 'Fictional pack');
    expect(
      (pack.pack.toJson()['fi.mau.bridged_pack'] as Map)['url'],
      'https://t.me/addstickers/FictionalPack',
    );
  });

  test('stable account data enables packs of other rooms', () {
    final space = ConversationRoom(client, '!space:example.invalid');
    space.state(imagePackStateType, {
      'images': {'s': _image('s')},
      'pack': {'display_name': 'Space pack'},
    }, key: 'pack');
    client.accountData[imagePackRoomsType] = BasicEvent(
      type: imagePackRoomsType,
      content: {
        'rooms': {
          space.id: {'pack': {}},
        },
      },
    );
    client.accountData[userImagePackType] = BasicEvent(
      type: userImagePackType,
      content: {
        'images': {'mine': _image('mine')},
      },
    );
    final packs = room.getImagePacks(ImagePackUsage.sticker);
    expect(packs['user']!.images.keys, ['mine']);
    final spacePack = packs.values.firstWhere(
      (p) => p.pack.displayName == 'Space pack',
    );
    expect(spacePack.images.keys, ['s']);
  });

  test('malformed pack content is skipped', () {
    room.state(imagePackStateType, {'images': 'not a map'}, key: 'bad');
    room.state(imagePackStateType, {
      'images': {'ok': _image('ok')},
    }, key: 'good');
    expect(roomImagePacks(room).keys, contains('good'));
    expect(() => room.getImagePacks(), returnsNormally);
  });
}

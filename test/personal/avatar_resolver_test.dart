// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/media/avatar_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

void main() {
  test('empty group avatar does not mask the bridge channel photo', () {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!group:example.invalid');
    room.state(EventTypes.RoomAvatar, {'url': ''});
    room.state('m.bridge', {
      'protocol': {'id': 'whatsapp'},
      'channel': {'avatar_url': 'mxc://example.invalid/group-photo'},
      'com.beeper.room_type.v2': 'group',
    }, key: 'fixture');
    expect(roomAvatarUri(room), Uri.parse('mxc://example.invalid/group-photo'));
  });

  test('a contact can use its DM photo when its member photo is missing', () {
    final client = ConversationClient();
    final room = ConversationRoom(
      client,
      '!instagram:example.invalid',
      network: 'instagram',
    );
    room.state(EventTypes.RoomAvatar, {
      'url': 'mxc://example.invalid/person-photo',
    });
    final user = room.unsafeGetUserFromMemoryOrFallback(
      '@anna:example.invalid',
    );
    expect(user.avatarUrl, isNull);
    expect(
      userAvatarUri(user),
      Uri.parse('mxc://example.invalid/person-photo'),
    );
  });

  test('a group without a photo never takes a participant photo', () {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!group:example.invalid');
    room.state('m.bridge', {
      'protocol': {'id': 'whatsapp'},
      'bridgebot': '@bridge:example.invalid',
      'com.beeper.room_type.v2': 'group',
    }, key: 'fixture');
    room.state(EventTypes.RoomMember, {
      'membership': 'join',
      'avatar_url': 'mxc://example.invalid/person-photo',
    }, key: '@anna:example.invalid');
    expect(roomAvatarUri(room), isNull);
  });

  test('invalid and blank avatar URIs stay absent', () {
    for (final value in [
      '',
      ' ',
      'mxc://example.invalid/',
      'https://example.invalid/photo',
      'relative',
    ]) {
      expect(usableAvatarUri(value), isNull);
    }
  });

  test('current portal photo wins over older photos in other rooms', () {
    final client = ConversationClient();
    final old = ConversationRoom(client, '!old:example.invalid');
    old.state(EventTypes.RoomAvatar, {'url': 'mxc://example.invalid/old'});
    final current = ConversationRoom(client, '!current:example.invalid');
    current.state(EventTypes.RoomAvatar, {
      'url': 'mxc://example.invalid/current',
    });
    expect(
      userAvatarUri(
        current.unsafeGetUserFromMemoryOrFallback('@anna:example.invalid'),
      ),
      Uri.parse('mxc://example.invalid/current'),
    );
  });

  test('avatar updates ignore group photos and unrelated members', () {
    final client = ConversationClient();
    final direct = ConversationRoom(client, '!direct:example.invalid');
    final group = ConversationRoom(client, '!group:example.invalid');
    group.state('m.bridge', {
      'protocol': {'id': 'whatsapp'},
      'bridgebot': '@bridge:example.invalid',
      'com.beeper.room_type.v2': 'group',
    }, key: 'fixture');
    group.state(EventTypes.RoomAvatar, {'url': 'mxc://example.invalid/group'});
    final user = direct.unsafeGetUserFromMemoryOrFallback(
      '@anna:example.invalid',
    );
    expect(
      affectsUserAvatar(user, group.id, group.getState(EventTypes.RoomAvatar)!),
      isFalse,
    );
    expect(
      affectsUserAvatar(
        user,
        direct.id,
        direct.getState(EventTypes.RoomMember, client.userID)!,
      ),
      isFalse,
    );
    expect(
      affectsUserAvatar(
        user,
        direct.id,
        direct.getState(EventTypes.RoomMember, user.id)!,
      ),
      isTrue,
    );
  });
}

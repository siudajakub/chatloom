// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/media/avatar_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

void main() {
  test('80 missing contact photos share one room scan, including misses', () {
    final client = ConversationClient();
    final rooms = [
      for (var i = 0; i < 80; i++)
        ConversationRoom(client, '!fixture-$i:example.invalid'),
    ];
    final index = LoadedAvatarIndex.of(client);
    addTearDown(index.dispose);
    for (var repeat = 0; repeat < 3; repeat++) {
      for (var i = 0; i < rooms.length; i++) {
        expect(
          userAvatarUri(
            rooms[i].unsafeGetUserFromMemoryOrFallback(
              '@missing-$i:example.invalid',
            ),
          ),
          isNull,
        );
      }
    }
    expect(index.debugBuilds, 1);
    expect(index.debugRoomsScanned, 80);

    // Typing/new messages change no loaded photo and keep the index warm.
    client.onSync.add(
      SyncUpdate(
        nextBatch: 'fixture-typing',
        rooms: RoomsUpdate(
          join: {
            rooms.first.id: JoinedRoomUpdate(
              ephemeral: [BasicEvent(type: 'm.typing', content: {})],
            ),
          },
        ),
      ),
    );
    expect(index.photoFor('@missing-0:example.invalid'), isNull);
    expect(index.debugBuilds, 1);
  });

  test('lazy profile changes refresh cached misses and removed photos', () {
    final client = ConversationClient();
    final origin = ConversationRoom(client, '!origin:example.invalid');
    final donor = ConversationRoom(client, '!donor:example.invalid');
    final index = LoadedAvatarIndex.of(client);
    addTearDown(index.dispose);
    const id = '@contact:example.invalid';
    final user = origin.unsafeGetUserFromMemoryOrFallback(id);
    expect(userAvatarUri(user), isNull);
    donor.state(EventTypes.RoomMember, {
      'membership': 'join',
      'avatar_url': 'mxc://example.invalid/loaded-photo',
    }, key: id);
    expect(
      userAvatarUri(user),
      Uri.parse('mxc://example.invalid/loaded-photo'),
    );
    donor.state(EventTypes.RoomMember, {'membership': 'join'}, key: id);
    expect(userAvatarUri(user), isNull);
    expect(index.debugBuilds, 3);
  });

  test('contact indexes keep account boundaries and first-room precedence', () {
    final a = ConversationClient();
    final b = ConversationClient('@other:example.invalid');
    final origin = ConversationRoom(a, '!origin:example.invalid');
    final first = ConversationRoom(a, '!first:example.invalid');
    final second = ConversationRoom(a, '!second:example.invalid');
    final other = ConversationRoom(b, '!origin:example.invalid');
    const id = '@contact:example.invalid';
    first.state(EventTypes.RoomMember, {
      'avatar_url': 'mxc://example.invalid/first-photo',
    }, key: id);
    second.state(EventTypes.RoomMember, {
      'avatar_url': 'mxc://example.invalid/second-photo',
    }, key: id);
    final indexA = LoadedAvatarIndex.of(a);
    final indexB = LoadedAvatarIndex.of(b);
    addTearDown(indexA.dispose);
    addTearDown(indexB.dispose);
    expect(
      userAvatarUri(origin.unsafeGetUserFromMemoryOrFallback(id)),
      Uri.parse('mxc://example.invalid/first-photo'),
    );
    expect(userAvatarUri(other.unsafeGetUserFromMemoryOrFallback(id)), isNull);
    a.rooms.remove(first);
    expect(
      userAvatarUri(origin.unsafeGetUserFromMemoryOrFallback(id)),
      Uri.parse('mxc://example.invalid/second-photo'),
    );
  });
}

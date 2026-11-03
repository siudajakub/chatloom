// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/personal/media/avatar_cache.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';
import '../notion/conversation_timeline_integration_test.dart'
    as support
    show group, mountConversation;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() => AvatarCache.debugSetShared(null));
  tearDown(AvatarCache.debugResetShared);

  for (final merged in [false, true]) {
    for (final source in ['member', 'portal', 'other-room', 'bridge']) {
      testWidgets(
        '${merged ? 'merged' : 'ordinary'} mounted bubble observes $source photo',
        (tester) async {
          final client = ConversationClient();
          final room = ConversationRoom(
            client,
            '!instagram:example.invalid',
            network: 'instagram',
          );
          final other = ConversationRoom(client, '!other:example.invalid');
          final event = room.message(r'$photo', 'Fictional message');
          final personal = ConversationPersonal(client);
          addTearDown(personal.dispose);
          final timeline = Timeline(
            room: room,
            chunk: TimelineChunk(events: [event]),
          );
          final scroll = ScrollController();
          addTearDown(timeline.cancelSubscriptions);
          addTearDown(scroll.dispose);
          await support.mountConversation(
            tester,
            merged
                ? MergedChatPage(
                    personal: personal,
                    group: support.group(personal, room, other),
                  )
                : Scaffold(
                    body: Message(
                      event,
                      bigEmojis: const {},
                      onInfoTab: (_) {},
                      scrollToEventId: (_) {},
                      onSwipe: () {},
                      timeline: timeline,
                      onMention: () {},
                      scrollController: scroll,
                      enterThread: null,
                    ),
                  ),
            client,
          );
          final bubbleAvatar = find.descendant(
            of: find.byType(Message),
            matching: find.byType(Avatar),
          );
          expect(bubbleAvatar, findsOneWidget);
          expect(tester.widget<Avatar>(bubbleAvatar).mxContent, isNull);
          final mountedAvatar = tester.element(bubbleAvatar);
          final photo = Uri.parse(
            'mxc://example.invalid/photo-$source-$merged',
          );
          void update(Uri? uri) {
            switch (source) {
              case 'member':
              case 'other-room':
                (source == 'member' ? room : other)
                    .state(EventTypes.RoomMember, {
                      'membership': 'join',
                      'displayname': 'Anna',
                      'avatar_url': uri?.toString() ?? '',
                    }, key: '@anna:example.invalid');
              case 'portal':
                room.state(EventTypes.RoomAvatar, {
                  'url': uri?.toString() ?? '',
                });
              case 'bridge':
                room.state('m.bridge', {
                  'protocol': {'id': 'instagram'},
                  'channel': {'avatar_url': uri?.toString() ?? ''},
                }, key: 'fixture');
            }
          }

          update(photo);
          await tester.pumpAndSettle();
          expect(tester.widget<Avatar>(bubbleAvatar).mxContent, photo);
          expect(tester.element(bubbleAvatar), same(mountedAvatar));
          final replacement = photo.replace(path: '${photo.path}-updated');
          update(replacement);
          await tester.pumpAndSettle();
          expect(tester.widget<Avatar>(bubbleAvatar).mxContent, replacement);
          update(null);
          await tester.pumpAndSettle();
          expect(tester.widget<Avatar>(bubbleAvatar).mxContent, isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          update(photo);
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

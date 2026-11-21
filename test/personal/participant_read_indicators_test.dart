// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/pages/chat/seen_by_row.dart';
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/delivery_ticks.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

const _bot = '@bridge:example.invalid';
const _flaggedBot = '@service:example.invalid';
const _anna = '@anna:example.invalid';
const _bob = '@bob:example.invalid';

void main() {
  test('participant count keeps unloaded humans and excludes joined bots', () {
    final room =
        ConversationRoom(ConversationClient(), '!group:example.invalid')
          ..state('m.bridge', {'bridgebot': _bot}, key: 'fixture')
          ..state(EventTypes.RoomMember, {'membership': 'join'}, key: _bot)
          ..state(EventTypes.RoomMember, {
            'membership': 'invite',
            'com.beeper.bridge.is_bridge_bot': true,
          }, key: _flaggedBot)
          ..summary = RoomSummary.fromJson({
            'm.joined_member_count': 10,
            'm.invited_member_count': 2,
          });
    expect(humanParticipantCount(room), 9);
    expect(humanParticipantCount(room, includeInvited: true), 10);

    room.state(EventTypes.RoomMember, {'membership': 'leave'}, key: _bot);
    expect(humanParticipantCount(room), 10);
    room.summary = RoomSummary.fromJson({});
    expect(humanParticipantCount(room), 2);
  });

  test('default left swipe moves eligible unread chats', () {
    const choice = InboxSwipeChoice.archive;
    expect(
      choice.forLeftSwipe(unread: true, archived: false),
      InboxSwipeChoice.moveDown,
    );
    expect(choice.forLeftSwipe(unread: true, archived: true), choice);
    expect(choice.forLeftSwipe(unread: false, archived: false), choice);
    expect(
      InboxSwipeChoice.read.forLeftSwipe(unread: true, archived: false),
      InboxSwipeChoice.read,
    );
  });

  test('reader avatars advance within their own source', () async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!first:example.invalid')
      ..state('m.bridge', {'bridgebot': _bot}, key: 'fixture')
      ..state(EventTypes.RoomMember, {
        'membership': 'join',
        'com.beeper.bridge.is_bridge_bot': true,
      }, key: _flaggedBot);
    final other = ConversationRoom(client, '!other:example.invalid');
    final first = room.message(r'$first', 'First', outgoing: true, minute: 1);
    final next = room.message(r'$next', 'Next', outgoing: true, minute: 2);
    final remote = room.message(r'$remote', 'Remote', minute: 3);
    final separate = other.message(
      r'$separate',
      'Separate',
      outgoing: true,
      minute: 2,
    );
    final timeline = await room.getTimeline();
    final otherTimeline = await other.getTimeline();
    final events = [remote, separate, next, first];
    final positions = SeenByPositions(
      events,
      MediaAlbums.of(events),
      (event) => event.room == room ? timeline : otherTimeline,
    );
    final receipts = room.receiptState.global.otherUsers;
    receipts[_anna] = LatestReceiptStateData(first.eventId, 1);
    receipts[_bob] = LatestReceiptStateData(remote.eventId, 2);
    receipts[_bot] = LatestReceiptStateData(remote.eventId, 2);
    receipts[_flaggedBot] = LatestReceiptStateData(remote.eventId, 2);
    var targets = ReceiptTargets.of(room);
    expect(positions.readersOf(first, targets), [_anna]);
    expect(positions.readersOf(next, targets), [_bob]);
    expect(positions.readersOf(separate, ReceiptTargets.of(other)), isEmpty);

    receipts[_anna] = LatestReceiptStateData(remote.eventId, 3);
    targets = ReceiptTargets.of(room);
    expect(positions.readersOf(first, targets), isEmpty);
    expect(positions.readersOf(next, targets), [_anna, _bob]);

    receipts.remove(_bob);
    final fewerReaders = ReceiptTargets.of(room);
    expect(fewerReaders, isNot(targets));
    expect(positions.readersOf(next, fewerReaders), [_anna]);
  });

  test('thread readers come from the active thread, not the main timeline', () {
    final room = ConversationRoom(
      ConversationClient(),
      '!thread:example.invalid',
    );
    const thread = r'$root';
    const reply = r'$reply';
    room.receiptState.global.otherUsers[_anna] = LatestReceiptStateData(
      thread,
      1,
    );
    final timelineState = LatestReceiptStateForTimeline.empty();
    timelineState.otherUsers[_bob] = LatestReceiptStateData(reply, 2);
    room.receiptState.byThread[thread] = timelineState;
    expect(ReceiptTargets.of(room).readersAt, {
      thread: {_anna},
    });
    expect(RoomReadReceipts.forThread(room, thread).targets.readersAt, {
      reply: {_bob},
    });
  });

  testWidgets('an avatar moves down to the next outgoing bubble', (
    tester,
  ) async {
    final room = ConversationRoom(
      ConversationClient(),
      '!motion:example.invalid',
    );
    final first = room.message(r'$first', 'First', outgoing: true);
    final next = room.message(r'$next', 'Next', outgoing: true);
    final timeline = await room.getTimeline();
    final events = [next, first];
    final positions = SeenByPositions(
      events,
      MediaAlbums.of(events),
      (_) => timeline,
    );
    final receipts = RoomReadReceipts.of(room);
    final byUser = room.receiptState.global.otherUsers;
    byUser[_anna] = LatestReceiptStateData(first.eventId, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final event in [first, next])
                ConversationBubble(
                  key: ValueKey(event.eventId),
                  outgoing: true,
                  body: Text(event.body),
                  footer: SeenByRow(event: event, positions: positions),
                ),
            ],
          ),
        ),
      ),
    );
    Finder avatarUnder(Event event) => find.descendant(
      of: find.byKey(ValueKey(event.eventId)),
      matching: find.byType(Avatar),
    );
    expect(avatarUnder(first), findsOneWidget);
    expect(avatarUnder(next), findsNothing);

    byUser[_anna] = LatestReceiptStateData(next.eventId, 2);
    receipts.refresh();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(avatarUnder(first), findsNothing);
    final avatar = avatarUnder(next);
    final text = find.text('Next');
    expect(avatar, findsOneWidget);
    expect(
      tester.getTopRight(avatar).dx,
      greaterThan(tester.getTopRight(text).dx),
    );
    expect(
      tester.getTopRight(avatar).dy,
      greaterThan(tester.getBottomRight(text).dy),
    );
    expect(NotionMotion.reduced(tester.element(avatar)), isFalse);
  });
}

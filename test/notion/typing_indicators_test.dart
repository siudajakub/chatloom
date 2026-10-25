// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/typing_indicators.dart';
import 'package:chatloom/personal/conversation_activity.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show ChatTheme;
import 'package:shared_preferences/shared_preferences.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('No IO');
}

class _Client extends Client {
  // Geometry tests must not expire while a shared host is stalled in swap.
  _Client()
    : super(
        'typing layout',
        database: _Database(),
        typingIndicatorTimeout: const Duration(hours: 1),
      );
  @override
  String get userID => '@owner:example.invalid';
}

class _Source implements ConversationTimelineSource {
  _Source(this.room);
  @override
  final Room room;
  @override
  List<Room> get typingRooms => [room];
  @override
  List<Event> get conversationEvents => [];
  @override
  ({ChatTheme? theme}) get conversationPalette => (theme: null);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unused');
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  for (final scale in [1.0, 2.0]) {
    for (final direction in TextDirection.values) {
      testWidgets('typing matches message geometry at $scale in $direction', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 800);
        addTearDown(tester.view.reset);
        final client = _Client();
        final room = Room(
          id: '!fixture:example.invalid',
          client: client,
          membership: Membership.join,
          summary: RoomSummary.fromJson({
            'm.joined_member_count': 2,
            'm.invited_member_count': 0,
          }),
        );
        client.rooms.add(room);
        const peer = '@peer:example.invalid';
        room.setState(
          Event(
            room: room,
            type: EventTypes.RoomMember,
            stateKey: peer,
            senderId: peer,
            eventId: '\$peer',
            originServerTs: DateTime.utc(2026),
            content: {'membership': 'join', 'displayname': 'Alex'},
          ),
        );
        room.setState(
          Event(
            room: room,
            type: EventTypes.RoomMember,
            stateKey: client.userID,
            senderId: client.userID,
            eventId: '\$owner',
            originServerTs: DateTime.utc(2026),
            content: {'membership': 'join', 'displayname': 'Owner'},
          ),
        );
        room.ephemerals['m.typing'] = BasicEvent(
          type: 'm.typing',
          content: {
            'user_ids': [peer],
          },
        );
        expect(room.membership, Membership.join);
        final activity = ConversationActivity(client: client, rooms: [room]);
        void observe() {}
        activity.addListener(observe);
        expect(activity.typing.map((entry) => entry.user.id), [peer]);
        activity.dispose();
        await tester.pumpWidget(
          MaterialApp(
            theme: NotionTheme.build(Brightness.dark),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(390, 800),
                disableAnimations: true,
                textScaler: TextScaler.linear(scale),
              ),
              child: Directionality(
                textDirection: direction,
                child: Scaffold(
                  body: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: NotionSpace.sm,
                        ),
                        child: ConversationBubble(
                          key: ValueKey('message'),
                          outgoing: false,
                          avatar: SizedBox.expand(
                            key: ValueKey('message-avatar'),
                          ),
                          body: Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: NotionSpace.xxs / 2,
                            ),
                            child: Text('Hello', style: NotionType.body),
                          ),
                        ),
                      ),
                      TypingIndicators(_Source(room)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        // Wait for asynchronous MaterialApp localization before measuring.
        await tester.pumpAndSettle();
        // Exercise a live typing update, as the open timeline receives it.
        client.onSync.add(
          SyncUpdate(
            nextBatch: 'typing-fixture',
            rooms: RoomsUpdate(
              join: {
                room.id: JoinedRoomUpdate(
                  ephemeral: [room.ephemerals['m.typing']!],
                ),
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final typing = find.byType(TypingIndicators);
        expect(typing, findsOneWidget);
        final avatar = find.descendant(
          of: typing,
          matching: find.byType(Avatar),
        );
        expect(avatar, findsOneWidget);
        final messageAvatar = find.byKey(const ValueKey('message-avatar'));
        expect(tester.getSize(avatar), tester.getSize(messageAvatar));
        expect(
          tester.getTopLeft(avatar).dx,
          tester.getTopLeft(messageAvatar).dx,
        );
        Finder fill(Finder parent) =>
            find.descendant(of: parent, matching: find.byType(ClipRRect)).last;
        final typingFill = fill(typing);
        final messageFill = fill(find.byKey(const ValueKey('message')));
        expect(
          tester.getSize(typingFill).height,
          closeTo(tester.getSize(messageFill).height, 1),
        );
        final typingRect = tester.getRect(typingFill);
        final messageRect = tester.getRect(messageFill);
        expect(
          direction == TextDirection.ltr ? typingRect.left : typingRect.right,
          direction == TextDirection.ltr ? messageRect.left : messageRect.right,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        OwnSenderResolver.of(client).dispose();
      });
    }
  }
}

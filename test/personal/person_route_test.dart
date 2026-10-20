// SPDX-License-Identifier: AGPL-3.0-or-later
// The merged person chat is a route: locations, notification mapping, child
// source chats and relative chat chrome. Fictional offline fixtures only.
import 'package:chatloom/config/routes.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../notion/conversation_test_support.dart';

String _paths(RouteMatchList match) =>
    match.routes.whereType<GoRoute>().map((route) => route.path).join(' > ');

void main() {
  test('person locations encode the group, source and event', () {
    expect(personChatLocation('person-1'), '/rooms/person/person-1');
    expect(
      personChatLocation(
        'person-1',
        sourceRoomId: '!room:example.invalid',
        eventId: r'$event',
        clientName: 'main',
      ),
      '/rooms/person/person-1?client=main&source=%21room%3Aexample.invalid&event=%24event',
    );
    expect(
      personSourceChatLocation(
        'person-1',
        '!room:example.invalid',
        eventId: r'$event',
      ),
      '/rooms/person/person-1/!room%3Aexample.invalid?event=%24event',
    );
  });

  test('a grouped notification opens the person with its source', () {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!notify:example.invalid');
    final plain = ChatLoomPushPayload('main', room.id, r'$message');
    final reminder = ChatLoomPushPayload(
      'main',
      room.id,
      r'$reminded',
      reminder: true,
    );
    final clientName = client.clientName;
    expect(
      notificationRoute(client, room.id, plain),
      '/rooms/${room.id}?client=$clientName',
    );
    expect(
      Uri.parse(
        notificationRoute(client, room.id, plain, personGroupId: 'person-1'),
      ),
      Uri(
        path: '/rooms/person/person-1',
        queryParameters: {'client': clientName, 'source': room.id},
      ),
    );
    expect(
      Uri.parse(
        notificationRoute(client, room.id, reminder, personGroupId: 'person-1'),
      ).queryParameters,
      {'client': clientName, 'source': room.id, 'event': r'$reminded'},
    );
  });

  test('an ungrouped room opens itself', () {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!alone:example.invalid');
    expect(
      conversationLocation(room, eventId: r'$event'),
      '/rooms/!alone:example.invalid?event=%24event',
    );
  });

  testWidgets('the person route precedes room ids and owns source chats', (
    tester,
  ) async {
    final router = GoRouter(routes: AppRoutes.routes);
    addTearDown(router.dispose);
    final person = router.configuration.findMatch(
      Uri.parse('/rooms/person/person-1?source=!a:example.invalid'),
    );
    expect(_paths(person), '/rooms > person/:groupId');
    expect(person.pathParameters, {'groupId': 'person-1'});

    final source = router.configuration.findMatch(
      Uri.parse('/rooms/person/person-1/!a:example.invalid'),
    );
    expect(_paths(source), '/rooms > person/:groupId > :roomid');
    expect(source.pathParameters, {
      'groupId': 'person-1',
      'roomid': '!a:example.invalid',
    });

    final details = router.configuration.findMatch(
      Uri.parse('/rooms/person/person-1/!a:example.invalid/details'),
    );
    expect(_paths(details), '/rooms > person/:groupId > :roomid > details');

    final ordinary = router.configuration.findMatch(
      Uri.parse('/rooms/!a:example.invalid/details'),
    );
    expect(_paths(ordinary), '/rooms > :roomid > details');
  });

  testWidgets('chat chrome stays under the person route', (tester) async {
    final seen = <String>[];
    Widget probe(String roomId) => Builder(
      builder: (context) {
        seen.add(chatLocation(context, roomId));
        return const SizedBox.shrink();
      },
    );
    final router = GoRouter(
      initialLocation: '/rooms/person/person-1/!a:example.invalid',
      routes: [
        GoRoute(
          path: '/rooms/person/:groupId/:roomid',
          builder: (context, state) => probe(state.pathParameters['roomid']!),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (context, state) => probe(state.pathParameters['roomid']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(seen.last, '/rooms/person/person-1/!a:example.invalid');

    router.go('/rooms/!b:example.invalid');
    await tester.pumpAndSettle();
    expect(seen.last, '/rooms/!b:example.invalid');
  });
}

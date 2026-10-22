// SPDX-License-Identifier: AGPL-3.0-or-later
// Day separators and the floating date pill (review UX-10), plus the
// header subtitle (UX-18). Fictional offline fixtures only.
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_app_bar_title.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// Group chat (no direct-chat mapping): the subtitle counts members.
class _GroupClient extends ConversationClient {
  @override
  Map<String, List<String>> get directChats => const {};
}

Event _onDay(ConversationRoom room, int day, int index) {
  final event = Event(
    room: room,
    eventId: '\$day-$day-$index',
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    originServerTs: DateTime.utc(2026, 10, day, 12, index),
    content: {
      'msgtype': MessageTypes.Text,
      'body': 'Fictional day $day message $index',
    },
  );
  room.sourceEvents.insert(0, event);
  return event;
}

Future<void> _mount(WidgetTester tester, Client client, Widget home) async {
  final state = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: state,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: home,
      ),
    ),
  );
}

Finder get _pill => find.byKey(const ValueKey('conversation-date-pill'));

double _pillOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.ancestor(of: _pill, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('UX-10 dates', () {
    late ConversationClient client;
    late ConversationRoom room;
    late ConversationPersonal personal;

    setUp(() {
      client = ConversationClient();
      room = ConversationRoom(client, '!dates:example.invalid');
      for (var day = 10; day < 16; day++) {
        for (var i = 0; i < 8; i++) {
          _onDay(room, day, i);
        }
      }
      personal = ConversationPersonal(client);
      PersonalClient.debugUse(client, personal);
    });
    tearDown(() => personal.dispose());

    testWidgets('day separators are centred pills', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, client, ChatPageWithRoom(room: room));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ChatEventList));
      final label = DateTime.utc(2026, 10, 15, 12).localizedDate(context);
      final chip = find.widgetWithText(ConversationDayChip, label);
      expect(chip, findsOneWidget);
      final list = tester.getRect(find.byType(ListView).first);
      expect(tester.getCenter(chip).dx, closeTo(list.center.dx, 1));
      // No pill while nothing scrolls.
      expect(_pill, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('a floating day pill shows while scrolling, then fades', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, client, ChatPageWithRoom(room: room));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ChatEventList));
      final days = {
        for (var day = 10; day < 16; day++)
          DateTime.utc(2026, 10, day, 12).localizedDate(context),
      };
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView).first),
      );
      // A slow drag: the pill names the day of the topmost row (it steps
      // aside while that day's own separator is right under it).
      final shown = <String>{};
      var opacity = 0.0;
      for (var i = 0; i < 24; i++) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        if (_pill.evaluate().isNotEmpty) {
          opacity = math.max(opacity, _pillOpacity(tester));
          shown.add(tester.widget<ConversationDayChip>(_pill).label);
        }
      }
      expect(shown, isNotEmpty);
      expect(opacity, 1);
      expect(days.containsAll(shown), isTrue);
      // Still there right after the list stops, gone after the hold.
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.pump(ConversationMotion.dateHold);
      await tester.pumpAndSettle();
      expect(_pill.evaluate().isEmpty || _pillOpacity(tester) == 0, isTrue);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  group('UX-18 header subtitle', () {
    Future<void> mountTitle(
      WidgetTester tester,
      ConversationClient client,
      ConversationRoom room, {
      ConnectionStatusMonitor? monitor,
    }) async {
      await _mount(
        tester,
        client,
        Scaffold(
          body: ChatHeaderSubtitle(room: room, monitor: monitor),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('a direct chat shows its network', (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!subtitle-dm:example.invalid');
      await mountTitle(tester, client, room);
      expect(find.text('WhatsApp'), findsOneWidget);
    });

    testWidgets('a group shows its member count', (tester) async {
      final client = _GroupClient();
      final room = ConversationRoom(client, '!subtitle-group:example.invalid');
      room.summary.mJoinedMemberCount = 5;
      await mountTitle(tester, client, room);
      expect(find.text('5 participants'), findsOneWidget);
    });

    testWidgets('someone typing replaces it, with dots, until they stop', (
      tester,
    ) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!subtitle-typing:example.invalid');
      await mountTitle(tester, client, room);
      room.ephemerals['m.typing'] = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': ['@anna:example.invalid'],
        },
      );
      client.onSync.add(
        SyncUpdate(
          nextBatch: 'fixture',
          rooms: RoomsUpdate(
            join: {
              room.id: JoinedRoomUpdate(
                ephemeral: [
                  BasicEvent(
                    type: 'm.typing',
                    content: {
                      'user_ids': ['@anna:example.invalid'],
                    },
                  ),
                ],
              ),
            },
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('typing…'), findsOneWidget);
      expect(find.byType(NotionTypingDots), findsOneWidget);
      // Own typing is never shown.
      room.ephemerals['m.typing'] = BasicEvent(
        type: 'm.typing',
        content: {
          'user_ids': [client.userID],
        },
      );
      client.onSync.add(
        SyncUpdate(
          nextBatch: 'fixture-2',
          rooms: RoomsUpdate(
            join: {
              room.id: JoinedRoomUpdate(
                ephemeral: [
                  BasicEvent(
                    type: 'm.typing',
                    content: {
                      'user_ids': [client.userID],
                    },
                  ),
                ],
              ),
            },
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('typing…'), findsNothing);
      expect(find.text('WhatsApp'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a connection problem takes precedence', (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(
        client,
        '!subtitle-offline:example.invalid',
      );
      final statuses = StreamController<SyncStatusUpdate>.broadcast();
      addTearDown(statuses.close);
      final monitor = ConnectionStatusMonitor(
        statuses: () => statuses.stream,
        current: () => const SyncStatusUpdate(SyncStatus.error),
        firstSync: () => false,
        hasNetwork: () async => true,
        offlineGrace: Duration.zero,
      );
      addTearDown(monitor.dispose);
      await mountTitle(tester, client, room, monitor: monitor);
      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.text('WhatsApp'), findsNothing);
      statuses.add(const SyncStatusUpdate(SyncStatus.finished));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Connecting…'), findsNothing);
      expect(find.text('WhatsApp'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

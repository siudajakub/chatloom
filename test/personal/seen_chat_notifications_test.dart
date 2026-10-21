// SPDX-License-Identifier: AGPL-3.0-or-later
// Review R3: reading a chat in the app clears its notification locally, with
// no receipt (incognito is the default). Fictional offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/seen_chat_notifications.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Plugin implements FlutterLocalNotificationsPlugin {
  final active = <ActiveNotification>[];
  final cancelled = <int>[];
  final shown = <int>[];
  int queries = 0;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => shown.add(id);

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async {
    queries++;
    return List.of(active);
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelled.add(id);
    active.removeWhere((n) => n.id == id);
  }

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected notification operation');
}

class _Page extends StatefulWidget {
  final List<Room> rooms;
  final ValueNotifier<bool> atBottom;
  const _Page({required this.rooms, required this.atBottom, super.key});
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  /// What chat.dart / merged_chat_page.dart do from their seen pass.
  void report() => SeenChatNotifications.seen(
    context,
    widget.rooms,
    atBottom: () => widget.atBottom.value,
  );

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Event _message(Room room, String id) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: '@anna:example.invalid',
  originServerTs: DateTime.utc(2026, 10, 20, 12),
  content: {'msgtype': MessageTypes.Text, 'body': 'Fictional text'},
);

void main() {
  late _Plugin plugin;
  late bool visible;
  late ConversationClient client;
  late ConversationRoom first, second, other;
  final bottom = ValueNotifier(true);
  final key = GlobalKey<_PageState>();

  int idOf(Room room) => messageNotificationId(client.clientName, room.id);
  ActiveNotification notification(Room room) =>
      ActiveNotification(id: idOf(room), groupKey: client.clientName);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    debugAppLockConfigured = () async => false;
  });

  tearDownAll(() => debugAppLockConfigured = null);

  setUp(() {
    plugin = _Plugin();
    visible = true;
    bottom.value = true;
    SeenChatNotifications.debugPlugin = () => plugin;
    SeenChatNotifications.debugSurfaceVisible = () => visible;
    SeenChatNotifications.debugUpdatesSummary = true;
    SeenChatNotifications.debugReset();
    client = ConversationClient();
    first = ConversationRoom(client, '!first:example.invalid');
    second = ConversationRoom(client, '!second:example.invalid');
    other = ConversationRoom(client, '!other:example.invalid');
    plugin.active.addAll([
      notification(first),
      notification(second),
      notification(other),
    ]);
  });

  tearDown(() {
    SeenChatNotifications.debugPlugin = null;
    SeenChatNotifications.debugSurfaceVisible = null;
    SeenChatNotifications.debugUpdatesSummary = null;
    SeenChatNotifications.debugReset();
  });

  // The fake plugin completes in microtasks, which every pump flushes.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, List<Room> rooms) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _Page(key: key, rooms: rooms, atBottom: bottom),
      ),
    );
    key.currentState!.report();
    await settle(tester);
  }

  testWidgets('a chat read at its newest message clears its own notification '
      'and refreshes the summary, without touching other chats', (
    tester,
  ) async {
    await open(tester, [first]);
    expect(plugin.cancelled, [idOf(first)]);
    expect(
      plugin.active.map((n) => n.id),
      unorderedEquals([idOf(second), idOf(other)]),
    );
    // Two chats remain: the silent group summary is rebuilt for them.
    expect(plugin.shown, [summaryNotificationId(client.clientName)]);
  });

  testWidgets('a merged person clears every source room it shows', (
    tester,
  ) async {
    await open(tester, [first, second]);
    expect(plugin.cancelled, containsAll([idOf(first), idOf(second)]));
    expect(plugin.active.map((n) => n.id), [idOf(other)]);
    // One chat left: the group summary is removed.
    expect(
      plugin.cancelled,
      contains(summaryNotificationId(client.clientName)),
    );
  });

  testWidgets('scrolled up, locked or in the background nothing is cleared; '
      'unlocking into the open chat clears it', (tester) async {
    bottom.value = false;
    await open(tester, [first]);
    expect(plugin.cancelled, isEmpty);

    bottom.value = true;
    visible = false;
    key.currentState!.report();
    await settle(tester);
    expect(plugin.cancelled, isEmpty);

    // The lock layer goes away: the next visible frame re-checks the page.
    visible = true;
    tester.binding.scheduleFrame();
    await settle(tester);
    expect(plugin.cancelled, [idOf(first)]);
  });

  testWidgets('repeated reports cost nothing until a new message arrives or '
      'the app becomes visible again', (tester) async {
    await open(tester, [first]);
    final queries = plugin.queries;
    key.currentState!.report();
    await settle(tester);
    key.currentState!.report();
    await settle(tester);
    expect(plugin.queries, queries);

    // A push shown while the chat was open in the background.
    plugin.active.add(notification(first));
    first.lastEvent = _message(first, r'$newer');
    key.currentState!.report();
    await settle(tester);
    expect(plugin.cancelled.where((id) => id == idOf(first)), hasLength(2));

    plugin.active.add(notification(first));
    visible = false;
    tester.binding.scheduleFrame();
    await tester.pump();
    visible = true;
    key.currentState!.report();
    await settle(tester);
    expect(plugin.cancelled.where((id) => id == idOf(first)), hasLength(3));
  });

  testWidgets('a page that is not the current route clears nothing, and '
      'open conversations silence their pushes until disposed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _Page(key: key, rooms: [first, second], atBottom: bottom),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(SeenChatNotifications.isOpen(client.clientName, second.id), isFalse);
    key.currentState!.report();
    expect(SeenChatNotifications.isOpen(client.clientName, second.id), isTrue);
    expect(SeenChatNotifications.isOpen(client.clientName, other.id), isFalse);
    expect(SeenChatNotifications.isOpen('another-account', second.id), isFalse);
    visible = false;
    expect(SeenChatNotifications.isOpen(client.clientName, second.id), isFalse);
    visible = true;
    await settle(tester);
    plugin.cancelled.clear();
    plugin.active
      ..clear()
      ..addAll([notification(first), notification(second)]);

    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()),
    );
    await tester.pumpAndSettle();
    first.lastEvent = _message(first, r'$covered');
    key.currentState!.report();
    await settle(tester);
    expect(plugin.cancelled, isEmpty);
    expect(SeenChatNotifications.isOpen(client.clientName, second.id), isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(SeenChatNotifications.isOpen(client.clientName, first.id), isFalse);
  });

  testWidgets('without the active-notification query the ids are cancelled '
      'directly', (tester) async {
    final failing = _FailingQuery();
    SeenChatNotifications.debugPlugin = () => failing;
    await open(tester, [first]);
    expect(failing.cancelled, contains(idOf(first)));
  });
}

class _FailingQuery extends _Plugin {
  @override
  Future<List<ActiveNotification>> getActiveNotifications() =>
      Future.error(UnimplementedError('Synthetic platform without query'));
}

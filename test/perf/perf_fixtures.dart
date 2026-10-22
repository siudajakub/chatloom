// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional, account-free fixtures for the smoothness benchmarks: a large
// inbox and a long conversation built from the offline conversation
// fixtures. No network, no account, no real storage (shared preferences are
// mocked and the private client never opens its database), so they are
// safe on a device next to the real app's data.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/pages/chat_list/chat_list_body.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// Mocked preferences and settings (call once per test process).
Future<void> initPerfSettings() async {
  SharedPreferences.setMockInitialValues({});
  await AppSettings.init(loadWebConfigFile: false);
}

class PerfClient extends ConversationClient {
  PerfClient() : super('@owner:example.invalid');
  @override
  String get prevBatch => 'fictional cursor';
}

class PerfRoom extends ConversationRoom {
  PerfRoom(super.client, super.id);
  int unread = 0;
  @override
  Event? get lastEvent => sourceEvents.firstOrNull;
  @override
  int get notificationCount => unread;
}

const _lines = [
  'Fictional short reply',
  'Are we still on for the fictional meeting tomorrow afternoon?',
  'Sure, see you there',
  'This is a longer fictional message that wraps over two or three lines in a phone-sized bubble, so the list has rows of different heights.',
  'ok',
  'Sending the fictional notes later tonight, they are not finished yet.',
];

/// An account with [rooms] chats, one or two messages each, newest first;
/// every fifth chat has unread messages.
({PerfClient client, List<PerfRoom> rooms}) perfInbox({int rooms = 300}) {
  final client = PerfClient();
  final list = <PerfRoom>[];
  for (var i = 0; i < rooms; i++) {
    final room = PerfRoom(client, '!perf-inbox-$i:example.invalid')
      ..state(EventTypes.RoomName, {'name': 'Fictional chat $i'});
    room.message(
      '\$perf-inbox-$i-a',
      _lines[i % _lines.length],
      minute: rooms * 2 - i * 2,
      outgoing: i.isEven,
    );
    if (i % 5 == 0) room.unread = 1 + i % 4;
    list.add(room);
  }
  PersonalClient.debugUse(client, ConversationPersonal(client));
  return (client: client, rooms: list);
}

/// A chat with [events] messages: alternating senders, varied lengths and a
/// reply every seventh message.
({PerfClient client, PerfRoom room}) perfConversation({int events = 500}) {
  final client = PerfClient();
  final room = PerfRoom(client, '!perf-chat:example.invalid');
  Event? previous;
  for (var i = 0; i < events; i++) {
    final text = '${_lines[i % _lines.length]} ($i)';
    final reply = i % 7 == 0 ? previous : null;
    previous = room.message(
      '\$perf-chat-$i',
      text,
      minute: i,
      outgoing: i % 3 == 0,
      content: reply == null
          ? null
          : {
              'msgtype': MessageTypes.Text,
              'body': text,
              'm.relates_to': {
                'm.in_reply_to': {'event_id': reply.eventId},
              },
            },
    );
  }
  PersonalClient.debugUse(client, ConversationPersonal(client));
  return (client: client, room: room);
}

/// The production inbox body over [client] (no plugins, no push setup).
class PerfInbox extends ChatList {
  const PerfInbox({super.key}) : super(activeChat: null);
  @override
  ChatListController createState() => _PerfInboxController();
}

class _PerfInboxController extends ChatListController {
  @override
  // Native plugins (share intents, call kit, push) are outside the fixture.
  // ignore: must_call_super
  void initState() {
    activeFilter = ActiveFilter.allChats;
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: ChatListViewBody(this));
}

/// The app's dark theme around [home], with [client] as the active account.
Widget perfApp(Client client, Widget home) {
  final matrix = ConversationMatrix(client, AppSettings.store);
  return Provider<MatrixState>.value(
    value: matrix,
    child: MaterialApp(
      theme: NotionTheme.build(Brightness.dark, NotionAppearance.standard),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: home,
    ),
  );
}

/// The production chat page of [room].
Widget perfChatPage(Room room) => ChatPage(roomId: room.id);

/// A sync that touches [rooms] (as the server sends for new messages).
SyncUpdate perfSync(Iterable<Room> rooms, int batch) => SyncUpdate(
  nextBatch: 'fixture-$batch',
  rooms: RoomsUpdate(join: {for (final r in rooms) r.id: JoinedRoomUpdate()}),
);

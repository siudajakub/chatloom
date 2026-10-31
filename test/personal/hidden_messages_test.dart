// SPDX-License-Identifier: AGPL-3.0-or-later
// FX-16 "Remove for you": hidden in ChatLoom only. Fictional offline
// fixtures; no account, no network.

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/local_message_search.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// In-memory stand-in for the encrypted private store.
class _Store implements HiddenMessagesStorage {
  Map<String, dynamic>? value;
  int reads = 0;
  int writes = 0;
  Object? readFailure;
  @override
  Future<Map<String, dynamic>?> read() async {
    reads++;
    if (readFailure != null) throw readFailure!;
    return value;
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    this.value = {
      ...value,
      'keys': List<String>.of(value['keys'] as List<String>),
    };
  }
}

/// A client whose every HTTP request is recorded (and answered 500).
class _NetClient extends Client {
  final requests = <http.BaseRequest>[];
  _NetClient._(MockClient http)
    : super(
        'offline hidden-messages fixture',
        database: ConversationDatabase(),
        httpClient: http,
      );
  factory _NetClient() {
    late final _NetClient client;
    client = _NetClient._(
      MockClient((request) async {
        client.requests.add(request);
        return http.Response('{}', 500);
      }),
    );
    return client;
  }
  @override
  String get userID => '@owner:example.invalid';
}

/// Records any private-journal write (the synced store).
class _Personal extends ConversationPersonal {
  _Personal(super.client);
  final synced = <String>[];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async =>
      synced.add('put $key');
  @override
  Future<void> delete(String key) async => synced.add('delete $key');
  final local = <String, Map<String, dynamic>>{};
  @override
  Future<void> writeLocalRecord(String key, Map<String, dynamic> value) async =>
      local[key] = value;
  @override
  Future<Map<String, dynamic>?> readLocalRecord(String key) async => local[key];
}

/// A sent message whose redaction would be recorded.
class _Message extends Event {
  int redactions = 0;
  _Message(Room room, String id, {String body = 'Fictional text'})
    : super(
        eventId: id,
        senderId: '@anna:example.invalid',
        originServerTs: DateTime(2026, 10, 24, 12),
        type: EventTypes.Message,
        content: {'msgtype': MessageTypes.Text, 'body': body},
        room: room,
        status: EventStatus.synced,
      );
  @override
  Future<String?> redactEvent({
    String? reason,
    String? txid,
    bool redactAllEdits = false,
  }) async {
    redactions++;
    return null;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late _Store store;
  setUp(() {
    store = _Store();
    HiddenMessages.instance.storageFor = (_) => store;
  });
  tearDown(() {
    HiddenMessages.instance.storageFor = HiddenMessages.defaultStorage;
  });

  test('hide filters the row, unhide brings it back', () async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!hide:example.invalid');
    final keep = _Message(room, r'$keep');
    final gone = _Message(room, r'$gone');
    final hidden = HiddenMessages.instance..load(client);
    await _settle();
    var notified = 0;
    void count() => notified++;
    hidden.addListener(count);
    hidden.hide(gone);
    expect(HiddenMessages.hides(gone), isTrue);
    expect(HiddenMessages.hides(keep), isFalse);
    expect([keep, gone].filterByVisibleInGui(), [keep]);
    // Not the delete-for-everyone path.
    expect(MessageDeletions.deleting(gone), isFalse);
    expect(notified, 1);
    hidden.unhide(gone);
    expect([keep, gone].filterByVisibleInGui(), [keep, gone]);
    expect(notified, 2);
    hidden.removeListener(count);
    hidden.debugReset(client);
  });

  test('only sent messages with a server ID can be hidden', () {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!can:example.invalid');
    expect(HiddenMessages.canHide(_Message(room, r'$sent')), isTrue);
    final sending = Event(
      eventId: 'txn-1',
      senderId: client.userID,
      originServerTs: DateTime(2026),
      type: EventTypes.Message,
      content: {'msgtype': MessageTypes.Text, 'body': 'x'},
      room: room,
      status: EventStatus.sending,
    );
    expect(HiddenMessages.canHide(sending), isFalse);
  });

  test('hides persist in the local store and load on the next start', () async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!persist:example.invalid');
    final first = HiddenMessages(storageFor: (_) => store)..load(client);
    await _settle();
    first.hide(_Message(room, r'$a'));
    first.hide(_Message(room, r'$b'));
    first.unhide(_Message(room, r'$a'));
    await _settle();
    expect(store.value?['keys'], ['!persist:example.invalid\u0000\$b']);

    final next = HiddenMessages(storageFor: (_) => store);
    var notified = 0;
    next.addListener(() => notified++);
    next.load(client);
    expect(next.isHidden(_Message(room, r'$b')), isFalse); // still loading
    await _settle();
    expect(next.isHidden(_Message(room, r'$b')), isTrue);
    expect(next.isHidden(_Message(room, r'$a')), isFalse);
    expect(notified, 1);
  });

  test('a failed read never overwrites the stored hides; retry merges', () async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!retry:example.invalid');
    store
      ..value = {
        'v': 1,
        'keys': ['!retry:example.invalid\u0000\$old'],
      }
      ..readFailure = StateError('Encrypted storage is not open');
    final hidden = HiddenMessages(storageFor: (_) => store)..load(client);
    await _settle();
    hidden.hide(_Message(room, r'$new'));
    await _settle();
    expect(store.writes, 0);
    store.readFailure = null;
    hidden.load(client); // the next open retries
    await _settle();
    expect(hidden.isHidden(_Message(room, r'$old')), isTrue);
    expect(hidden.isHidden(_Message(room, r'$new')), isTrue);
    expect(store.value?['keys'], [
      '!retry:example.invalid\u0000\$old',
      '!retry:example.invalid\u0000\$new',
    ]);
  });

  test('bounded: the oldest hide falls out first', () async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!cap:example.invalid');
    final hidden = HiddenMessages(storageFor: (_) => null)..load(client);
    for (var i = 0; i <= HiddenMessages.capacity; i++) {
      hidden.hide(_Message(room, '\$m$i'));
    }
    expect(hidden.isHidden(_Message(room, r'$m0')), isFalse);
    expect(hidden.isHidden(_Message(room, r'$m1')), isTrue);
    expect(hidden.countIn([room]), HiddenMessages.capacity);
  });

  test('chat details: count, show all again, Undo restores', () async {
    final client = ConversationClient();
    final a = ConversationRoom(client, '!a:example.invalid');
    final b = ConversationRoom(client, '!b:example.invalid');
    final hidden = HiddenMessages(storageFor: (_) => null)..load(client);
    hidden
      ..hide(_Message(a, r'$1'))
      ..hide(_Message(a, r'$2'))
      ..hide(_Message(b, r'$3'));
    expect(hidden.countIn([a]), 2);
    expect(hidden.countIn([a, b]), 3);
    final shown = hidden.unhideAll([a]);
    expect(shown, hasLength(2));
    expect(hidden.countIn([a]), 0);
    expect(hidden.isHidden(_Message(b, r'$3')), isTrue);
    hidden.restore(shown);
    expect(hidden.countIn([a]), 2);
  });

  test('search leaves out hidden messages and their edits', () async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!search:example.invalid');
    final hidden = HiddenMessages.instance..load(client);
    await _settle();
    final secret = _Message(room, r'$secret', body: 'apple pie');
    final other = _Message(room, r'$other', body: 'apple tart');
    final edit = Event(
      eventId: r'$edit',
      senderId: '@anna:example.invalid',
      originServerTs: DateTime(2026, 10, 24, 13),
      type: EventTypes.Message,
      content: {
        'msgtype': MessageTypes.Text,
        'body': '* apple crumble',
        'm.new_content': {'msgtype': MessageTypes.Text, 'body': 'apple crumble'},
        'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$secret'},
      },
      room: room,
      status: EventStatus.synced,
    );
    final pool = LocalMessagePool()..add([secret, other, edit]);
    final terms = localSearchTerms('apple');
    expect(
      pool.search(terms).map((h) => h.eventId),
      unorderedEquals([r'$secret', r'$other']),
    );
    hidden.hide(secret);
    // Already read into the pool: filtered at search time.
    expect(pool.search(terms).map((h) => h.eventId), [r'$other']);
    // Read after the hide: never enters the device search.
    final compact = compactMessages([edit, secret, other]);
    expect(compact.map((e) => e.$2.eventId), [r'$other']);
    hidden.debugReset(client);
  });

  test('the default store is the device-local record, never the journal',
      () async {
    final client = _NetClient();
    final personal = _Personal(client);
    final storage = PersonalHiddenMessagesStorage(personal);
    await storage.write({
      'v': 1,
      'keys': ['!r:example.invalid\u0000\$x'],
    });
    expect(await storage.read(), isNotNull);
    expect(personal.local.keys, [PersonalHiddenMessagesStorage.key]);
    expect(personal.synced, isEmpty);
    expect(client.requests, isEmpty);
  });

  testWidgets('Remove for you: snackbar explains, Undo shows it again, '
      'nothing is redacted, sent or synced', (tester) async {
    final client = _NetClient();
    final personal = _Personal(client);
    PersonalClient.debugUse(client, personal);
    final room = ConversationRoom(client, '!local:example.invalid');
    final event = _Message(room, r'$local');
    HiddenMessages.instance.load(client);
    await tester.runAsync(_settle);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    var refreshes = 0;
    HiddenMessages.hideWithUndo(context, event, refresh: () => refreshes++);
    await tester.pump();
    expect([event].filterByVisibleInGui(), isEmpty);
    expect(refreshes, 1);
    expect(
      find.text('Removed for you. It stays in the chat on WhatsApp.'),
      findsOneWidget,
    );
    // The action itself (the snackbar is still sliding in).
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await tester.pump();
    expect([event].filterByVisibleInGui(), [event]);
    expect(refreshes, 2);
    await tester.runAsync(_settle);

    // Only the device-local store was written.
    expect(store.writes, greaterThan(0));
    expect(event.redactions, 0);
    expect(client.requests, isEmpty);
    expect(personal.synced, isEmpty);
    expect(MessageDeletions.deleting(event), isFalse);
    HiddenMessages.instance.debugReset(client);
  });
}

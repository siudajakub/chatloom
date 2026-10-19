// SPDX-License-Identifier: AGPL-3.0-or-later
// "Waiting for this message": one renderer for ordinary and merged chats.
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/chat/events/message_content.dart';
import 'package:fluffychat/pages/chat/events/undecryptable_message.dart';
import 'package:fluffychat/pages/chat/events/waiting_message_view.dart';
import 'package:fluffychat/pages/chat/matrix_conversation_grouping.dart';
import 'package:fluffychat/pages/chat/undecryptable_chat_hint.dart';
import 'package:fluffychat/personal/encryption/undecryptable_messages.dart';
import 'package:fluffychat/ui/notion/notion_theme.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart' show DecryptException;
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  late Client client;
  late Room room;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  setUp(() {
    client = Client('undecryptable bubble', database: _UnusedDatabase());
    room = Room(id: '!room:example.invalid', client: client);
  });

  Event locked({bool redacted = false}) => Event(
    content: {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
      'ciphertext': 'opaque',
      'session_id': 'session-a',
      'msgtype': MessageTypes.BadEncrypted,
      'body': DecryptException.unknownSession,
      'can_request_session': true,
    },
    type: EventTypes.Encrypted,
    eventId: r'$locked',
    senderId: '@sender:example.invalid',
    originServerTs: DateTime.utc(2026),
    room: room,
    unsigned: redacted
        ? {
            'redacted_because': {
              'type': EventTypes.Redaction,
              'event_id': r'$redaction',
              'sender': '@sender:example.invalid',
              'origin_server_ts': 0,
              'content': <String, Object?>{},
            },
          }
        : null,
  );

  testWidgets('MessageContent renders the waiting bubble, not the raw body', (
    tester,
  ) async {
    final event = locked();
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    addTearDown(timeline.cancelSubscriptions);
    await tester.pumpWidget(
      _app(
        MessageContent(
          event,
          timeline: timeline,
          textColor: const Color(0xFFE8E7E5),
          linkColor: const Color(0xFFE8E7E5),
          borderRadius: BorderRadius.zero,
          selected: false,
          bigEmojis: const {},
        ),
      ),
    );
    expect(find.byType(UndecryptableMessage), findsOneWidget);
    expect(find.text(DecryptException.unknownSession), findsNothing);
    expect(find.text('Waiting for this message'), findsOneWidget);
    await tester.pump();
    // This synthetic client has no encryption, so asking cannot help.
    expect(find.text('Can’t decrypt this message'), findsOneWidget);
    expect(
      UndecryptableMessages.of(client).stageOf(event),
      KeyRecoveryStage.permanent,
    );
  });

  test('undecryptable messages group and never fold into state', () {
    final event = locked();
    expect(isUndecryptable(event), isTrue);
    expect(event.isCollapsedState, isFalse);
    expect(conversationGroupingItem(event).boundary, isFalse);
    final redacted = locked(redacted: true);
    expect(isUndecryptable(redacted), isFalse);
    expect(conversationGroupingItem(redacted).boundary, isTrue);
  });

  testWidgets('each stage says what is happening; stuck ones offer a step', (
    tester,
  ) async {
    var retried = 0;
    var verified = 0;
    Future<void> show(KeyRecoveryStage? stage) => tester.pumpWidget(
      _app(
        WaitingMessageView(
          stage: stage,
          textColor: const Color(0xFFE8E7E5),
          onRetry: () => retried++,
          onVerify: () => verified++,
        ),
      ),
    );
    for (final stage in [
      null,
      KeyRecoveryStage.backup,
      KeyRecoveryStage.devices,
      KeyRecoveryStage.keyReceived,
    ]) {
      await show(stage);
      expect(find.text(WaitingMessageView.detail(stage)), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    }
    await show(KeyRecoveryStage.failed);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
    await show(KeyRecoveryStage.verifySession);
    await tester.tap(find.text('Verify session'));
    expect(verified, 1);
    await show(KeyRecoveryStage.permanent);
    expect(find.text('Can’t decrypt this message'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });

  test('retryEach asks each event through its own account', () {
    final other = Client('other account', database: _UnusedDatabase());
    final otherRoom = Room(id: '!other:example.invalid', client: other);
    final mine = locked();
    final theirs = Event(
      content: mine.content,
      type: EventTypes.Encrypted,
      eventId: r'$theirs',
      senderId: '@sender:example.invalid',
      originServerTs: DateTime.utc(2026),
      room: otherRoom,
    );
    expect(UndecryptableMessages.retryEach([mine, theirs]), 2);
    // Neither synthetic client has encryption: each tracker settles its own
    // event, and never the other account's.
    expect(
      UndecryptableMessages.of(client).stageOf(mine),
      KeyRecoveryStage.permanent,
    );
    expect(
      UndecryptableMessages.of(other).stageOf(theirs),
      KeyRecoveryStage.permanent,
    );
    expect(UndecryptableMessages.of(other).stageOf(mine), isNull);
  });

  testWidgets('chat header hint counts and opens the fix', (tester) async {
    var fixes = 0;
    await tester.pumpWidget(
      _app(UndecryptableChatHint(count: 3, onFix: () => fixes++)),
    );
    expect(find.text('3 messages couldn’t be decrypted'), findsOneWidget);
    await tester.tap(find.text('Fix'));
    expect(fixes, 1);
    expect(UndecryptableChatHint.label(1), '1 message couldn’t be decrypted');
  });
}

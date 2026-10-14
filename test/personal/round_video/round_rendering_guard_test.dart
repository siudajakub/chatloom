import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/chat/events/message_content.dart';
import 'package:fluffychat/pages/chat/events/round_video_bridge_message.dart';
import 'package:fluffychat/pages/chat/events/round_video_message.dart';
import 'package:fluffychat/pages/chat/events/video_player.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('renderer must not access database');
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets('strict marker selects the round renderer', (tester) async {
    await _render(tester, {
      'msgtype': 'm.video',
      'body': 'fixture.mp4',
      'info': {'fi.mau.telegram.round_message': true},
    }, (widget) => expect(widget, isA<RoundVideoBridgeMessage>()));
  });
  testWidgets('string marker retains ordinary video', (tester) async {
    await _render(tester, {
      'msgtype': 'm.video',
      'body': 'fixture.mp4',
      'info': {'fi.mau.telegram.round_message': 'true', 'w': 384, 'h': 384},
    }, (widget) => expect(widget, isA<EventVideoPlayer>()));
  });
  for (final type in ['m.video', 'm.image', 'm.audio', 'm.file', 'm.notice']) {
    testWidgets('TTL guard precedes $type renderer and thumbnail', (
      tester,
    ) async {
      await _render(tester, {
        'msgtype': type,
        'body': 'limited fixture',
        'url': 'mxc://example.invalid/fixture',
        'info': {'thumbnail_url': 'mxc://example.invalid/thumbnail'},
        'pl.personal.chat.telegram.media_policy': {
          'version': 1,
          'transfer_allowed': false,
          'reason': 'time_limited',
          'ttl_seconds': 15,
          'view_once': false,
          'protected_content': null,
          'lazy_supported': false,
        },
      }, (widget) => expect(widget, isA<RoundVideoMessage>()));
    });
  }
  test('protected and limited attachments cannot be exported or thumbed', () {
    final client = Client('guard fixture', database: _UnusedDatabase());
    final room = Room(id: '!fixture:example.invalid', client: client);
    for (final protective in [
      {'protected_content': true},
      {'view_once': true},
      {'ttl_seconds': 1},
    ]) {
      final event = Event(
        type: EventTypes.Message,
        room: room,
        eventId: r'$fixture',
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {
          'msgtype': 'm.video',
          'body': 'fixture',
          'url': 'mxc://example.invalid/fixture',
          'info': {'fi.mau.telegram.round_message': true},
          ...protective,
        },
      );
      expect(event.personalMediaExportAllowed, isFalse);
      expect(event.showThumbnail, isFalse);
    }
  });
}

Future<void> _render(
  WidgetTester tester,
  Map<String, dynamic> content,
  void Function(Widget) verify,
) async {
  final client = Client('render fixture', database: _UnusedDatabase());
  final room = Room(id: '!fixture:example.invalid', client: client);
  final event = Event(
    content: content,
    type: EventTypes.Message,
    eventId: r'$fixture',
    senderId: '@fixture:example.invalid',
    originServerTs: DateTime.utc(2026),
    room: room,
  );
  final timeline = Timeline(
    room: room,
    chunk: TimelineChunk(events: [event]),
  );
  addTearDown(timeline.cancelSubscriptions);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          verify(
            MessageContent(
              event,
              timeline: timeline,
              textColor: Colors.black,
              linkColor: Colors.blue,
              borderRadius: BorderRadius.zero,
              selected: false,
              bigEmojis: const {},
            ).build(context),
          );
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  expect(tester.takeException(), isNull);
}

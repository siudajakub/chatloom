import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/image_bubble.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  for (final geo in <String?>[null, '', 'geo:NaN,NaN', 'geo:91,181']) {
    testWidgets('malformed bridged location $geo falls back to text', (
      tester,
    ) async {
      await _renderContent(tester, {
        'msgtype': MessageTypes.Location,
        'body': 'Shared location',
        'geo_uri': ?geo,
      }, (rendered) => expect(rendered, isA<Padding>()));
    });
  }

  testWidgets('zero image dimensions retain finite default size', (
    tester,
  ) async {
    await _renderContent(
      tester,
      {
        'msgtype': MessageTypes.Image,
        'body': 'Image',
        'info': {'w': 0, 'h': 0},
      },
      (rendered) {
        expect(rendered, isA<ImageBubble>());
        final image = rendered as ImageBubble;
        // The one media rule: a square at the media width.
        expect(image.width, NotionBubble.mediaMaxWidth);
        expect(image.height, NotionBubble.mediaMaxWidth);
      },
    );
  });
}

Future<void> _renderContent(
  WidgetTester tester,
  Map<String, dynamic> content,
  void Function(Widget) verify,
) async {
  final client = Client(
    'synthetic bridged message',
    database: _UnusedDatabase(),
  );
  final room = Room(id: '!synthetic:example.invalid', client: client);
  final event = Event(
    content: content,
    type: EventTypes.Message,
    eventId: r'$synthetic',
    senderId: '@sender:example.invalid',
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
          final rendered = MessageContent(
            event,
            timeline: timeline,
            textColor: Colors.black,
            linkColor: Colors.blue,
            borderRadius: BorderRadius.zero,
            selected: false,
            bigEmojis: const {},
          ).build(context);
          verify(rendered);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  expect(tester.takeException(), isNull);
}

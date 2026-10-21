// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

Event _event() => Event(
  room: Room(
    id: '!actions:example.invalid',
    client: Client('actions fixture', database: _UnusedDatabase()),
  ),
  eventId: r'$actions-round',
  senderId: '@fixture:example.invalid',
  type: EventTypes.Message,
  originServerTs: DateTime.utc(2026),
  content: {
    'msgtype': 'm.video',
    'body': 'fixture.mp4',
    'info': {'fi.mau.telegram.round_message': true, 'duration': 10000},
  },
);

void main() {
  testWidgets('inline round groups save, forward and transcribe in one menu', (
    tester,
  ) async {
    final calls = <String>[];
    final event = _event();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoundVideoMessage(
            event,
            showThumbnail: false,
            enlargeOnPlay: false,
            coordinator: RoundPlaybackCoordinator(),
            sourceAvailable: () => true,
            onExport: (_) async => calls.add('save'),
            onForward: (_) async => calls.add('forward'),
            onTranscribe: (_) async => calls.add('transcribe'),
          ),
        ),
      ),
    );
    expect(find.byTooltip('More options'), findsOneWidget);
    expect(find.byTooltip('Save round video'), findsNothing);
    expect(find.byTooltip('Forward in Telegram'), findsNothing);
    expect(find.byTooltip('Transcribe'), findsNothing);
    for (final entry in <String, String>{
      'Save round video': 'save',
      'Forward in Telegram': 'forward',
      'Transcribe': 'transcribe',
    }.entries) {
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(calls.last, entry.value);
    }
    expect(calls, ['save', 'forward', 'transcribe']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

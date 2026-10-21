// SPDX-License-Identifier: AGPL-3.0-or-later
// Delivery status of photos, videos, voice, files and round videos in their
// own bubble: sending (with the upload), sent, "Not sent · Tap to retry".
// Fictional offline fixtures only; no accounts, network or storage.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/events/outgoing_upload_progress.dart';
import 'package:chatloom/pages/chat/events/round_video_view.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/upload_progress.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../personal/outgoing_media_support.dart';
import 'conversation_test_support.dart';

class _FileRoom extends ConversationRoom {
  final sent = <({String name, String? txid})>[];
  _FileRoom(Client client) : super(client, '!files:example.invalid');

  @override
  Future<Event?> getEventById(String eventID) async => null;

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    sent.add((name: file.name, txid: txid));
    return r'$accepted';
  }
}

Event _ownFile(
  ConversationRoom room,
  String txid, {
  required String msgtype,
  EventStatus status = EventStatus.sending,
}) {
  final event = Event(
    room: room,
    eventId: txid,
    type: EventTypes.Message,
    senderId: room.client.userID!,
    originServerTs: DateTime.utc(2026, 10, 21, 12),
    status: status,
    content: {
      'msgtype': msgtype,
      'body': 'fictional.bin',
      'filename': 'fictional.bin',
      'info': {'mimetype': 'application/octet-stream', 'size': 3},
    },
    unsigned: {'transaction_id': txid},
  );
  room.sourceEvents.insert(0, event);
  return event;
}

Future<void> _mount(WidgetTester tester, Client client, Widget home) async {
  final matrix = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: matrix,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: home,
      ),
    ),
  );
}

Widget _message(Event event, Timeline timeline) => Scaffold(
  body: Center(
    child: Message(
      event,
      bigEmojis: const {},
      onInfoTab: (_) {},
      scrollToEventId: (_) {},
      onSwipe: () {},
      timeline: timeline,
      onMention: () {},
      scrollController: ScrollController(),
      enterThread: null,
    ),
  ),
);

/// Reports [sent] of [total] bytes for [txid], as an upload would.
Future<void> _progress(String txid, int sent, int total) =>
    UploadProgress.track(txid, () async {
      UploadProgress.current!.update(#file, sent, total);
    });

double? _ringValue(WidgetTester tester, Finder within) => tester
    .widget<CircularProgressIndicator>(
      find.descendant(
        of: within,
        matching: find.byKey(const ValueKey('outgoing-upload-indicator')),
      ),
    )
    .value;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(UploadProgress.debugClear);

  testWidgets('a sending file says "Sending" and fills its ring', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!upload:example.invalid');
    final event = _ownFile(room, 'upload-1', msgtype: MessageTypes.File);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: room.sourceEvents),
    );
    addTearDown(timeline.cancelSubscriptions);
    await _mount(tester, client, _message(event, timeline));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    final l10n = L10n.of(tester.element(find.byType(Message)));
    expect(find.text(l10n.sending), findsOneWidget);
    // No phase words, and no clock: the upload has its own ring.
    expect(find.text(l10n.uploading), findsNothing);
    expect(find.text(l10n.encrypting), findsNothing);
    final chip = find.ancestor(
      of: find.text(l10n.sending),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: chip.first, matching: find.byIcon(Icons.schedule)),
      findsNothing,
    );
    expect(_ringValue(tester, chip.first), isNull, reason: 'preparing');
    await _progress('upload-1', 40, 100);
    await tester.pump();
    expect(_ringValue(tester, chip.first), closeTo(.4, .001));
    // The file row's own indicator follows the same upload.
    expect(
      find.byKey(const ValueKey('outgoing-upload-indicator')),
      findsNWidgets(2),
    );
  });

  testWidgets('a sending video shows the upload disc and cannot be opened', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!video:example.invalid');
    final event = _ownFile(room, 'video-1', msgtype: MessageTypes.Video);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: room.sourceEvents),
    );
    addTearDown(timeline.cancelSubscriptions);
    await _mount(tester, client, _message(event, timeline));
    await tester.pump(const Duration(milliseconds: 100));
    // Not before the loader grace: a fast upload never flashes it.
    expect(find.byKey(const ValueKey('outgoing-upload-overlay')), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.byKey(const ValueKey('outgoing-upload-overlay')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.play_arrow_outlined), findsNothing);
    final frame = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('outgoing-upload-overlay')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(frame.onTap, isNull);
  });

  testWidgets('an own voice message that is sending is an upload', (
    tester,
  ) async {
    final room = ConversationRoom(
      ConversationClient(),
      '!voice:example.invalid',
    );
    expect(
      isOutgoingUpload(_ownFile(room, 'v1', msgtype: MessageTypes.Audio)),
      isTrue,
    );
    expect(
      isOutgoingUpload(
        _ownFile(
          room,
          'v2',
          msgtype: MessageTypes.Audio,
          status: EventStatus.sent,
        ),
      ),
      isFalse,
    );
    expect(
      isOutgoingUpload(_ownFile(room, 't1', msgtype: MessageTypes.Text)),
      isFalse,
    );
  });

  testWidgets('a failed file explains why and retries the same attempt', (
    tester,
  ) async {
    final echoes = OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final client = ConversationClient();
    final room = _FileRoom(client);
    // A send whose preparation failed: its reason is kept for the sheet.
    final ticket = await OutgoingMedia.send(
      room,
      MatrixFile(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'fictional.bin',
        mimeType: 'application/octet-stream',
      ),
      txid: 'failed-1',
      prepare: () async => throw StateError('fictional'),
    );
    await expectLater(ticket.accepted, throwsA(anything));
    final failed = Event.fromMatrixEvent(echoes.events['failed-1']!, room);
    room.sourceEvents.insert(0, failed);
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: room.sourceEvents),
    );
    addTearDown(timeline.cancelSubscriptions);
    await _mount(tester, client, _message(failed, timeline));
    await tester.pumpAndSettle();
    expect(find.text('Not sent · Tap to retry'), findsOneWidget);
    await tester.tap(find.text('Not sent · Tap to retry'));
    await tester.pumpAndSettle();
    expect(
      find.text('The file could not be prepared for sending.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(room.sent.single.txid, 'failed-1');
    expect(echoes.statusOf('failed-1'), EventStatus.sending.intValue);
  });

  group('round video', () {
    Widget round(ValueListenable<double?>? upload, {bool pending = false}) =>
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RoundVideoView(
                upload: upload,
                pending: pending,
                outgoing: true,
                duration: const Duration(seconds: 4),
                onToggle: () {},
              ),
            ),
          ),
        );

    testWidgets('an uploading round shows its ring and cannot be played', (
      tester,
    ) async {
      final progress = ValueNotifier<double?>(null);
      addTearDown(progress.dispose);
      await tester.pumpWidget(round(progress, pending: true));
      expect(find.byTooltip('Play round video'), findsNothing);
      expect(find.byKey(const ValueKey('round-upload-ring')), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('outgoing-upload-overlay')),
        findsOneWidget,
      );
      progress.value = .4;
      await tester.pump();
      expect(find.byKey(const ValueKey('round-upload-ring')), findsOneWidget);
      final semantics = tester.ensureSemantics();
      await tester.pump();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Round video')).value,
        contains('sending'),
      );
      semantics.dispose();
      // Sent: the ordinary play button is back.
      await tester.pumpWidget(round(null));
      expect(find.byTooltip('Play round video'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('outgoing-upload-overlay')),
        findsNothing,
      );
    });
  });
}

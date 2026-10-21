// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline media. These fixtures never open a picker or contact a server.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/send_file_dialog.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../personal/outgoing_media_support.dart';
import 'conversation_test_support.dart';

class _MediaClient extends ConversationClient {
  Completer<MediaConfig>? configGate;
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => configGate == null
      ? MediaConfig(mUploadSize: 1024 * 1024)
      : await configGate!.future;
}

typedef _Send = ({
  String name,
  String? id,
  Event? reply,
  String? root,
  String? last,
});

class _MediaRoom extends ConversationRoom {
  final sent = <_Send>[];
  Future<String?> Function(int attempt)? response;
  _MediaRoom(Client client) : super(client, '!fictional-media:example.invalid');

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
    sent.add((
      name: file.name,
      id: txid,
      reply: inReplyTo,
      root: threadRootEventId,
      last: threadLastEventId,
    ));
    return response == null
        ? r'$fictional-accepted'
        : await response!(sent.length);
  }
}

MatrixException _rejected({bool rateLimit = false}) => MatrixException(
  http.Response(
    rateLimit
        ? '{"errcode":"M_LIMIT_EXCEEDED","error":"fixture","retry_after_ms":0}'
        : '{"errcode":"M_FORBIDDEN","error":"fixture"}',
    rateLimit ? 429 : 403,
  ),
);

XFile _file([String name = 'fictional.txt']) => XFile.fromData(
  Uint8List.fromList([1, 2, 3]),
  name: name,
  path: name,
  mimeType: 'text/plain',
);

class _UnreadableImage extends XFile {
  _UnreadableImage()
    : super('/fictional/missing-image.png', mimeType: 'image/png');

  @override
  Future<Uint8List> readAsBytes() async =>
      throw StateError('Fictional unreadable image');

  @override
  Future<int> length() async => throw StateError('Fictional unreadable image');
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _MediaRoom room, {
    FrozenAttachmentContext? frozen,
    List<XFile>? files,
    ValueChanged<AttachmentSendResult?>? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showDialog<AttachmentSendResult>(
                  context: context,
                  builder: (_) => SendFileDialog(
                    room: room,
                    files: files ?? [_file()],
                    outerContext: context,
                    initialCaption: 'Fictional caption',
                    composeContext: frozen,
                    replyTo: frozen?.replyTo,
                    threadRootEventId: frozen?.threadRootEventId,
                    threadLastEventId: frozen?.threadLastEventId,
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Open attachments'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open attachments'));
    await tester.pumpAndSettle();
  }

  test(
    'frozen media rejects a different source, lost reply or send permission',
    () {
      final client = _MediaClient();
      final room = _MediaRoom(client);
      var current = true;
      final frozen = FrozenAttachmentContext(
        room: room,
        isCurrent: () => current,
      );
      expect(frozen.validate, returnsNormally);
      current = false;
      expect(frozen.validate, throwsStateError);
      current = true;
      room.sendingAllowed = false;
      expect(frozen.validate, throwsStateError);
      room.sendingAllowed = true;
      final other = ConversationRoom(client, '!other:example.invalid');
      final wrongReply = other.message(r'$other-reply', 'Fictional reply');
      expect(
        FrozenAttachmentContext(
          room: room,
          replyTo: wrongReply,
          isCurrent: () => true,
        ).validate,
        throwsStateError,
      );
    },
  );

  testWidgets(
    'the dialog closes once the bubble is in the chat, before the upload ends',
    (tester) async {
      final echoes = OutgoingEcho.debugWriter = FakeEchoes();
      addTearDown(() => OutgoingEcho.debugWriter = null);
      final client = _MediaClient()..configGate = Completer<MediaConfig>();
      final room = _MediaRoom(client);
      final accepted = Completer<String?>();
      room.response = (_) => accepted.future;
      AttachmentSendResult? result;
      await open(tester, room, onResult: (value) => result = value);
      final send = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Send'),
      );
      send.onPressed!();
      send.onPressed!();
      await tester.pump();
      // Only the (cached) media limit is awaited; no progress dialog.
      expect(find.byType(SendFileDialog), findsOneWidget);
      client.configGate!.complete(MediaConfig(mUploadSize: 1024 * 1024));
      await tester.pumpAndSettle();
      expect(find.byType(SendFileDialog), findsNothing);
      expect(result?.caption, 'Fictional caption');
      expect(echoes.events, hasLength(1), reason: 'one bubble, one send');
      expect(room.sent, hasLength(1));
      expect(room.sent.single.id, echoes.events.keys.single);
      // The upload is still running in the background.
      expect(accepted.isCompleted, isFalse);
      accepted.complete(r'$accepted');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a refusal after the bubble shows in the bubble, not in a dialog',
    (tester) async {
      final echoes = OutgoingEcho.debugWriter = FakeEchoes();
      addTearDown(() => OutgoingEcho.debugWriter = null);
      final room = _MediaRoom(_MediaClient());
      final reply = room.message(r'$reply', 'Fictional source reply');
      room.response = (_) async => throw _rejected();
      AttachmentSendResult? result;
      await open(
        tester,
        room,
        onResult: (value) => result = value,
        frozen: FrozenAttachmentContext(
          room: room,
          isCurrent: () => true,
          replyTo: reply,
          threadRootEventId: r'$thread',
          threadLastEventId: r'$thread-last',
        ),
      );
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.byType(SendFileDialog), findsNothing);
      expect(result?.caption, 'Fictional caption');
      final id = echoes.events.keys.single;
      expect(echoes.statusOf(id), EventStatus.error.intValue);
      // The shared Matrix error text (matrix-errors), never the errcode.
      expect(
        OutgoingMedia.failureOf(id),
        'You don’t have permission to do that.',
      );
      final sent = room.sent.single;
      expect(sent.reply, same(reply));
      expect(sent.root, r'$thread');
      expect(sent.last, r'$thread-last');
    },
  );

  testWidgets(
    'a rate limit is retried with the transaction, reply and thread',
    (tester) async {
      OutgoingEcho.debugWriter = FakeEchoes();
      addTearDown(() => OutgoingEcho.debugWriter = null);
      final room = _MediaRoom(_MediaClient());
      final reply = room.message(r'$reply', 'Fictional source reply');
      room.response = (attempt) async {
        if (attempt == 1) throw _rejected(rateLimit: true);
        return r'$accepted';
      };
      await open(
        tester,
        room,
        frozen: FrozenAttachmentContext(
          room: room,
          isCurrent: () => true,
          replyTo: reply,
          threadRootEventId: r'$thread',
          threadLastEventId: r'$last',
        ),
      );
      await tester.tap(find.text('Send'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(room.sent, hasLength(2));
      expect(room.sent[0], room.sent[1]);
    },
  );

  testWidgets(
    'source drift while config loads prevents any attachment transport',
    (tester) async {
      final echoes = OutgoingEcho.debugWriter = FakeEchoes();
      addTearDown(() => OutgoingEcho.debugWriter = null);
      final client = _MediaClient()..configGate = Completer<MediaConfig>();
      final room = _MediaRoom(client);
      var current = true;
      await open(
        tester,
        room,
        frozen: FrozenAttachmentContext(room: room, isCurrent: () => current),
      );
      await tester.tap(find.text('Send'));
      await tester.pump();
      current = false;
      client.configGate!.complete(MediaConfig(mUploadSize: 1024 * 1024));
      await tester.pumpAndSettle();
      expect(room.sent, isEmpty);
      expect(echoes.events, isEmpty);
      expect(find.textContaining('could not be prepared'), findsOneWidget);
      expect(find.text('Fictional caption'), findsOneWidget);
    },
  );

  testWidgets('files go out in order, each with its own transaction', (
    tester,
  ) async {
    final echoes = OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await open(tester, room, files: [_file('one.txt'), _file('two.txt')]);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.byType(SendFileDialog), findsNothing);
    expect(room.sent.map((send) => send.name), ['one.txt', 'two.txt']);
    expect(echoes.events.keys, [room.sent[0].id, room.sent[1].id]);
    expect(room.sent[0].id, isNot(room.sent[1].id));
  });

  testWidgets(
    'when a later bubble cannot be stored, Send again sends only the rest',
    (tester) async {
      final echoes = OutgoingEcho.debugWriter = FakeEchoes()
        ..failWriteNumber = 2;
      addTearDown(() => OutgoingEcho.debugWriter = null);
      final room = _MediaRoom(_MediaClient());
      await open(tester, room, files: [_file('one.txt'), _file('two.txt')]);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('1 of 2 attachments are already in the chat'),
        findsOneWidget,
      );
      expect(find.textContaining('could not be prepared'), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.byType(SendFileDialog), findsNothing);
      expect(room.sent.map((send) => send.name), ['one.txt', 'two.txt']);
      expect(echoes.events, hasLength(2));
    },
  );

  testWidgets(
    'unreadable image displays a failed preview instead of spinning',
    (tester) async {
      final room = _MediaRoom(_MediaClient());
      await open(tester, room, files: [_UnreadableImage()]);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

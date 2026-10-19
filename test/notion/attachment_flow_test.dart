// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline media. These fixtures never open a picker or contact a server.
import 'dart:async';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

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

  testWidgets('one pending attachment send retains preview until acceptance', (
    tester,
  ) async {
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
    expect(find.byType(SendFileDialog), findsOneWidget);
    expect(find.text('Fictional caption'), findsOneWidget);
    client.configGate!.complete(MediaConfig(mUploadSize: 1024 * 1024));
    await tester.pump();
    await tester.pump();
    expect(room.sent, hasLength(1));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    accepted.complete(r'$accepted');
    await tester.pumpAndSettle();
    expect(find.byType(SendFileDialog), findsNothing);
    expect(result?.caption, 'Fictional caption');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed rejection keeps files and caption and retries the same source context',
    (tester) async {
      final room = _MediaRoom(_MediaClient());
      final reply = room.message(r'$reply', 'Fictional source reply');
      room.response = (attempt) async {
        if (attempt == 1) throw _rejected();
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
          threadLastEventId: r'$thread-last',
        ),
      );
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.textContaining('server rejected'), findsOneWidget);
      expect(find.text('fictional.txt'), findsOneWidget);
      expect(find.text('Fictional caption'), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(room.sent, hasLength(2));
      expect(room.sent[0].id, room.sent[1].id);
      expect(
        room.sent.every(
          (send) =>
              identical(send.reply, reply) &&
              send.root == r'$thread' &&
              send.last == r'$thread-last',
        ),
        isTrue,
      );
    },
  );

  testWidgets('rate-limit retry keeps the transaction, reply and thread', (
    tester,
  ) async {
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
  });

  testWidgets(
    'unknown acceptance keeps selection and requires checking the source',
    (tester) async {
      final room = _MediaRoom(_MediaClient())
        ..response = (_) async =>
            throw StateError('fictional transport failure');
      await open(tester, room);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sending was not confirmed'), findsOneWidget);
      expect(find.text('fictional.txt'), findsOneWidget);
      expect(find.text('Fictional caption'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Send'))
            .onPressed,
        isNull,
      );
      expect(room.sent, hasLength(1));
      await tester.tap(find.text('Close without retrying'));
      await tester.pumpAndSettle();
      expect(find.byType(SendFileDialog), findsNothing);
    },
  );

  testWidgets(
    'source drift while config loads prevents any attachment transport',
    (tester) async {
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
      expect(find.textContaining('could not be prepared'), findsOneWidget);
      expect(find.text('Fictional caption'), findsOneWidget);
    },
  );

  testWidgets('accepted files are skipped when a later file is rejected', (
    tester,
  ) async {
    final room = _MediaRoom(_MediaClient());
    room.response = (attempt) async {
      if (attempt == 2) throw _rejected();
      return r'$accepted';
    };
    await open(tester, room, files: [_file('one.txt'), _file('two.txt')]);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 of 2 attachments accepted'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(room.sent.map((send) => send.name), [
      'one.txt',
      'two.txt',
      'two.txt',
    ]);
    expect(room.sent[1].id, room.sent[2].id);
  });

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

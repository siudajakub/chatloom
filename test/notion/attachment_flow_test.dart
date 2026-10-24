// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional offline media. These fixtures never open a picker or contact a server.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/send_file_dialog.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/media/caption_followup.dart';
import 'package:chatloom/personal/media/media_quality.dart';
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
  String msgtype,
  int? shrink,
  Map<String, dynamic>? extra,
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
      msgtype: file.msgType,
      shrink: shrinkImageMaxDimension,
      extra: extraContent,
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

const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';

/// A photo that counts how often it is read (MD-06).
class _CountingImage extends XFile {
  int reads = 0;
  final String _name;
  _CountingImage([this._name = 'photo.png'])
    : super.fromData(
        base64Decode(_pixelPng),
        name: _name,
        path: _name,
        mimeType: 'image/png',
      );

  @override
  String get name => _name;

  @override
  Future<Uint8List> readAsBytes() {
    reads++;
    return super.readAsBytes();
  }
}

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
    bool asFiles = false,
    String caption = 'Fictional caption',
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
                final result = await showSendFileDialog(
                  context,
                  SendFileDialog(
                    room: room,
                    files: files ?? [_file()],
                    outerContext: context,
                    initialCaption: caption,
                    sendAsFiles: asFiles,
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
      final send = tester.widget<InkWell>(
        find.descendant(
          of: find.byTooltip('Send'),
          matching: find.byType(InkWell),
        ),
      );
      send.onTap!();
      send.onTap!();
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
      await tester.tap(find.byTooltip('Send'));
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
      await tester.tap(find.byTooltip('Send'));
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
      await tester.tap(find.byTooltip('Send'));
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
    await tester.tap(find.byTooltip('Send'));
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
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('1 of 2 attachments are already in the chat'),
        findsOneWidget,
      );
      expect(find.textContaining('could not be prepared'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
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

  testWidgets('the preview is full screen with a caption, HD chip and send', (
    tester,
  ) async {
    final room = _MediaRoom(_MediaClient());
    await open(tester, room, files: [_CountingImage()]);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Fictional caption'), findsOneWidget);
    // No compression question (J, 2026-10-24): only the HD chip, off.
    expect(find.text('Compressed'), findsNothing);
    expect(find.textContaining('Original'), findsNothing);
    expect(find.byTooltip('Send in HD'), findsOneWidget);
    expect(find.byIcon(Icons.hd_outlined), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    final size = tester.getSize(find.byType(SendFileDialog));
    expect(size, tester.view.physicalSize / tester.view.devicePixelRatio);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(SendFileDialog), findsNothing);
    expect(room.sent, isEmpty);
  });

  testWidgets('toggling HD never reads the files again (MD-06)', (
    tester,
  ) async {
    final room = _MediaRoom(_MediaClient());
    final a = _CountingImage('a.png'), b = _CountingImage('b.png');
    await open(tester, room, files: [a, b]);
    final before = a.reads + b.reads;
    await tester.tap(find.byTooltip('Send in HD'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.hd_rounded));
    await tester.pumpAndSettle();
    expect(a.reads + b.reads, before);
  });

  testWidgets('photos are compressed at 2048 px without asking (MD-01)', (
    tester,
  ) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await open(tester, room, files: [_CountingImage()]);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    final sent = room.sent.single;
    expect(sent.msgtype, MessageTypes.Image);
    expect(sent.shrink, MediaQuality.photoMaxSide);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('HD sends photos at 2560 px, for this send only', (tester) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await open(tester, room, files: [_CountingImage()]);
    await tester.tap(find.byTooltip('Send in HD'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.hd_rounded), findsOneWidget);
    final toggle = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byIcon(Icons.hd_rounded),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.toggled != null,
            ),
          )
          .first,
    );
    expect(toggle.properties.toggled, isTrue);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(room.sent.single.msgtype, MessageTypes.Image);
    expect(room.sent.single.shrink, MediaQuality.photoHdMaxSide);
    expect(
      MediaProfile.ofPhotoMaxSide(room.sent.single.shrink!),
      MediaProfile.hd,
    );
    // The next preview starts without HD (never remembered).
    await tester.tap(find.text('Open attachments'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.hd_outlined), findsOneWidget);
    expect(find.byIcon(Icons.hd_rounded), findsNothing);
  });

  testWidgets('"File" sends the photo unchanged, as a file, no HD (MD-02)', (
    tester,
  ) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await open(tester, room, files: [_CountingImage()], asFiles: true);
    expect(find.byTooltip('Send in HD'), findsNothing);
    expect(find.textContaining('Sent as a file, unchanged'), findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    final sent = room.sent.single;
    expect(sent.msgtype, MessageTypes.File);
    expect(sent.shrink, isNull);
  });

  testWidgets('a video and a pasted image go out compressed, no question', (
    tester,
  ) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await open(
      tester,
      room,
      files: [
        XFile.fromData(
          Uint8List.fromList(List.filled(64, 0)),
          name: 'clip.mp4',
          mimeType: 'video/mp4',
        ),
        // What paste and drag and drop hand the preview.
        XFile.fromData(
          base64Decode(_pixelPng),
          name: 'pasted-image.png',
          path: 'pasted-image.png',
          mimeType: 'image/png',
        ),
      ],
    );
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.byTooltip('Send in HD'), findsOneWidget);
    expect(find.text('Compressed'), findsNothing);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(room.sent.map((s) => s.msgtype), [
      MessageTypes.Video,
      MessageTypes.Image,
    ]);
    expect(room.sent.last.shrink, MediaQuality.photoMaxSide);
  });

  testWidgets('a plain file shows no HD chip and no quality question', (
    tester,
  ) async {
    final room = _MediaRoom(_MediaClient());
    await open(tester, room, files: [_file()]);
    expect(find.text('File'), findsOneWidget);
    expect(find.byTooltip('Send in HD'), findsNothing);
    expect(find.text('Compressed'), findsNothing);
  });

  testWidgets('an album carries its caption on the newest item only', (
    tester,
  ) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await open(
      tester,
      room,
      files: [_CountingImage('a.png'), _CountingImage('b.png')],
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(room.sent.map((s) => s.extra?['body']), [null, 'Fictional caption']);
  });

  testWidgets('an item can be removed before sending', (tester) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    addTearDown(() => OutgoingEcho.debugWriter = null);
    final room = _MediaRoom(_MediaClient());
    await open(
      tester,
      room,
      files: [_CountingImage('a.png'), _CountingImage('b.png')],
    );
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Photo'), findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(room.sent.map((s) => s.name), ['b.png']);
  });

  testWidgets('a caption the network drops follows as its own message', (
    tester,
  ) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    final captions = <String>[];
    CaptionFollowUp.debugSender = (room, text, thread) async =>
        captions.add(text);
    addTearDown(() {
      OutgoingEcho.debugWriter = null;
      CaptionFollowUp.debugSender = null;
    });
    final room = _MediaRoom(_MediaClient())
      ..state(bridgeFeaturesEventType, {
        'file': {
          'm.image': {
            'mime_types': {'image/*': 2},
            'caption': -1,
          },
        },
      }, key: 'fixture');
    await open(tester, room, files: [_CountingImage()]);
    expect(find.text(CaptionFollowUp.notice), findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(room.sent.single.extra, isNull, reason: 'no caption on the photo');
    expect(captions, ['Fictional caption']);
  });

  testWidgets('a supported caption stays on the media', (tester) async {
    OutgoingEcho.debugWriter = FakeEchoes();
    final captions = <String>[];
    CaptionFollowUp.debugSender = (room, text, thread) async =>
        captions.add(text);
    addTearDown(() {
      OutgoingEcho.debugWriter = null;
      CaptionFollowUp.debugSender = null;
    });
    final room = _MediaRoom(_MediaClient())
      ..state(bridgeFeaturesEventType, {
        'file': {
          'm.image': {
            'mime_types': {'image/*': 2},
            'caption': 2,
            'max_caption_length': 1024,
          },
        },
      }, key: 'fixture');
    await open(tester, room, files: [_CountingImage()]);
    expect(find.text(CaptionFollowUp.notice), findsNothing);
    await tester.enterText(find.byType(TextField), 'x' * 1100);
    await tester.pump();
    expect(
      find.text(CaptionFollowUp.notice),
      findsOneWidget,
      reason: 'over the network limit',
    );
    await tester.enterText(find.byType(TextField), 'Short caption');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(room.sent.single.extra?['body'], 'Short caption');
    expect(captions, isEmpty);
  });
}

// Fictional captures of the production message/composer and merged presenters.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

bool _emojiFontLoaded = false;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.showThumbnailsInTimeline.setItem(false);
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Medium.ttf'))
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Bold.ttf'));
    await fonts.load();
    final emojiFont = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (emojiFont.existsSync()) {
      final bytes = await emojiFont.readAsBytes();
      await (FontLoader(
        'Apple Color Emoji',
      )..addFont(Future.value(bytes.buffer.asByteData()))).load();
      _emojiFontLoaded = true;
    }

    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  final output = Platform.environment['CONVERSATION_CAPTURE_DIR'];
  final manifest = <Map<String, Object?>>[];
  final cases =
      <
        ({
          double width,
          double scale,
          Brightness theme,
          bool rtl,
          bool merged,
          double keyboard,
          String state,
        })
      >[
        (
          width: 320,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'text',
        ),
        (
          width: 360,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'media',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'text',
        ),
        (
          width: 430,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'text',
        ),
        (
          width: 320,
          scale: 2,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 280,
          state: 'text',
        ),
        (
          width: 390,
          scale: 1.5,
          theme: Brightness.light,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'error',
        ),
        (
          width: 430,
          scale: 2,
          theme: Brightness.light,
          rtl: true,
          merged: false,
          keyboard: 0,
          state: 'media',
        ),
        (
          width: 900,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'media',
        ),
        (
          width: 1365,
          scale: 1.5,
          theme: Brightness.light,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'text',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'text',
        ),
        (
          width: 320,
          scale: 2,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 280,
          state: 'text',
        ),
        (
          width: 430,
          scale: 1.5,
          theme: Brightness.light,
          rtl: true,
          merged: true,
          keyboard: 0,
          state: 'text',
        ),
        (
          width: 900,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'picker',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'picker',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'reply',
        ),
        (
          width: 320,
          scale: 2,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 360,
          state: 'reply',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'details',
        ),
        (
          width: 900,
          scale: 1,
          theme: Brightness.light,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'details',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'group',
        ),
        (
          width: 320,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'actions',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.light,
          rtl: true,
          merged: true,
          keyboard: 0,
          state: 'actions',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'actions',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: false,
          keyboard: 0,
          state: 'hold',
        ),
        (
          width: 320,
          scale: 1,
          theme: Brightness.light,
          rtl: true,
          merged: false,
          keyboard: 0,
          state: 'hold',
        ),
        // The merged person chat renders through the same timeline and
        // composer as the ordinary chat.
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'text',
        ),
        (
          width: 390,
          scale: 1,
          theme: Brightness.dark,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'reply',
        ),
        (
          width: 390,
          scale: 1.3,
          theme: Brightness.light,
          rtl: false,
          merged: true,
          keyboard: 0,
          state: 'select',
        ),
      ];
  for (var index = 0; index < cases.length; index++) {
    final c = cases[index];
    testWidgets('production capture $index ${c.width}/${c.scale}/${c.state}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(c.width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = ConversationClient();
      final a = ConversationRoom(client, '!capture-a:example.invalid');
      final b = ConversationRoom(
        client,
        '!capture-b:example.invalid',
        network: 'messenger',
      );
      final one = a.message(r'$one', 'Hey, coffee tomorrow?');
      a.message(r'$two', 'Around five?', minute: 41);
      a.message(r'$three', 'Yes, after work.', outgoing: true, minute: 42);
      a.message(r'$four', 'At the same place?', outgoing: true, minute: 43);
      a.message(r'$five', 'Exactly. I’ll send you the location.', minute: 44);
      if (c.state == 'details') {
        a.message(
          r'$quote',
          'I’ll be there at five.',
          outgoing: true,
          minute: 47,
          content: {
            'msgtype': MessageTypes.Text,
            'body': 'I’ll be there at five.',
            'm.relates_to': {
              'm.in_reply_to': {'event_id': r'$five'},
            },
          },
        );
        a.sourceEvents.insert(
          0,
          Event(
            room: a,
            eventId: r'$thumb',
            type: EventTypes.Reaction,
            senderId: client.userID,
            originServerTs: DateTime.utc(2026, 10, 16, 16, 46),
            content: {
              'm.relates_to': {
                'rel_type': RelationshipTypes.reaction,
                'event_id': r'$five',
                'key': '👍',
              },
            },
          ),
        );
      }
      if (c.state == 'media') {
        a.message(
          r'$image',
          'Photo',
          minute: 45,
          content: {
            'msgtype': MessageTypes.Image,
            'body': 'Photo',
            'info': {
              'w': 640,
              'h': 360,
              'xyz.amorgan.blurhash': 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
            },
          },
        );
        a.message(
          r'$voice',
          'Voice message',
          minute: 46,
          content: {
            'msgtype': MessageTypes.Audio,
            'body': 'Voice message',
            'info': {'duration': 18000},
            'org.matrix.msc3245.voice': {},
          },
        );
      }
      if (c.state == 'error')
        a.message(
          r'$error',
          'This draft could not be sent.',
          outgoing: true,
          minute: 47,
          status: EventStatus.error,
        );
      if (c.state == 'group')
        a.state('m.bridge', {
          'protocol': {'id': 'whatsapp'},
          'bridgebot': '@bridge:example.invalid',
          'com.beeper.room_type.v2': 'group',
        }, key: 'fixture');
      if (c.merged) {
        b.message(r'$messenger', 'Saw your message on Messenger.', minute: 45);
      }
      final personal = ConversationPersonal(client);
      final group = PersonGroup(
        id: 'capture',
        name: 'Anna',
        members: [personal.ref(a), personal.ref(b)],
        defaultRoomId: a.id,
      );
      final scroll = ScrollController();
      final editor = TextEditingController();
      final hold = VoiceRecordHold();
      final timeline = Timeline(
        room: a,
        chunk: TimelineChunk(events: a.sourceEvents),
      );
      final boundary = GlobalKey();
      final chronological = a.sourceEvents.reversed
          .where(
            (e) => e.type == EventTypes.Message || e.type == EventTypes.Sticker,
          )
          .toList();
      final ordinary = Scaffold(
        appBar: AppBar(
          title: Text(c.state == 'group' ? 'Fictional group' : 'Anna'),
          toolbarHeight: 56,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                Expanded(
                  child: SelectionArea(
                    child: ListView(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(
                            child: Text(
                              'Today · 16:40',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        for (var i = 0; i < chronological.length; i++)
                          Message(
                            chronological[i],
                            nextEvent: i > 0 ? chronological[i - 1] : null,
                            previousEvent: i + 1 < chronological.length
                                ? chronological[i + 1]
                                : null,
                            bigEmojis: const {},
                            onSelect: (_) {},
                            onInfoTab: (_) {},
                            scrollToEventId: (_) {},
                            onSwipe: () {},
                            onEdit: () {},
                            singleSelected: false,
                            timeline: timeline,
                            onMention: () {},
                            scrollController: scroll,
                            colors: const [Colors.grey, Colors.grey],
                            enterThread: null,
                          ),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: ListenableBuilder(
                    listenable: hold,
                    builder: (context, _) => CompactComposer(
                      input: TextField(
                        controller: editor,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: 'Message…',
                          hintMaxLines: 1,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          filled: false,
                        ),
                      ),
                      source: const ConversationSourceChip(network: 'whatsapp'),
                      actions: [
                        ComposerAction(
                          icon: Icons.attach_file_outlined,
                          label: 'Attach media or a file',
                          onPressed: () {},
                        ),
                        ComposerAction(
                          icon: Icons.add_reaction_outlined,
                          label: 'Emoji picker',
                          onPressed: () {},
                        ),
                        ComposerAction(
                          icon: Icons.videocam_outlined,
                          label: 'Round video',
                          onPressed: () {},
                        ),
                      ],
                      collapseOnText: editor,
                      inputOverlay: hold.capturing
                          ? VoiceRecordHoldOverlay(
                              hold: hold,
                              duration: const Duration(seconds: 7),
                            )
                          : null,
                      primaryAction: VoiceRecordButton(
                        hold: hold,
                        onStart: () async => true,
                        onSend: () async {},
                        onCancel: () {},
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(client, preferences),
          child: RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: NotionTheme.build(c.theme).copyWith(
                textTheme: NotionTheme.build(c.theme).textTheme.apply(
                  fontFamilyFallback: const ['Apple Color Emoji'],
                ),
              ),
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(c.scale),
                  viewInsets: EdgeInsets.only(bottom: c.keyboard),
                ),
                child: Directionality(
                  textDirection: c.rtl ? TextDirection.rtl : TextDirection.ltr,
                  child: child!,
                ),
              ),
              home: c.merged
                  ? MergedChatPage(personal: personal, group: group)
                  : ordinary,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (c.state == 'reply') {
        tester
            .widgetList<ConversationMessageGestures>(
              find.byType(ConversationMessageGestures),
            )
            .firstWhere((w) => w.onReply != null)
            .onReply!();
        await tester.pumpAndSettle();
      }
      if (c.state == 'select') {
        await tester.longPress(find.text('Exactly. I’ll send you the location.'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('React 👍'), findsOneWidget);
      }
      if (c.state == 'actions') {
        await tester.tap(find.byTooltip('More message actions'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Hide message actions'), findsOneWidget);
        expect(find.byTooltip('Attach media or a file'), findsOneWidget);
      }
      TestGesture? held;
      if (c.state == 'hold') {
        held = await tester.startGesture(
          tester.getCenter(find.byType(VoiceRecordButton)),
        );
        await tester.pump();
        await tester.pump(VoiceRecordLayout.enter);
        // Halfway to the lock: the pill rises and its lock closes.
        await held.moveBy(const Offset(0, -40));
        await tester.pump();
        expect(hold.phase, VoiceRecordPhase.holding);
        expect(find.byKey(const Key('voice_lock_pill')), findsOneWidget);
        expect(find.text('0:07'), findsOneWidget);
      }
      if (c.state == 'picker') {
        await tester.tap(find.byType(ConversationSourceChip));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      if (output != null) {
        final filename =
            '${index.toString().padLeft(2, '0')}-${c.merged ? 'merged' : 'ordinary'}-${c.width.toInt()}-${(c.scale * 100).toInt()}-${c.theme.name}-${c.rtl ? 'rtl' : 'ltr'}-${c.state}.png';
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory(output).create(recursive: true);
          await File(
            '$output/$filename',
          ).writeAsBytes(data!.buffer.asUint8List());
        });
        manifest.add({
          'file': filename,
          'width': c.width,
          'height': 900,
          'textScale': c.scale,
          'theme': c.theme.name,
          'rtl': c.rtl,
          'merged': c.merged,
          'keyboard': c.keyboard,
          'state': c.state,
          'presenter': c.merged
              ? 'MergedChatPage'
              : 'Message + CompactComposer',
          'data': 'fictional offline',
          'mediaPixels': 'placeholder only',
          'emojiFont': _emojiFontLoaded
              ? 'system Apple Color Emoji'
              : 'platform fallback',
        });
      }
      expect(
        client.rooms.whereType<ConversationRoom>().fold<int>(
          0,
          (sum, r) => sum + r.reactionsSent,
        ),
        0,
      );
      if (held != null) {
        await held.cancel();
        await tester.pump();
        expect(hold.phase, VoiceRecordPhase.idle);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      hold.dispose();
      timeline.cancelSubscriptions();
      scroll.dispose();
      editor.dispose();
      personal.dispose();
      // Keep a referenced event live through disposal to check fixture identity.
      expect(one.room, same(a));
    });
  }
  tearDownAll(() async {
    if (output != null)
      await File(
        '$output/manifest.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
  });
}

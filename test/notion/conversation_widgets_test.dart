import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('incoming and outgoing entries share the authored column', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: const [
              NotionAuthoredMessageRow(
                avatar: Icon(Icons.person_outline),
                author: 'Anna',
                time: '16:40',
                body: Text('Are you free tomorrow?'),
              ),
              NotionAuthoredMessageRow(
                avatar: Icon(Icons.person_outline),
                author: 'You',
                time: '16:41',
                body: Text('Yes, after work.'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('Anna')).dx,
      tester.getTopLeft(find.text('You')).dx,
    );
    expect(
      tester.getTopLeft(find.text('Are you free tomorrow?')).dx,
      tester.getTopLeft(find.text('Yes, after work.')).dx,
    );
    expect(find.text('16:40'), findsOneWidget);
    expect(find.text('16:41'), findsOneWidget);
  });

  testWidgets(
    'long author and detailed timestamp reflow without losing message actions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  child: NotionAuthoredMessageRow(
                    avatar: const Icon(Icons.person_outline),
                    author: 'A very long conversation participant name',
                    time: 'October 13, 2026 · 16:40',
                    actions: NotionIconButton(
                      icon: Icons.more_horiz,
                      label: 'Message actions',
                      onPressed: () {},
                    ),
                    body: const Text(
                      'A long message remains readable and wraps in the same authored column.',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Message actions'), findsOneWidget);
      expect(find.text('October 13, 2026 · 16:40'), findsOneWidget);
    },
  );

  testWidgets(
    'audio controls have independent real playback seek and download actions',
    (tester) async {
      var plays = 0;
      var downloads = 0;
      double? sought;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: NotionAudioFileBlock(
                duration: '0:18',
                progress: .2,
                onPlay: () => plays++,
                onDownload: () => downloads++,
                onSeek: (value) => sought = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Play audio'));
      expect(plays, 1);
      expect(downloads, 0);
      await tester.tap(find.byTooltip('Download audio'));
      expect(downloads, 1);
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(.65);
      expect(sought, .65);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual transcription renders without creating a job and blocks duplicate requests',
    (tester) async {
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotionTranscribeAction(onPressed: () => requests++),
          ),
        ),
      );
      await tester.pump();
      expect(requests, 0);
      await tester.tap(find.text('Transcribe'));
      expect(requests, 1);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NotionTranscribeAction(
              busy: true,
              label: 'Waiting for confirmation',
            ),
          ),
        ),
      );
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      expect(find.text('Waiting for confirmation'), findsOneWidget);
    },
  );

  testWidgets('empty and pending send states stay disabled', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NotionSendButton())),
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    var sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotionSendButton(busy: true, onPressed: () => sends++),
        ),
      ),
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    expect(sends, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets(
      'composer controls remain reachable at width $width and 200 percent text',
      (tester) async {
        final editor = TextEditingController(
          text: 'A multiline draft\nremains in this conversation.',
        );
        addTearDown(editor.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 844),
                  textScaler: const TextScaler.linear(2),
                  viewInsets: const EdgeInsets.only(bottom: 280),
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: SizedBox(
                    width: width,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: NotionComposer(
                        input: TextField(
                          controller: editor,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: 'Write a message…',
                          ),
                        ),
                        actions: [
                          NotionIconButton(
                            icon: Icons.attach_file_outlined,
                            label: 'Attach file',
                            onPressed: () {},
                          ),
                          NotionIconButton(
                            icon: Icons.mic_none_outlined,
                            label: 'Record audio',
                            onPressed: () {},
                          ),
                          NotionIconButton(
                            icon: Icons.schedule_outlined,
                            label: 'Schedule',
                            onPressed: () {},
                          ),
                        ],
                        source: const Text(
                          'WhatsApp',
                          style: NotionTokens.caption,
                        ),
                        sendAction: NotionSendButton(onPressed: () {}),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        for (final label in [
          'Attach file',
          'Record audio',
          'Schedule',
          'Send message',
        ]) {
          final size = tester.getSize(find.byTooltip(label));
          expect(size.width, greaterThanOrEqualTo(44));
          expect(size.height, greaterThanOrEqualTo(44));
        }
        expect(editor.text, contains('multiline draft'));
      },
    );
  }

  testWidgets(
    'details round trip retains editor reply source and history position',
    (tester) async {
      final draft = TextEditingController(text: 'Keep this draft');
      final scroll = ScrollController();
      addTearDown(draft.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(
                title: NotionCompactChatHeader(
                  avatar: const Icon(Icons.person_outline),
                  name: 'Anna',
                  onDetails: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Chat details')),
                          body: const Text('Source properties'),
                        ),
                      ),
                    );
                  },
                ),
              ),
              body: Column(
                children: [
                  Expanded(
                    child: ListView(
                      controller: scroll,
                      children: List.generate(
                        40,
                        (index) =>
                            SizedBox(height: 50, child: Text('History $index')),
                      ),
                    ),
                  ),
                  const Text('Reply in WhatsApp'),
                  NotionComposer(
                    input: TextField(controller: draft),
                    actions: const [],
                    source: const Text('WhatsApp'),
                    sendAction: const NotionSendButton(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      scroll.jumpTo(430);
      await tester.pump();
      final position = scroll.offset;
      await tester.tap(find.text('Anna'));
      await tester.pumpAndSettle();
      expect(find.text('Chat details'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(draft.text, 'Keep this draft');
      expect(scroll.offset, position);
      expect(find.text('Reply in WhatsApp'), findsOneWidget);
      expect(find.text('WhatsApp'), findsOneWidget);
    },
  );

  test(
    'anchor correction preserves screen position for both timeline directions',
    () {
      expect(notionRestoredScrollOffset(200, 120, 170, reverse: true), 150);
      expect(notionRestoredScrollOffset(200, 120, 70, reverse: true), 250);
      expect(notionRestoredScrollOffset(200, 120, 170, reverse: false), 250);
      expect(notionRestoredScrollOffset(200, 120, 120, reverse: true), 200);
    },
  );
}

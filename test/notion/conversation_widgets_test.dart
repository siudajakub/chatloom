import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/personal/ui/notion_transcribe_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'chat header exposes one named button with its own details action',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var opens = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                title: NotionCompactChatHeader(
                  avatar: Semantics(
                    label: 'Fictional avatar child',
                    child: const Icon(Icons.person_outline),
                  ),
                  name: 'Fictional source',
                  onDetails: () => opens++,
                ),
              ),
            ),
          ),
        );
        final control = find.semantics.byLabel(
          'Chat details for Fictional source',
        );
        expect(control, findsOne);
        final node = control.evaluate().single;
        final data = node.getSemanticsData();
        expect(data.label, 'Chat details for Fictional source');
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isHeader, isFalse);
        expect(data.flagsCollection.isEnabled, ui.Tristate.isTrue);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        tester.semantics.tap(control);
        await tester.pump();
        expect(opens, 1);
        await tester.tap(find.text('Fictional source'));
        await tester.pump();
        expect(opens, 2);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('unavailable chat details keep the named button disabled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const NotionCompactChatHeader(
                avatar: Icon(Icons.person_outline),
                name: 'Fictional source',
                onDetails: null,
              ),
            ),
          ),
        ),
      );
      final control = find.semantics.byLabel(
        'Chat details for Fictional source',
      );
      expect(control, findsOne);
      final data = control.evaluate().single.getSemanticsData();
      expect(data.label, 'Chat details for Fictional source');
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.flagsCollection.isHeader, isFalse);
      expect(data.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(data.hasAction(ui.SemanticsAction.tap), isFalse);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('incoming starts and outgoing ends the conversation column', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: const [
              ConversationBubble(
                outgoing: false,
                avatar: Icon(Icons.person_outline),
                body: Text('Are you free tomorrow?'),
                footer: Text('16:40'),
              ),
              ConversationBubble(
                outgoing: true,
                body: Text('Yes, after work.'),
                footer: Text('16:41'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('Are you free tomorrow?')).dx,
      lessThan(tester.getTopLeft(find.text('Yes, after work.')).dx),
    );
    expect(find.text('16:40'), findsOneWidget);
    expect(find.text('16:41'), findsOneWidget);
  });

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
      expect(sought, isNull);
      slider.onChangeEnd!(.65);
      expect(sought, .65);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual transcription waits for a tap and supports unavailable actions',
    (tester) async {
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotionTranscribeSplitButton(
              onTranscribe: () => requests++,
              onLanguageSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(requests, 0);
      await tester.tap(find.text('Transcribe'));
      expect(requests, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotionTranscribeSplitButton(label: 'Unavailable'),
          ),
        ),
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('transcribe-primary')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Unavailable'), findsOneWidget);
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
    // The spinner waits for the loader grace (no flash on fast sends).
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

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

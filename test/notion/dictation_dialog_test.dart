// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/dictation_dialog.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _capture = Key('dictation-phone');

const _fictionalText =
    'Hej, będę za jakieś piętnaście minut. '
    'Możesz zamówić mi kawę? Poproszę cappuccino z mlekiem owsianym.\n\n'
    'Daj znać, czy udało się znaleźć stolik przy oknie. Do zobaczenia!';

void main() {
  late TextEditingController editor;
  var sends = 0;
  var closes = 0;
  var resumes = 0;

  setUpAll(loadDictationCaptureFonts);

  setUp(() {
    editor = TextEditingController(text: _fictionalText);
    sends = closes = resumes = 0;
  });
  tearDown(() => editor.dispose());

  Widget host({
    DictationPhase phase = DictationPhase.review,
    double scale = 1,
    double keyboard = 0,
    Size size = const Size(390, 844),
    bool paused = false,
    String? error,
  }) => RepaintBoundary(
    key: _capture,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('en'),
      supportedLocales: L10n.supportedLocales,
      localizationsDelegates: L10n.localizationsDelegates,
      theme: NotionTheme.build(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: size,
          textScaler: TextScaler.linear(scale),
          padding: const EdgeInsets.only(top: 32, bottom: 24),
          viewPadding: const EdgeInsets.only(top: 32, bottom: 24),
          viewInsets: EdgeInsets.only(bottom: keyboard),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: NotionGlassScope(
        mode: NotionGlassMode.on,
        child: Builder(
          builder: (context) => Stack(
            children: [
              dictationConversationFixture(),
              Positioned.fill(
                child: ColoredBox(color: context.notion.colors.scrim),
              ),
              SafeArea(
                child: DictationPanel(
                  phase: phase,
                  controller: editor,
                  duration: const Duration(seconds: 18),
                  paused: paused,
                  error: error,
                  onPrimary: () => sends++,
                  onClose: () => closes++,
                  onResume: () => resumes++,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'editable transcript needs an explicit send; whitespace is disabled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(sends, 0);
      expect(find.text('Review your message'), findsOneWidget);
      expect(
        find.text('Only the text will be sent to the conversation.'),
        findsOneWidget,
      );
      final field = find.descendant(
        of: find.byKey(const Key('dictation-editor')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(field).expands, isTrue);
      await tester.enterText(field, '   \n  ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('dictation-primary')));
      expect(sends, 0);
      await tester.enterText(field, 'Poprawiona wiadomość.');
      await tester.pump();
      expect(editor.text, 'Poprawiona wiadomość.');
      await tester.tap(find.byKey(const Key('dictation-primary')));
      expect(sends, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed send retains editable text and exposes the error', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(error: 'Tekst jest zachowany — spróbuj ponownie.'),
    );
    await tester.pumpAndSettle();
    expect(editor.text, _fictionalText);
    expect(
      find.text('Tekst jest zachowany — spróbuj ponownie.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dictation-editor')), findsOneWidget);
    expect(sends, 0);
    await tester.tap(find.byKey(const Key('dictation-primary')));
    expect(sends, 1);
  });

  testWidgets('transcribing disables primary and provides no send action', (
    tester,
  ) async {
    await tester.pumpWidget(host(phase: DictationPhase.transcribing));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dictation-editor')), findsNothing);
    expect(find.text('Send message'), findsNothing);
    expect(
      find.text('ElevenLabs Scribe v2 is preparing the text…'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('dictation-primary')));
    expect(sends, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('paused recorder exposes resume and retains time', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(phase: DictationPhase.recording, paused: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('0:18'), findsOneWidget);
    expect(find.text('Recording paused'), findsOneWidget);
    await tester.tap(find.text('Resume recording'));
    expect(resumes, 1);
    expect(sends, 0);
  });

  testWidgets(
    '320px with large text, long transcript and keyboard keeps send reachable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      editor.text = List.filled(30, _fictionalText).join('\n');
      await tester.pumpWidget(
        host(scale: 2, keyboard: 280, size: const Size(320, 640)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final send = find.byKey(const Key('dictation-primary'));
      await tester.ensureVisible(send);
      await tester.pump();
      await tester.tap(send);
      expect(sends, 1);
      expect(editor.text.length, greaterThan(4000));
      expect(tester.takeException(), isNull);
    },
  );

  for (final state in ['review', 'recording', 'keyboard']) {
    testWidgets('phone preview $state uses production widgets', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        host(
          phase: state == 'recording'
              ? DictationPhase.recording
              : DictationPhase.review,
          keyboard: state == 'keyboard' ? 320 : 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final output = Platform.environment['NOTION_CAPTURE_DIR'];
      if (output == null) return;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_capture),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$output/panel-$state.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}

Future<void> loadDictationCaptureFonts() async {
  final fonts = FontLoader('Roboto');
  for (final weight in ['Regular', 'Medium', 'Bold']) {
    fonts.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
  }
  await fonts.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

Widget dictationConversationFixture() => Scaffold(
  appBar: AppBar(
    leading: const BackButton(),
    title: const Row(
      children: [
        NotionInitialAvatar(name: 'Anna', size: NotionSize.avatar),
        SizedBox(width: NotionSpace.sm),
        Text('Anna'),
      ],
    ),
    actions: const [
      NotionIconButton(icon: Icons.call_outlined, label: 'Zadzwoń'),
      NotionIconButton(icon: Icons.more_horiz, label: 'Więcej'),
    ],
  ),
  body: Column(
    children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(NotionSpace.md),
          children: const [
            ConversationBubble(
              outgoing: false,
              body: Text('Hej! O której będziesz?'),
            ),
            SizedBox(height: NotionSpace.sm),
            ConversationBubble(
              outgoing: true,
              body: Text('Właśnie wychodzę, zaraz dam znać.'),
            ),
            SizedBox(height: NotionSpace.sm),
            ConversationBubble(
              outgoing: false,
              body: Text('Super, czekam w kawiarni przy parku.'),
            ),
          ],
        ),
      ),
      CompactComposer(
        useCompactActionToolbar: true,
        inlineActions: [
          ComposerAction(
            icon: Icons.sentiment_satisfied_alt_outlined,
            label: 'Emoji',
            onPressed: () {},
          ),
        ],
        source: const ConversationSourceChip(network: 'whatsapp'),
        input: const TextField(
          decoration: InputDecoration(
            hintText: 'Wiadomość',
            border: InputBorder.none,
          ),
        ),
        addAction: NotionIconButton(
          icon: Icons.add,
          label: 'Dodaj',
          onPressed: () {},
        ),
        primaryAction: NotionIconButton(
          icon: Icons.mic_none_outlined,
          label: 'Wiadomość głosowa',
          onPressed: () {},
        ),
        secondaryAction: NotionIconButton(
          icon: Icons.videocam_outlined,
          label: 'Wiadomość wideo',
          onPressed: () {},
        ),
        tertiaryAction: NotionIconButton(
          icon: Icons.edit_note_outlined,
          label: 'Dyktuj wiadomość',
          onPressed: () {},
        ),
      ),
    ],
  ),
);

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart'
    show NotionSendButton;
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late TextEditingController editor;
  late VoiceRecordHold hold;
  setUp(() {
    editor = TextEditingController();
    hold = VoiceRecordHold();
  });
  tearDown(() {
    editor.dispose();
    hold.dispose();
  });

  Widget host({
    double scale = 1,
    TextDirection direction = TextDirection.ltr,
  }) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: Directionality(
            textDirection: direction,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: editor,
                builder: (context, value, _) => CompactComposer(
                  input: TextField(controller: editor),
                  source: ConversationSourceChip(
                    network: 'telegram',
                    onPressed: () {},
                  ),
                  addAction: IconButton(
                    tooltip: 'Attach',
                    onPressed: () {},
                    icon: const Icon(Icons.add),
                  ),
                  fieldAction: ComposerAction(
                    icon: Icons.sentiment_satisfied_alt_outlined,
                    label: 'Emoji',
                    onPressed: () {},
                  ),
                  useCompactActionToolbar: true,
                  primaryIsRecord: value.text.isEmpty,
                  secondaryAction: value.text.isEmpty
                      ? NotionIconButton(
                          icon: Icons.videocam_outlined,
                          label: 'Round video',
                          onPressed: () {},
                        )
                      : null,
                  tertiaryAction: value.text.isEmpty
                      ? NotionIconButton(
                          icon: Icons.edit_note_outlined,
                          label: 'Dictate a message',
                          onPressed: () {},
                        )
                      : null,
                  primaryAction: value.text.isEmpty
                      ? VoiceRecordButton(
                          key: const ValueKey('mic'),
                          hold: hold,
                          onStart: () async => true,
                          onSend: () async {},
                          onCancel: () {},
                        )
                      : NotionSendButton(onPressed: () {}),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  final toggle = find.byTooltip('Show recording options');

  for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
    testWidgets(
      '320dp at 200% text reveals three 48dp recording actions above the row ($direction)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(host(scale: 2, direction: direction));
        await tester.pumpAndSettle();
        final dictate = find.byTooltip('Dictate a message');
        final round = find.byTooltip('Round video');
        final mic = find.byType(VoiceRecordButton);
        final add = find.byTooltip('Attach');
        // "+" and the recording picker share a line.
        expect(tester.getCenter(add).dy, tester.getCenter(toggle).dy);
        final folded = tester.getSize(find.byType(TextField)).width;
        expect(folded, greaterThan(80));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Hide recording options'), findsOneWidget);
        // The controls open above the editor without resizing it.
        expect(tester.getSize(find.byType(TextField)).width, folded);
        for (final button in [dictate, round, mic]) {
          expect(tester.getSize(button), const Size.square(48));
          expect(
            tester.getCenter(button).dy,
            lessThan(tester.getTopLeft(find.byType(TextField)).dy),
          );
        }
        final ltr = direction == TextDirection.ltr;
        final picker = tester.getCenter(
          find.byTooltip('Hide recording options'),
        );
        expect(tester.getCenter(mic).dx < picker.dx, ltr);
        expect(tester.getCenter(dictate).dx < tester.getCenter(mic).dx, ltr);
        await tester.tap(find.byTooltip('Hide recording options'));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(TextField)).width, folded);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'typing puts send in the recording picker\'s place, same editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextField));
      final state = tester.state(find.byType(EditableText));
      final toggleCenter = tester.getCenter(
        find.byTooltip('Hide recording options'),
      );
      await tester.enterText(find.byType(TextField), 'Fictional draft');
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(EditableText)), same(state));
      expect(tester.getCenter(find.byType(NotionSendButton)), toggleCenter);
      expect(find.byTooltip('Dictate a message'), findsNothing);
      expect(find.byTooltip('Hide recording options'), findsNothing);
      expect(tester.testTextInput.isVisible, isTrue);
      // Clearing the text brings the picker back, folded.
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resize preserves the editor and active microphone state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(toggle, findsNothing);
    final editorState = tester.state(find.byType(EditableText));
    final micState = tester.state(find.byType(VoiceRecordButton));
    await tester.binding.setSurfaceSize(const Size(320, 700));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(EditableText)), same(editorState));
    expect(tester.state(find.byType(VoiceRecordButton)), same(micState));
    expect(toggle, findsOneWidget);
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(80));
    expect(tester.takeException(), isNull);
  });
}

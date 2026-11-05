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
                  inlineActions: [
                    ComposerAction(
                      icon: Icons.add_reaction_outlined,
                      label: 'Emoji',
                      onPressed: () {},
                    ),
                  ],
                  useCompactActionToolbar: true,
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

  for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
    testWidgets(
      '320dp at 200% text keeps the editor and three 48dp actions ($direction)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(host(scale: 2, direction: direction));
        await tester.pumpAndSettle();
        final dictate = find.byTooltip('Dictate a message');
        final round = find.byTooltip('Round video');
        final mic = find.byType(VoiceRecordButton);
        expect(tester.getSize(find.byType(TextField)).width, greaterThan(120));
        for (final button in [dictate, round, mic]) {
          expect(tester.getSize(button), const Size.square(48));
        }
        expect(tester.getCenter(dictate).dy, tester.getCenter(round).dy);
        expect(tester.getCenter(round).dy, tester.getCenter(mic).dy);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('typing keeps the phone toolbar and the same active editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byType(TextField));
    final state = tester.state(find.byType(EditableText));
    final editorRect = tester.getRect(find.byType(TextField));
    final micRect = tester.getRect(find.byType(VoiceRecordButton));
    await tester.enterText(find.byType(TextField), 'Fictional draft');
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(EditableText)), same(state));
    expect(tester.getRect(find.byType(TextField)), editorRect);
    expect(tester.getRect(find.byType(NotionSendButton)), micRect);
    expect(find.byTooltip('Dictate a message'), findsNothing);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resize preserves the editor and active microphone state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final editorState = tester.state(find.byType(EditableText));
    final micState = tester.state(find.byType(VoiceRecordButton));
    await tester.binding.setSurfaceSize(const Size(320, 700));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(EditableText)), same(editorState));
    expect(tester.state(find.byType(VoiceRecordButton)), same(micState));
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(120));
    expect(tester.takeException(), isNull);
  });
}

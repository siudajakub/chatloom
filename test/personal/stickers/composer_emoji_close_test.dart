// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 13 (J): an emoji tap in the composer's panel types the emoji and
// closes the panel; the field takes focus again. Offline fixtures only.
import 'package:chatloom/pages/chat/chat_emoji_picker.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/stickers/notion_emoji_picker.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_panel.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

/// The shared part of both real hosts ([ChatController] and the merged
/// chat): the toggle closes by focusing the field, and the field's focus
/// closes an open panel.
class _Host extends ChangeNotifier implements ConversationComposerHost {
  _Host(this.room) {
    inputFocus.addListener(() {
      if (showEmojiPicker && inputFocus.hasFocus) hideEmojiPicker();
    });
  }

  @override
  final Room room;
  @override
  final FocusNode inputFocus = FocusNode(debugLabel: 'composer');
  @override
  final TextEditingController sendController = TextEditingController();
  @override
  bool showEmojiPicker = true;
  int toggles = 0;

  @override
  Event? get replyEvent => null;
  @override
  String? get activeThreadId => null;
  @override
  String? get threadLastEventId => null;

  @override
  void emojiPickerAction() {
    toggles++;
    if (showEmojiPicker) {
      inputFocus.requestFocus();
    } else {
      inputFocus.unfocus();
    }
    showEmojiPicker = !showEmojiPicker;
    notifyListeners();
  }

  @override
  void hideEmojiPicker() {
    showEmojiPicker = false;
    notifyListeners();
  }

  @override
  void onEmojiSelected(Category? category, Emoji? emoji) {
    if (emoji == null) return;
    final value = sendController.value;
    final at = value.selection.isValid
        ? value.selection.start
        : value.text.length;
    sendController.value = TextEditingValue(
      text: value.text.replaceRange(at, at, emoji.emoji),
      selection: TextSelection.collapsed(offset: at + emoji.emoji.length),
    );
  }

  @override
  void emojiPickerBackspace() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late StickerLibrary library;
  late _Host host;

  setUp(() {
    final client = ConversationClient();
    final room = ConversationRoom(
      client,
      '!chat:example.invalid',
      network: 'telegram',
    );
    host = _Host(room);
    library = fakeLibrary(FakeStickerBackend());
    StickerLibrary.debugSet(client, library);
    StickerPanel.debugResetTab(StickerPanelTab.emoji);
  });
  tearDown(() {
    library.dispose();
    host.inputFocus.dispose();
    host.sendController.dispose();
    host.dispose();
  });

  Future<void> pumpComposer(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 760);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: host,
            builder: (context, _) => Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextField(
                  focusNode: host.inputFocus,
                  controller: host.sendController,
                ),
                ChatEmojiPicker(host),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ComposerEmojiTab), findsOneWidget);
  }

  testWidgets('an emoji tap types it, closes the panel, focuses the field', (
    tester,
  ) async {
    await pumpComposer(tester);
    host.sendController.value = const TextEditingValue(
      text: 'hi ',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.tap(find.bySemanticsLabel('😂').first);
    await tester.pump();
    expect(host.sendController.text, 'hi 😂');
    expect(host.showEmojiPicker, isFalse);
    expect(host.toggles, 1);
    expect(host.inputFocus.hasFocus, isTrue);
    // The slot's own close: still there on the first frame, then gone.
    await tester.pumpAndSettle();
    expect(find.byType(ComposerEmojiTab), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a search result tap closes the panel too', (tester) async {
    await pumpComposer(tester);
    await tester.tap(find.widgetWithText(TextField, 'Search emoji'));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search emoji'),
      'joy',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('😂').first);
    await tester.pump();
    expect(host.sendController.text, '😂');
    expect(host.showEmojiPicker, isFalse);
    expect(host.inputFocus.hasFocus, isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ComposerEmojiTab), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a picker the host already closed is not toggled open', (
    tester,
  ) async {
    await pumpComposer(tester);
    host.showEmojiPicker = false;
    await tester.tap(find.bySemanticsLabel('😂').first);
    await tester.pump();
    expect(host.toggles, 0);
    expect(host.showEmojiPicker, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('the reaction sheet still closes by its own pop', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 760);
    addTearDown(tester.view.reset);
    final picked = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked.add(
                await showEmojiPickerSheet(context, title: 'React'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatLoomEmojiPicker), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('😂').first);
    await tester.pumpAndSettle();
    expect(picked, ['😂']);
    expect(find.byType(ChatLoomEmojiPicker), findsNothing);
    expect(find.byType(ComposerEmojiTab), findsNothing);
  });
}

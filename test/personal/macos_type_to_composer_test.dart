// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/composer_keyboard.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A conversation: messages in a [SelectionArea], a search field and the
/// composer. Its state owns the Mac chat commands, as `ChatController` does.
class _Chat extends StatefulWidget {
  const _Chat({required this.log});
  final List<String> log;
  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final composer = TextEditingController();
  final composerFocus = FocusNode(debugLabel: 'composer');
  final search = TextEditingController();
  bool enabled = true;

  @override
  void initState() {
    super.initState();
    MacDesktopCommands.bindChat(
      this,
      MacChatCommands(
        searchInChat: () {},
        scrollToTop: () {},
        scrollToBottom: () {},
        typeIntoComposer: (text) {
          if (!enabled) return false;
          insertComposerText(composer, text);
          composerFocus.requestFocus();
          return true;
        },
        escape: () {
          widget.log.add('escape');
          return true;
        },
      ),
    );
  }

  @override
  void dispose() {
    MacDesktopCommands.unbindChat(this);
    composer.dispose();
    composerFocus.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      DismissIntent: ComposerBackAction(
        composer: composerFocus,
        enabled: true,
        onBack: () => widget.log.add('composer back'),
      ),
    },
    child: Column(
      children: [
        TextField(key: const Key('search'), controller: search),
        const Expanded(child: SelectionArea(child: Text('A message'))),
        TextField(
          key: const Key('composer'),
          controller: composer,
          focusNode: composerFocus,
        ),
      ],
    ),
  );
}

/// The inbox column beside the chat.
class _Inbox extends StatefulWidget {
  const _Inbox();
  @override
  State<_Inbox> createState() => _InboxState();
}

class _InboxState extends State<_Inbox> {
  final focus = FocusNode(debugLabel: 'inbox row');

  @override
  void initState() {
    super.initState();
    MacDesktopCommands.bindInbox(this, MacInboxCommands(search: () {}));
  }

  @override
  void dispose() {
    MacDesktopCommands.unbindInbox(this);
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: focus, child: const SizedBox(width: 200));
}

void main() {
  late List<String> log;

  setUp(() {
    log = [];
    MacDesktopCommands.debugReset();
    FocusManager.instance.addEarlyKeyEventHandler(
      MacDesktopCommands.handleEarlyKey,
    );
    FocusManager.instance.addLateKeyEventHandler(
      MacDesktopCommands.handleUnhandledKey,
    );
  });
  tearDown(() {
    FocusManager.instance.removeEarlyKeyEventHandler(
      MacDesktopCommands.handleEarlyKey,
    );
    FocusManager.instance.removeLateKeyEventHandler(
      MacDesktopCommands.handleUnhandledKey,
    );
    MacDesktopCommands.debugReset();
    PersonalPrivacy.surfaceUnlocked = true;
  });

  Future<_ChatState> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const _Inbox(),
              Expanded(child: _Chat(log: log)),
            ],
          ),
        ),
      ),
    );
    return tester.state<_ChatState>(find.byType(_Chat));
  }

  Future<void> clickMessage(WidgetTester tester) async {
    await tester.tap(find.text('A message'), kind: PointerDeviceKind.mouse);
    await tester.pump();
  }

  testWidgets('typing after a click on a message writes in the composer', (
    tester,
  ) async {
    final chat = await mount(tester);
    chat.composer.text = 'Hi';
    await clickMessage(tester);
    expect(chat.composerFocus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(chat.composer.text, 'Hia');
    expect(chat.composerFocus.hasFocus, isTrue);
  });

  testWidgets('typing with focus in the inbox writes in the open chat', (
    tester,
  ) async {
    final chat = await mount(tester);
    tester.state<_InboxState>(find.byType(_Inbox)).focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    expect(chat.composer.text, 'b');
  });

  testWidgets('shortcuts, other fields, the lock and dialogs keep keys', (
    tester,
  ) async {
    final chat = await mount(tester);
    await clickMessage(tester);
    // ⌘C (copy a selection) and ⌃ keys are never typed.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Arrows, Tab and Backspace are not text.
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(chat.composer.text, isEmpty);

    // The lock covers the chat: nothing is typed.
    PersonalPrivacy.surfaceUnlocked = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    expect(chat.composer.text, isEmpty);
    PersonalPrivacy.surfaceUnlocked = true;

    // Another text field keeps its own typing.
    await tester.tap(find.byKey(const Key('search')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('search')), 'query');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(chat.composer.text, isEmpty);

    // A dialog over the chat keeps its keys.
    showDialog<void>(
      context: tester.element(find.byType(_Chat)),
      builder: (_) =>
          const Dialog(child: Focus(autofocus: true, child: Text('Dialog'))),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    expect(chat.composer.text, isEmpty);
  });

  testWidgets('a composer that cannot take text leaves the key alone', (
    tester,
  ) async {
    final chat = await mount(tester);
    chat.enabled = false;
    await clickMessage(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(chat.composer.text, isEmpty);
  });

  testWidgets('Esc goes back from the messages and the composer only', (
    tester,
  ) async {
    final chat = await mount(tester);
    await clickMessage(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(log, ['escape']);

    // In the composer Esc arrives as the field's DismissIntent.
    chat.composerFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(log, ['escape', 'composer back']);

    // An input method composing in the composer cancels its candidate.
    chat.composer.value = const TextEditingValue(
      text: 'ni',
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(log, hasLength(2));

    // Esc in another field (search) stays there; in the inbox it does
    // not close the chat.
    await tester.tap(find.byKey(const Key('search')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    tester.state<_InboxState>(find.byType(_Inbox)).focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(log, hasLength(2));
  });

  group('typed text', () {
    KeyDownEvent down(String? character, LogicalKeyboardKey key) =>
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: key,
          character: character,
          timeStamp: Duration.zero,
        );

    test('letters, Option characters and spaces type; controls do not', () {
      String? typed(String? c, {bool meta = false, bool control = false}) =>
          macTypedText(
            down(c, LogicalKeyboardKey.keyA),
            metaPressed: meta,
            controlPressed: control,
          );
      expect(typed('a'), 'a');
      expect(typed('ą'), 'ą');
      expect(typed(' '), ' ');
      expect(typed('a', meta: true), isNull);
      expect(typed('a', control: true), isNull);
      expect(typed('\r'), isNull);
      expect(typed('\t'), isNull);
      expect(typed('\u001b'), isNull);
      expect(typed('\u007f'), isNull);
      // AppKit's arrow and function keys (NSUpArrowFunctionKey…).
      expect(typed(''), isNull);
      expect(typed(null), isNull);
    });
  });

  group('composer keys', () {
    const enter = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: Duration.zero,
    );
    const up = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowUp,
      logicalKey: LogicalKeyboardKey.arrowUp,
      timeStamp: Duration.zero,
    );

    test('⌘↩ sends also when Enter adds a new line', () {
      var sends = 0;
      KeyEventResult handle({required bool meta, bool ime = false}) =>
          conversationComposerKeyResult(
            enter,
            value: TextEditingValue(
              text: 'draft',
              composing: ime
                  ? const TextRange(start: 0, end: 5)
                  : TextRange.empty,
            ),
            sendOnEnter: false,
            shiftPressed: false,
            metaPressed: meta,
            onSend: () => sends++,
          );
      expect(handle(meta: false), KeyEventResult.ignored);
      expect(handle(meta: true, ime: true), KeyEventResult.ignored);
      expect(sends, 0);
      expect(handle(meta: true), KeyEventResult.handled);
      expect(sends, 1);
    });

    test('a bare ↑ in the empty composer edits the last message', () {
      var edits = 0;
      KeyEventResult handle(
        String text, {
        bool meta = false,
        bool shift = false,
        bool editable = true,
      }) => conversationComposerKeyResult(
        up,
        value: TextEditingValue(text: text),
        sendOnEnter: true,
        shiftPressed: shift,
        metaPressed: meta,
        onSend: () {},
        onEditLast: editable ? () => edits++ : null,
      );
      expect(handle('draft'), KeyEventResult.ignored);
      expect(handle('', meta: true), KeyEventResult.ignored);
      expect(handle('', shift: true), KeyEventResult.ignored);
      expect(handle('', editable: false), KeyEventResult.ignored);
      expect(edits, 0);
      expect(handle(''), KeyEventResult.handled);
      expect(edits, 1);
    });

    test('text goes in at the caret, replacing a selection', () {
      final controller = TextEditingController(text: 'Hello world');
      controller.selection = const TextSelection(
        baseOffset: 6,
        extentOffset: 11,
      );
      expect(insertComposerText(controller, 'there'), 'Hello there');
      expect(controller.selection, const TextSelection.collapsed(offset: 11));
      controller.value = const TextEditingValue(text: 'ab');
      expect(insertComposerText(controller, 'c'), 'abc');
      controller.dispose();
    });
  });

  group('title bar', () {
    tearDown(() => MacDesktopWindow.titlebarInset.value = 0);

    testWidgets('the inset raises the top padding; full screen resets it', (
      tester,
    ) async {
      late EdgeInsets padding, viewPadding;
      await tester.pumpWidget(
        MacTitlebarInset(
          inset: MacDesktopWindow.titlebarInset,
          child: Builder(
            builder: (context) {
              padding = MediaQuery.paddingOf(context);
              viewPadding = MediaQuery.viewPaddingOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(padding.top, 0);
      MacDesktopWindow.applyInset(28.0);
      await tester.pump();
      expect(padding.top, 28);
      expect(viewPadding.top, 28);
      // Nonsense from the native side is ignored.
      MacDesktopWindow.applyInset(-4);
      MacDesktopWindow.applyInset('28');
      MacDesktopWindow.applyInset(double.nan);
      await tester.pump();
      expect(padding.top, 28);
      // Full screen.
      MacDesktopWindow.applyInset(0);
      await tester.pump();
      expect(padding.top, 0);
    });
  });
}

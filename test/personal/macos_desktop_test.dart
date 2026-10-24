// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(() => PersonalPrivacy.surfaceUnlocked = true);

  test('a disposed inbox cannot remove its replacement search binding', () {
    final oldInbox = Object();
    final currentInbox = Object();
    var oldCalls = 0;
    var currentCalls = 0;
    MacDesktopCommands.bindSearch(oldInbox, () => oldCalls++);
    MacDesktopCommands.bindSearch(currentInbox, () => currentCalls++);
    MacDesktopCommands.unbindSearch(oldInbox);
    MacDesktopCommands.search();
    expect(oldCalls, 0);
    expect(currentCalls, 1);
    MacDesktopCommands.unbindSearch(currentInbox);
    MacDesktopCommands.search();
    expect(currentCalls, 1);
  });

  test('native and keyboard search cannot navigate through the app lock', () {
    final owner = Object();
    var calls = 0;
    MacDesktopCommands.bindSearch(owner, () => calls++);
    PersonalPrivacy.surfaceUnlocked = false;
    MacDesktopCommands.search();
    expect(calls, 0);
    PersonalPrivacy.surfaceUnlocked = true;
    MacDesktopCommands.search();
    expect(calls, 1);
    MacDesktopCommands.unbindSearch(owner);
  });

  group('shortcuts', shortcutTests);
}

void shortcutTests() {
  late List<String> calls;
  late FocusNode focus;
  late TextEditingController text;

  setUp(() {
    calls = [];
    focus = FocusNode();
    text = TextEditingController();
    MacDesktopCommands.debugReset();
    MacDesktopCommands.bindInbox(
      'inbox',
      MacInboxCommands(
        search: () => calls.add('search'),
        openAt: (index) => calls.add('open $index'),
        step: (delta) => calls.add('step $delta'),
        nextUnread: () => calls.add('unread'),
        toggleArchived: () => calls.add('archive'),
        toggleUnread: () => calls.add('mark unread'),
      ),
    );
  });
  tearDown(() {
    MacDesktopCommands.debugReset();
    focus.dispose();
    text.dispose();
  });

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: MacDesktopIntegration.bindings(
        onSettings: () => calls.add('settings'),
        onShortcutsHelp: () => calls.add('help'),
        child: Scaffold(
          body: TextField(controller: text, focusNode: focus, maxLines: 4),
        ),
      ),
    ),
  );

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool meta = false,
    bool control = false,
    bool alt = false,
    bool shift = false,
  }) async {
    final modifiers = [
      if (meta) LogicalKeyboardKey.metaLeft,
      if (control) LogicalKeyboardKey.controlLeft,
      if (alt) LogicalKeyboardKey.altLeft,
      if (shift) LogicalKeyboardKey.shiftLeft,
    ];
    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.pump();
  }

  testWidgets('chat switching, search and help keys reach their commands', (
    tester,
  ) async {
    await mount(tester);
    focus.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.digit1, meta: true);
    await press(tester, LogicalKeyboardKey.digit9, meta: true);
    await press(tester, LogicalKeyboardKey.tab, control: true);
    await press(tester, LogicalKeyboardKey.tab, control: true, shift: true);
    await press(tester, LogicalKeyboardKey.bracketRight, meta: true);
    await press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
    await press(tester, LogicalKeyboardKey.arrowDown, alt: true, shift: true);
    await press(tester, LogicalKeyboardKey.keyN, meta: true);
    await press(tester, LogicalKeyboardKey.keyK, meta: true);
    await press(tester, LogicalKeyboardKey.keyF, meta: true);
    await press(tester, LogicalKeyboardKey.slash, meta: true);
    await press(tester, LogicalKeyboardKey.comma, meta: true);
    await press(tester, LogicalKeyboardKey.keyA, meta: true, shift: true);
    await press(tester, LogicalKeyboardKey.keyU, meta: true, shift: true);
    expect(calls, [
      'open 0',
      'open 8',
      'step 1',
      'step -1',
      'step 1',
      'step -1',
      'unread',
      'search',
      'search',
      'search',
      'help',
      'settings',
      'archive',
      'mark unread',
    ]);
  });

  testWidgets('⌘F searches the open chat; ⌘↑/⌘↓ scroll it', (tester) async {
    MacDesktopCommands.bindChat(
      'chat',
      MacChatCommands(
        searchInChat: () => calls.add('chat search'),
        scrollToTop: () => calls.add('top'),
        scrollToBottom: () => calls.add('bottom'),
      ),
    );
    await mount(tester);
    focus.requestFocus();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyF, meta: true);
    await press(tester, LogicalKeyboardKey.arrowUp, meta: true);
    await press(tester, LogicalKeyboardKey.arrowDown, meta: true);
    expect(calls, ['chat search', 'top', 'bottom']);
    MacDesktopCommands.unbindChat('other');
    expect(MacDesktopCommands.hasChat, isTrue);
    MacDesktopCommands.unbindChat('chat');
    await press(tester, LogicalKeyboardKey.keyF, meta: true);
    expect(calls.last, 'search');
  });

  testWidgets('arrow shortcuts leave a field with text to text editing', (
    tester,
  ) async {
    MacDesktopCommands.bindChat(
      'chat',
      MacChatCommands(
        searchInChat: () {},
        scrollToTop: () => calls.add('top'),
        scrollToBottom: () => calls.add('bottom'),
      ),
    );
    await mount(tester);
    focus.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'first line\nsecond');
    await press(tester, LogicalKeyboardKey.arrowUp, meta: true);
    await press(tester, LogicalKeyboardKey.arrowDown, alt: true);
    expect(calls, isEmpty);
    // Chat switching without arrows still works while typing.
    await press(tester, LogicalKeyboardKey.tab, control: true);
    expect(calls, ['step 1']);
  });

  testWidgets('no shortcut navigates through the app lock', (tester) async {
    await mount(tester);
    focus.requestFocus();
    await tester.pump();
    PersonalPrivacy.surfaceUnlocked = false;
    await press(tester, LogicalKeyboardKey.digit1, meta: true);
    await press(tester, LogicalKeyboardKey.tab, control: true);
    await press(tester, LogicalKeyboardKey.slash, meta: true);
    await press(tester, LogicalKeyboardKey.comma, meta: true);
    await press(tester, LogicalKeyboardKey.keyA, meta: true, shift: true);
    expect(calls, isEmpty);
  });

  test('the help sheet lists every bound key family', () {
    final keys = macShortcutHelp.map((e) => e.keys).join(' ');
    for (final key in [
      '⌘K',
      '⌘N',
      '⌘F',
      '⌘1',
      '⌃Tab',
      '⌘[',
      '⌘]',
      '⌥⇧↓',
      '⌘↑',
      '⌘↓',
      '⌘,',
      '⌘/',
      '⌘⇧A',
      '⌘⇧U',
      '⌘↩',
      '⌘W',
      'Esc',
    ]) {
      expect(keys, contains(key));
    }
  });
}

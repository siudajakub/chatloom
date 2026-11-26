// SPDX-License-Identifier: AGPL-3.0-or-later
// Idle-frame gate (perf wave 2026-11-26): an app nobody touches draws no
// frames. Every main screen (inbox, conversation, merged conversation,
// chat details, settings, plus the production inbox and chat page over the
// offline fixtures) must stop asking for frames once its entrance motion is
// over, keep no periodic timer armed, and stay silent for ten fake minutes.
// With tickers off (TickerMode, or NotionActivity while the app is
// inactive) the screens must not draw at all. The sticker panel must not
// poll a fling frozen by TickerMode off (the `_ScrollAwareLoad` loop in
// lib/personal/stickers/sticker_tile.dart).
//
// Frames are counted in fake time: time passes without drawing and a frame
// is drawn only when one was asked for (see `idleFrames`).
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/events/message_content.dart';
import 'package:chatloom/personal/stickers/gif_tab.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_panel.dart';
import 'package:chatloom/personal/stickers/sticker_tab.dart';
import 'package:chatloom/personal/stickers/sticker_tile.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';
import '../personal/stickers/sticker_test_support.dart';
import 'idle_support.dart';
import 'perf_fixtures.dart';
import 'perf_scenarios.dart';

/// Longest entrance motion of a screen at rest (page transition, staggered
/// rows, badges). A frame asked for later is a loop or a timer at rest.
const _entrance = Duration(seconds: 2);

/// Fake time a settled screen is watched for.
const _soak = Duration(minutes: 10);

/// With tickers off a screen may still draw the one follow-up frame right
/// after it is built (the focus manager's first focus pass rebuilds the
/// `Focus` widgets once); nothing after that.
const _followUp = Duration(milliseconds: 100);

/// One-shot timers that are armed forever only in fake time, by origin.
/// `RoomPrefetchScope` measures quiet time with a real `Stopwatch`
/// (lib/personal/media/media_prefetcher.dart:689), which does not advance
/// under fake time, so `_tick` re-arms itself; on a device real time passes
/// and it flushes once. Its timer never schedules a frame.
const _fakeTimeOnly = ['media_prefetcher.dart'];

List<String> _unexpected(List<String> armed) => [
  for (final line in armed)
    if (!_fakeTimeOnly.any(line.contains)) line,
];

void _phone(WidgetTester tester) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

/// Settles the screen past [NotionMotion.loopCap] and checks it is idle:
/// no frame after the entrance, no ticker, no periodic timer, and nothing
/// for [_soak] more.
Future<void> _expectIdle(
  WidgetTester tester,
  TimerSpy spy,
  String name, {
  Duration entrance = _entrance,
}) async {
  final settle = await spy.run(
    () => idleFrames(tester, NotionMotion.loopCap + const Duration(seconds: 5)),
  );
  expect(tester.takeException(), isNull, reason: name);
  final late = settle.where((t) => t > entrance).toList();
  expect(
    late,
    isEmpty,
    reason:
        '$name keeps asking for frames at rest (${late.length} frames, '
        'last at ${late.lastOrNull}); armed timers: ${spy.armed}',
  );
  expect(tester.binding.hasScheduledFrame, isFalse, reason: name);
  expect(tester.binding.transientCallbackCount, 0, reason: '$name tickers');
  expect(spy.armedPeriodic, isEmpty, reason: '$name periodic timers');

  final soak = await spy.run(
    () => idleFrames(tester, _soak, step: const Duration(seconds: 1)),
  );
  expect(
    soak,
    isEmpty,
    reason: '$name re-armed UI work while idle; armed timers: ${spy.armed}',
  );
  expect(
    _unexpected(spy.armed),
    isEmpty,
    reason: '$name timers after $_soak idle',
  );
}

class _Host implements ConversationComposerHost {
  _Host(this.room);

  @override
  final Room room;
  @override
  final FocusNode inputFocus = FocusNode();
  @override
  final TextEditingController sendController = TextEditingController();
  @override
  bool showEmojiPicker = true;
  @override
  Event? replyEvent;

  @override
  String? get activeThreadId => null;
  @override
  String? get threadLastEventId => null;
  @override
  void cancelReplyEventAction() {}
  @override
  void onEmojiSelected(Category? category, Emoji? emoji) {}
  @override
  void emojiPickerBackspace() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(initPerfSettings);
  tearDown(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  group('screens at rest draw no frames', () {
    for (final MapEntry(key: name, value: screen) in idleScreens.entries) {
      testWidgets(name, (tester) async {
        _phone(tester);
        final spy = TimerSpy();
        await spy.run(() => tester.pumpWidget(idleHost(screen())));
        await _expectIdle(tester, spy, name);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('production inbox (ChatList over fixtures)', (tester) async {
      _phone(tester);
      final fixture = perfInbox(rooms: 120);
      final spy = TimerSpy();
      await spy.run(() async {
        await tester.pumpWidget(perfApp(fixture.client, const PerfInbox()));
        await perfInboxRows(tester);
      });
      expect(find.byType(NotionInboxRow), findsWidgets, reason: 'real rows');
      await _expectIdle(tester, spy, 'production inbox');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('production chat page (ChatPage over fixtures)', (
      tester,
    ) async {
      _phone(tester);
      final fixture = perfConversation(events: 120);
      final spy = TimerSpy();
      await spy.run(() async {
        await tester.pumpWidget(
          perfApp(fixture.client, perfChatPage(fixture.room)),
        );
        await _waitFor(tester, find.byType(MessageContent));
        // Off mobile the composer is autofocused
        // (lib/pages/chat/chat_input_row.dart:479), and a focused field
        // blinks its cursor: EditableText's periodic 500 ms timer draws two
        // frames a second for as long as the window is focused (it stops
        // under TickerMode off). Measured here: everything else.
        final focused = [
          for (final field in tester.stateList<EditableTextState>(
            find.byType(EditableText),
          ))
            if (field.widget.focusNode.hasFocus) field.widget.focusNode,
        ];
        for (final node in focused) {
          node.unfocus();
        }
        await tester.pump();
      });
      await _expectIdle(tester, spy, 'production chat page');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('tickers off: no frames at all', () {
    for (final MapEntry(key: name, value: screen) in idleScreens.entries) {
      testWidgets('$name under TickerMode off', (tester) async {
        _phone(tester);
        await tester.pumpWidget(idleHost(screen(), mode: IdleMode.tickersOff));
        final frames = await idleFrames(tester, NotionMotion.loopCap);
        expect(tester.takeException(), isNull);
        expect(
          frames.where((t) => t > _followUp),
          isEmpty,
          reason: '$name drew with tickers off',
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('$name goes quiet when the app turns inactive', (
        tester,
      ) async {
        _phone(tester);
        final binding = tester.binding;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(idleHost(screen(), mode: IdleMode.inactive));
        // Mid-entrance: page and row motion is still running.
        await tester.pump(const Duration(milliseconds: 16));
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        // One frame applies TickerMode off (and the end state of one-shot
        // motion, NotionMotion.reduced); then nothing.
        await tester.pump();
        final frames = await idleFrames(tester, NotionMotion.loopCap);
        expect(tester.takeException(), isNull);
        expect(
          frames.where((t) => t > _followUp),
          isEmpty,
          reason: '$name drew while inactive',
        );
        expect(binding.hasScheduledFrame, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('production inbox and chat page under TickerMode off', (
      tester,
    ) async {
      _phone(tester);
      final inbox = perfInbox(rooms: 120);
      await tester.pumpWidget(
        TickerMode(
          enabled: false,
          child: perfApp(inbox.client, const PerfInbox()),
        ),
      );
      await perfInboxRows(tester);
      expect(find.byType(NotionInboxRow), findsWidgets, reason: 'real rows');
      // Localizations and the first page arrive asynchronously; after that
      // nothing may ask for a frame.
      await idleFrames(tester, const Duration(seconds: 1));
      expect(
        await idleFrames(tester, NotionMotion.loopCap),
        isEmpty,
        reason: 'production inbox drew with tickers off',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));

      final chat = perfConversation(events: 120);
      await tester.pumpWidget(
        TickerMode(
          enabled: false,
          child: perfApp(chat.client, perfChatPage(chat.room)),
        ),
      );
      await _waitFor(tester, find.byType(MessageContent));
      await idleFrames(tester, const Duration(seconds: 1));
      expect(
        await idleFrames(tester, NotionMotion.loopCap),
        isEmpty,
        reason: 'production chat page drew with tickers off',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('sticker panel', () {
    late StickerLibrary library;
    late _Host host;
    late FocusNode panelFocus;

    setUp(() {
      final client = ConversationClient();
      host = _Host(ConversationRoom(client, '!chat:example.invalid'));
      final backend = FakeStickerBackend();
      library = fakeLibrary(backend);
      panelFocus = FocusNode();
      StickerLibrary.debugSet(client, library);
      StickerPanel.debugResetTab(StickerPanelTab.stickers);
      StickerTab.debugResetPosition();
      GifTab.debugResetPosition();
      backend.rooms['!space:example.invalid'] = {
        for (var p = 1; p <= 6; p++)
          'P$p': pack('Pack $p', {
            for (var i = 0; i < 30; i++) 'P${p}_$i': packImage('p${p}s$i'),
          }),
      };
      for (var p = 6; p >= 1; p--) {
        library.addPack(
          StickerPackRef(roomId: '!space:example.invalid', stateKey: 'P$p'),
        );
      }
    });
    tearDown(() {
      library.dispose();
      panelFocus.dispose();
      host.inputFocus.dispose();
      host.sendController.dispose();
    });

    testWidgets('a fling frozen by TickerMode off does not poll per frame', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      final tickers = ValueNotifier(true);
      addTearDown(tickers.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: tickers,
          builder: (context, on, child) =>
              TickerMode(enabled: on, child: child!),
          child: MaterialApp(
            theme: NotionTheme.build(Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: 320,
                  child: StickerPanel(host: host, searchFocus: panelFocus),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grid = find.byKey(const ValueKey('sticker-grid'));
      int images() => find
          .descendant(of: grid, matching: find.byType(MxcImage))
          .evaluate()
          .length;
      int cells() => find
          .descendant(of: grid, matching: find.byType(StickerTile))
          .evaluate()
          .length;

      // Fast fling: cells built now wait (placeholder) for it to slow down.
      await tester.fling(grid, const Offset(0, -300), 9000);
      for (var i = 0; i < 3; i++) {
        await tester.pump(perfFrame);
      }
      expect(images(), lessThan(cells()), reason: 'cells wait during a fling');

      // The window loses focus mid-fling: the fling's ticker is muted and
      // its velocity stays high, so a per-frame re-check would never end.
      tickers.value = false;
      await tester.pump();
      await tester.pump();
      final frames = await idleFrames(tester, NotionMotion.loopCap);
      expect(frames, isEmpty, reason: 'polled a frozen fling');
      expect(tester.binding.hasScheduledFrame, isFalse);

      // Focus returns: the fling ends and the waiting cells load.
      tickers.value = true;
      await tester.pumpAndSettle();
      expect(images(), cells());
      final after = await idleFrames(tester, const Duration(seconds: 30));
      expect(after, isEmpty, reason: 'sticker panel idle after the fling');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}

/// Waits (outside fake time) for [finder]: the timeline and localizations
/// load asynchronously.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  await perfReady(tester);
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}

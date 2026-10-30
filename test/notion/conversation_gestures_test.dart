import 'dart:async';

import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _surface = ValueKey('fictional-message-surface');

Future<void> _mount(
  WidgetTester tester, {
  VoidCallback? onReply,
  Future<bool> Function()? onLike,
  ConversationQuickLike Function()? likePreview,
  void Function(ConversationMessagePress press)? onLongPress,
  Object identity = 'fictional-source-event',
  bool enabled = true,
  bool quickLike = true,
  bool rightToLeft = false,
  bool reduced = false,
  TextDirection direction = TextDirection.ltr,
  double width = 260,
  Widget? child,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        disableAnimations: reduced,
      ),
      child: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Center(
            child: ConversationMessageGestures(
              identity: identity,
              enabled: enabled,
              quickLikeEnabled: quickLike,
              swipeRightToLeft: rightToLeft,
              onReply: onReply,
              onLike: onLike,
              likePreview: likePreview,
              onLongPress: onLongPress,
              child: SizedBox(
                key: _surface,
                width: width,
                height: 80,
                child: ColoredBox(
                  color: const Color(0xFF414141),
                  child: child ?? const Text('Fictional message'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _doubleTap(WidgetTester tester) async {
  await tester.tap(find.byKey(_surface));
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(find.byKey(_surface));
  await tester.pump();
}

void main() {
  final haptics = <Object?>[];
  setUp(() {
    haptics.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate')
            haptics.add(call.arguments);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('reply arms at 64 and commits only once on release', (
    tester,
  ) async {
    var replies = 0;
    await _mount(tester, onReply: () => replies++);
    final start = tester.getCenter(find.byKey(_surface));
    final short = await tester.startGesture(start);
    await short.moveBy(const Offset(60, 0));
    await short.up();
    await tester.pumpAndSettle();
    expect(replies, 0);
    expect(haptics, isEmpty);
    final armed = await tester.startGesture(start);
    await armed.moveBy(const Offset(70, 0));
    await tester.pump();
    expect(replies, 0);
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    await armed.moveBy(const Offset(40, 0));
    await armed.up();
    await tester.pumpAndSettle();
    expect(replies, 1);
    expect(haptics, hasLength(1));
    expect(
      (tester.getCenter(find.byKey(_surface)) - start).distance,
      lessThan(.1),
    );
  });

  testWidgets('hysteresis retains arm at 55 but disarms below 48', (
    tester,
  ) async {
    var replies = 0;
    await _mount(tester, onReply: () => replies++);
    final start = tester.getCenter(find.byKey(_surface));
    final retained = await tester.startGesture(start);
    await retained.moveBy(const Offset(70, 0));
    await retained.moveBy(const Offset(-15, 0));
    await retained.up();
    await tester.pumpAndSettle();
    expect(replies, 1);
    final disarmed = await tester.startGesture(start);
    await disarmed.moveBy(const Offset(70, 0));
    await disarmed.moveBy(const Offset(-25, 0));
    await disarmed.moveBy(const Offset(25, 0));
    await disarmed.moveBy(const Offset(-25, 0));
    await disarmed.up();
    await tester.pumpAndSettle();
    expect(replies, 1);
    expect(haptics, hasLength(2));
  });

  testWidgets('rubber band remains below 84 dp', (tester) async {
    await _mount(tester, onReply: () {});
    final start = tester.getCenter(find.byKey(_surface));
    final drag = await tester.startGesture(start);
    await drag.moveBy(const Offset(300, 0));
    await tester.pump();
    final distance = tester.getCenter(find.byKey(_surface)).dx - start.dx;
    expect(distance, greaterThan(64));
    expect(distance, lessThan(84));
    await drag.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('cancel and a second pointer never commit', (tester) async {
    var replies = 0;
    await _mount(tester, onReply: () => replies++);
    final start = tester.getCenter(find.byKey(_surface));
    final canceled = await tester.startGesture(start);
    await canceled.moveBy(const Offset(90, 0));
    await canceled.cancel();
    await tester.pumpAndSettle();
    final first = await tester.startGesture(start, pointer: 1);
    await first.moveBy(const Offset(90, 0));
    final second = await tester.startGesture(start, pointer: 2);
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    expect(replies, 0);
  });

  testWidgets('vertical and diagonal scrolls never arm a reply', (
    tester,
  ) async {
    var replies = 0;
    await _mount(tester, onReply: () => replies++);
    final start = tester.getCenter(find.byKey(_surface));
    for (final delta in [const Offset(0, 100), const Offset(90, 90)]) {
      final drag = await tester.startGesture(start);
      await drag.moveBy(delta);
      await drag.up();
      await tester.pumpAndSettle();
    }
    expect(replies, 0);
    expect(haptics, isEmpty);
  });

  testWidgets('configured swipe direction mirrors in RTL', (tester) async {
    var replies = 0;
    for (final direction in TextDirection.values) {
      await _mount(
        tester,
        direction: direction,
        rightToLeft: true,
        onReply: () => replies++,
      );
      final start = tester.getCenter(find.byKey(_surface));
      final sign = direction == TextDirection.ltr ? -1.0 : 1.0;
      final wrong = await tester.startGesture(start);
      await wrong.moveBy(Offset(-sign * 80, 0));
      await wrong.up();
      await tester.pumpAndSettle();
      final correct = await tester.startGesture(start);
      await correct.moveBy(Offset(sign * 80, 0));
      await correct.up();
      await tester.pumpAndSettle();
    }
    expect(replies, 2);
  });

  testWidgets('system back edges are not captured', (tester) async {
    var replies = 0;
    await _mount(tester, width: 800, onReply: () => replies++);
    final drag = await tester.startGesture(const Offset(10, 300));
    await drag.moveBy(const Offset(110, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(replies, 0);
    expect(haptics, isEmpty);
  });

  testWidgets('disabled (text selection) keeps child controls only', (
    tester,
  ) async {
    var replies = 0;
    var likes = 0;
    var plays = 0;
    await _mount(
      tester,
      enabled: false,
      onReply: () => replies++,
      onLike: () async {
        likes++;
        return true;
      },
      child: TextButton(onPressed: () => plays++, child: const Text('Play')),
    );
    await _doubleTap(tester);
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(_surface)),
    );
    await drag.moveBy(const Offset(90, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(replies, 0);
    expect(likes, 0);
    expect(plays, 2);
  });

  testWidgets(
    'buttons keep immediate single taps; double tap there is theirs; swipe still replies',
    (tester) async {
      var replies = 0;
      var likes = 0;
      var plays = 0;
      await _mount(
        tester,
        onReply: () => replies++,
        onLike: () async {
          likes++;
          return true;
        },
        child: Align(
          alignment: Alignment.topLeft,
          child: TextButton(
            onPressed: () => plays++,
            child: const Text('Play'),
          ),
        ),
      );
      // A single tap on the button lands at once, without waiting out the
      // double-tap window.
      await tester.tap(find.text('Play'));
      await tester.pump();
      expect(plays, 1);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Play'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(plays, 3);
      expect(likes, 0);
      // The bubble's chrome around the button still double-taps.
      final surface = tester.getRect(find.byKey(_surface));
      final chrome = surface.bottomRight - const Offset(20, 20);
      await tester.tapAt(chrome);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(chrome);
      await tester.pumpAndSettle();
      expect(likes, 1);
      // A swipe that starts on the button replies (the drag wins the arena).
      final drag = await tester.startGesture(
        tester.getCenter(find.text('Play')),
      );
      await drag.moveBy(const Offset(24, 0));
      await drag.moveBy(const Offset(70, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(replies, 1);
      expect(plays, 3);
    },
  );

  testWidgets('links in text share the double tap and open after its window', (
    tester,
  ) async {
    var likes = 0;
    var opened = 0;
    final link = TapGestureRecognizer()..onTap = () => opened++;
    addTearDown(link.dispose);
    await _mount(
      tester,
      onLike: () async {
        likes++;
        return true;
      },
      child: Align(
        alignment: Alignment.topLeft,
        child: Text.rich(
          TextSpan(
            text: 'Fictional ',
            children: [TextSpan(text: 'link', recognizer: link)],
          ),
        ),
      ),
    );
    final linkRect = tester.getRect(
      find.text('Fictional link', findRichText: true),
    );
    final onLink = linkRect.centerRight - const Offset(8, 0);
    await tester.tapAt(onLink);
    await tester.pump();
    expect(opened, 0);
    await tester.pump(kDoubleTapTimeout);
    expect(opened, 1);
    await tester.tapAt(onLink);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(onLink);
    await tester.pumpAndSettle();
    expect(likes, 1);
    expect(opened, 1);
    await tester.pump(const Duration(milliseconds: 400));
    final onWord = linkRect.centerLeft + const Offset(8, 0);
    await tester.tapAt(onWord);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(onWord);
    await tester.pumpAndSettle();
    expect(likes, 2);
    expect(opened, 1);
  });

  testWidgets(
    'an inactive voice note replies from its waveform; an active one scrubs',
    (tester) async {
      var replies = 0;
      final seeks = <double>[];
      for (final active in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: ConversationMessageGestures(
                    identity: 'fictional-voice-$active',
                    onReply: () => replies++,
                    child: NotionAudioFileBlock(
                      duration: '0:18 / 1:06',
                      progress: .27,
                      seekDuration: const Duration(seconds: 66),
                      onPlay: () {},
                      onSeek: active ? seeks.add : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final waveform = tester.getRect(
          find.byKey(const ValueKey('voice-waveform')),
        );
        final drag = await tester.startGesture(
          Offset(waveform.left + waveform.width * .3, waveform.center.dy),
        );
        await drag.moveBy(const Offset(24, 0));
        await drag.moveBy(const Offset(70, 0));
        await drag.up();
        await tester.pumpAndSettle();
      }
      expect(replies, 1);
      expect(seeks, hasLength(1));
    },
  );

  testWidgets('long-press sinks the bubble, then reports its rect and finger', (
    tester,
  ) async {
    final presses = <ConversationMessagePress>[];
    final positions = <Offset?>[];
    await _mount(
      tester,
      onReply: () {},
      onLongPress: (press) {
        presses.add(press);
        press.pointer?.addListener(
          () => positions.add(press.pointer!.position),
        );
      },
    );
    final rect = tester.getRect(find.byKey(_surface));
    final finger = await tester.startGesture(rect.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Sinking toward the press scale while held.
    expect(tester.getRect(find.byKey(_surface)).width, lessThan(rect.width));
    await tester.pump(const Duration(milliseconds: 250));
    expect(presses, hasLength(1));
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    final press = presses.single;
    expect(press.rect, rect);
    expect(press.visualRect.width, lessThanOrEqualTo(rect.width));
    expect(press.pointer, isNotNull);
    // The menu takes over: the list bubble is back at rest at once.
    await tester.pump();
    expect(tester.getRect(find.byKey(_surface)), rect);
    await finger.moveBy(const Offset(10, -40));
    await finger.up();
    await tester.pump();
    expect(positions, hasLength(2));
    expect(press.pointer!.released, isTrue);
    press.snapshot?.dispose();
  });

  testWidgets('a previewed add bursts at the finger before the result', (
    tester,
  ) async {
    final response = Completer<bool>();
    await _mount(
      tester,
      onLike: () => response.future,
      likePreview: () => (emoji: '❤️', adds: true),
    );
    await _doubleTap(tester);
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(find.text('❤️'), findsOneWidget);
    expect(find.byType(NotionReactionBurst), findsOneWidget);
    response.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(NotionReactionBurst), findsNothing);
    expect(haptics, hasLength(1));
  });

  testWidgets('mouse double click belongs to the child', (tester) async {
    var likes = 0;
    var selections = 0;
    await _mount(
      tester,
      onLike: () async {
        likes++;
        return true;
      },
      child: GestureDetector(
        onDoubleTap: () => selections++,
        child: const ColoredBox(color: Colors.transparent),
      ),
    );
    await tester.tap(find.byKey(_surface), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byKey(_surface), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(likes, 0);
    expect(selections, 1);
  });

  testWidgets('touch double tap accepts one like with one haptic', (
    tester,
  ) async {
    var likes = 0;
    final response = Completer<bool>();
    await _mount(
      tester,
      onReply: () {},
      onLike: () {
        likes++;
        return response.future;
      },
    );
    await _doubleTap(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await _doubleTap(tester);
    expect(likes, 1);
    expect(haptics, isEmpty);
    response.complete(true);
    await tester.pumpAndSettle();
    expect(haptics, ['HapticFeedbackType.lightImpact']);
  });

  testWidgets('rejected and disabled quick likes have no success feedback', (
    tester,
  ) async {
    var likes = 0;
    await _mount(
      tester,
      onLike: () async {
        likes++;
        return false;
      },
    );
    await _doubleTap(tester);
    await tester.pumpAndSettle();
    expect(likes, 1);
    expect(haptics, isEmpty);
    await _mount(
      tester,
      quickLike: false,
      onLike: () async {
        likes++;
        return true;
      },
    );
    await _doubleTap(tester);
    await tester.pumpAndSettle();
    expect(likes, 1);
    expect(haptics, isEmpty);
  });

  testWidgets('identity replacement cancels drag and stale like feedback', (
    tester,
  ) async {
    var replies = 0;
    final response = Completer<bool>();
    await _mount(
      tester,
      onReply: () => replies++,
      onLike: () => response.future,
    );
    await _doubleTap(tester);
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(_surface)),
    );
    await drag.moveBy(const Offset(90, 0));
    await _mount(
      tester,
      identity: 'another-source-event',
      onReply: () => replies++,
    );
    await drag.up();
    response.complete(true);
    await tester.pumpAndSettle();
    expect(replies, 0);
    expect(
      haptics.where((value) => value == 'HapticFeedbackType.lightImpact'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disableAnimations keeps direct drag and immediate return', (
    tester,
  ) async {
    var replies = 0;
    await _mount(tester, reduced: true, onReply: () => replies++);
    final start = tester.getCenter(find.byKey(_surface));
    final drag = await tester.startGesture(start);
    await drag.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(tester.getCenter(find.byKey(_surface)).dx, greaterThan(start.dx));
    await drag.up();
    await tester.pump();
    expect(replies, 1);
    expect(tester.getCenter(find.byKey(_surface)), start);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('platform reduceMotion stops an already running spring', (
    tester,
  ) async {
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    await _mount(tester, onReply: () {});
    final start = tester.getCenter(find.byKey(_surface));
    final drag = await tester.startGesture(start);
    await drag.moveBy(const Offset(80, 0));
    await drag.up();
    await tester.pump(const Duration(milliseconds: 16));
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    await tester.pump();
    expect(tester.getCenter(find.byKey(_surface)), start);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('dispose during return or pending like is safe', (tester) async {
    final response = Completer<bool>();
    await _mount(tester, onReply: () {}, onLike: () => response.future);
    await _doubleTap(tester);
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(_surface)),
    );
    await drag.moveBy(const Offset(80, 0));
    await drag.up();
    await tester.pumpWidget(const SizedBox());
    response.complete(true);
    // Flutter's double-tap tracker owns a non-cancelable 40 ms minimum-time
    // stopwatch even after the recognizer is disposed.
    await tester.pump(kDoubleTapMinTime);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion changing during like does not lock future likes',
    (tester) async {
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      var likes = 0;
      await _mount(
        tester,
        onLike: () async {
          likes++;
          return true;
        },
      );
      await _doubleTap(tester);
      await tester.pump(const Duration(milliseconds: 20));
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await _doubleTap(tester);
      await tester.pumpAndSettle();
      expect(likes, 2);
      expect(haptics, hasLength(2));
    },
  );

  testWidgets('entrance is opt-in and never repeats on rebuild', (
    tester,
  ) async {
    Widget entrance({required bool animate, String text = 'History'}) =>
        MaterialApp(
          home: ConversationMessageEntrance(
            identity: 'same-event',
            animate: animate,
            child: Text(text),
          ),
        );
    await tester.pumpWidget(entrance(animate: false));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(entrance(animate: true, text: 'Edited'));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(entrance(animate: true));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    await tester.pumpWidget(entrance(animate: true, text: 'Reaction updated'));
    expect(tester.hasRunningAnimations, isFalse);
  });
}

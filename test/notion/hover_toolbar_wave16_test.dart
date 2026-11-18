// SPDX-License-Identifier: AGPL-3.0-or-later
// Desktop hover toolbar and double click (wave 16): the toolbar survives the
// gap between bubble and toolbar, hides after a grace with an exit, and a
// mouse double click reacts. Synthetic widgets and events only.
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _bubble = ValueKey('fictional-bubble');

Future<int Function()> _mount(WidgetTester tester) async {
  var likes = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Scaffold(
        body: SelectionArea(
          child: Center(
            child: ConversationMessageGestures(
              identity: 'fictional-event',
              hoverActions: true,
              hoverReact: () => true,
              quickLikeEnabled: true,
              onReply: () {},
              onLike: () async {
                likes++;
                return true;
              },
              likePreview: () => (emoji: '❤️', adds: true),
              onLongPress: (press) => press.snapshot?.dispose(),
              child: const SizedBox(
                key: _bubble,
                width: 200,
                height: 40,
                child: Text('Fictional words to click'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return () => likes;
}

Future<TestGesture> _mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  return mouse;
}

void main() {
  testWidgets('crossing a gap to the toolbar keeps it; leaving hides it', (
    tester,
  ) async {
    await _mount(tester);
    final mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(find.byKey(_bubble)));
    await tester.pumpAndSettle();
    expect(find.byType(NotionHoverToolbar), findsOneWidget);
    final bubble = tester.getRect(find.byKey(_bubble));
    final bar = tester.getRect(find.byIcon(Icons.reply_rounded));
    // Off both, below the bubble's corner (a diagonal path), for less than
    // the grace.
    await mouse.moveTo(Offset(bubble.right + 2, bubble.bottom + 30));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(NotionHoverToolbar), findsOneWidget);
    await mouse.moveTo(bar.center);
    await tester.pump(NotionHoverToolbar.hideGrace * 2);
    await tester.pumpAndSettle();
    expect(find.byType(NotionHoverToolbar), findsOneWidget);
    final toolbar = tester.widget<NotionHoverToolbar>(
      find.byType(NotionHoverToolbar),
    );
    expect(toolbar.visible, isTrue);
    // Generous targets.
    expect(bar.width, greaterThanOrEqualTo(NotionSize.iconSm));
    expect(
      tester.getSize(find.byTooltip('React')).width,
      greaterThanOrEqualTo(NotionHoverToolbar.slot),
    );
    // Away for good: still there within the grace, then an exit, then gone.
    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.widget<NotionHoverToolbar>(find.byType(NotionHoverToolbar))
          .visible,
      isTrue,
    );
    await tester.pump(NotionHoverToolbar.hideGrace);
    expect(
      tester.widget<NotionHoverToolbar>(find.byType(NotionHoverToolbar))
          .visible,
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(find.byType(NotionHoverToolbar), findsNothing);
  });

  testWidgets('a toolbar hiding comes back when the pointer returns', (
    tester,
  ) async {
    await _mount(tester);
    final mouse = await _mouse(tester);
    final center = tester.getCenter(find.byKey(_bubble));
    await mouse.moveTo(center);
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(NotionHoverToolbar.hideGrace);
    await tester.pump(const Duration(milliseconds: 40));
    await mouse.moveTo(center);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NotionHoverToolbar>(find.byType(NotionHoverToolbar))
          .visible,
      isTrue,
    );
  });

  testWidgets('a mouse double click on text reacts', (tester) async {
    final likes = await _mount(tester);
    final at = tester.getCenter(find.text('Fictional words to click'));
    for (var i = 0; i < 2; i++) {
      if (i > 0) await tester.pump(const Duration(milliseconds: 90));
      final mouse = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.up();
    }
    await tester.pump();
    expect(likes(), 1);
    await tester.pumpAndSettle();
  });

  testWidgets('a single mouse click does not react', (tester) async {
    final likes = await _mount(tester);
    await tester.tap(
      find.text('Fictional words to click'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(likes(), 0);
  });
}

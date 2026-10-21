// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Glass overlays keep one glass state while they animate (wave 3,
// network-motion): the network popover grows out of the dock with its blur
// on from the first to the last frame, the source sheet blurs while it
// slides and drags, nothing above a blur fades or scales, and switching the
// glass state never remounts the content. Frames are pumped one by one.
import 'package:chatloom/pages/chat/conversation_source_picker.dart';
import 'package:chatloom/personal/ui/notion_inbox_dock.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

const _frame = Duration(milliseconds: 16);

/// Product of every opacity applied above [element]'s render object.
double _opacity(Element element) {
  var node = element.renderObject;
  var value = 1.0;
  while (node != null) {
    if (node is RenderAnimatedOpacity) value *= node.opacity.value;
    if (node is RenderOpacity) value *= node.opacity;
    node = node.parent;
  }
  return value;
}

/// Fails when a fade or a scale sits above [element]'s render object.
void _expectNoFadeOrScaleAbove(Element element) {
  var node = element.renderObject?.parent;
  while (node != null) {
    if (node is RenderAnimatedOpacity) {
      expect(node.opacity.value, 1, reason: 'blur inside a fade');
    }
    if (node is RenderOpacity) {
      expect(node.opacity, 1, reason: 'blur inside a fade');
    }
    if (node is RenderTransform) {
      final m = Matrix4.identity();
      node.applyPaintTransform(node.child!, m);
      expect(m.getMaxScaleOnAxis(), 1, reason: 'blur inside a scale');
    }
    node = node.parent;
  }
}

Element _single(Finder finder) {
  final found = finder.evaluate().toList();
  expect(found, hasLength(1));
  return found.single;
}

Widget _dockApp({
  NotionGlassMode mode = NotionGlassMode.on,
  bool reduced = false,
}) => NotionGlassScope(
  mode: mode,
  child: MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(
      body: ListView(
        children: [
          for (var i = 0; i < 30; i++) ListTile(title: Text('Row $i')),
        ],
      ),
      bottomNavigationBar: NotionInboxDock(
        onSettings: () {},
        onSearch: () {},
        onNetworkSelected: (_) {},
        networks: const ['telegram', 'whatsapp', 'signal'],
      ),
    ),
  ),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  final menu = find.byType(NotionNetworkMenu);
  final popoverBlur = find.ancestor(
    of: menu,
    matching: find.byType(BackdropFilter),
  );
  final dockBlur = find.descendant(
    of: find.byType(NotionInboxDock),
    matching: find.byType(BackdropFilter),
  );
  RenderNotionRevealClip reveal(WidgetTester tester) =>
      tester.renderObject<RenderNotionRevealClip>(
        find.ancestor(of: menu, matching: find.byType(NotionRevealClip)),
      );
  Color popoverFill(WidgetTester tester) =>
      (tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: popoverBlur,
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration)
          .color!;

  testWidgets('network popover grows from the dock with one steady blur', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_dockApp());
    final dock = _single(dockBlur);
    await tester.tap(find.byKey(const ValueKey('notion_dock_network')));
    await tester.pump();

    final blur = _single(popoverBlur);
    final filter = (blur.widget as BackdropFilter).filter;
    final row = _single(find.text('Telegram'));
    final fill = popoverFill(tester);
    final full = tester.getSize(find.byType(NotionRevealClip));
    expect(fill.a, lessThan(1), reason: 'translucent glass from frame one');
    final dockTop = tester.getTopLeft(find.byType(NotionInboxDock)).dy;
    expect(
      reveal(
        tester,
      ).localToGlobal(reveal(tester).currentClip.outerRect.center).dy,
      greaterThan(dockTop - 24),
      reason: 'the glass starts at the dock pill',
    );

    var lastWidth = -1.0;
    var lastOpacity = -1.0;
    void frame() {
      // One BackdropFilter, never disabled, never rebuilt into a new
      // element, never under a fade or a scale; one tone.
      expect(_single(popoverBlur), same(blur));
      expect((blur.widget as BackdropFilter).enabled, isTrue);
      expect((blur.widget as BackdropFilter).filter, filter);
      _expectNoFadeOrScaleAbove(blur);
      expect(popoverFill(tester), fill);
      // The rows are never remounted (that replayed their entrance).
      expect(_single(find.text('Telegram')), same(row));
      // The dock's glass is untouched.
      expect(_single(dockBlur), same(dock));
      expect((dock.widget as BackdropFilter).enabled, isTrue);
      _expectNoFadeOrScaleAbove(dock);
    }

    var frames = 0;
    while (tester.hasRunningAnimations && frames++ < 60) {
      frame();
      final width = reveal(tester).currentClip.width;
      expect(width, greaterThanOrEqualTo(lastWidth), reason: 'grows only');
      lastWidth = width;
      final opacity = _opacity(row);
      expect(opacity, greaterThanOrEqualTo(lastOpacity), reason: 'no replay');
      lastOpacity = opacity;
      await tester.pump(_frame);
    }
    frame();
    expect(reveal(tester).revealing, isFalse);
    expect(reveal(tester).currentClip.outerRect.size, full);
    expect(_opacity(row), 1);

    // Close: the rows fade out first, the glass collapses into the pill.
    Navigator.of(tester.element(menu)).pop();
    await tester.pump();
    lastWidth = double.infinity;
    lastOpacity = 2;
    while (menu.evaluate().isNotEmpty) {
      frame();
      final width = reveal(tester).currentClip.width;
      expect(width, lessThanOrEqualTo(lastWidth), reason: 'shrinks only');
      lastWidth = width;
      final opacity = _opacity(row);
      expect(opacity, lessThanOrEqualTo(lastOpacity));
      lastOpacity = opacity;
      await tester.pump(_frame);
    }
    expect(_single(dockBlur), same(dock));
  });

  testWidgets('reduced motion shows the popover at once', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _dockApp(mode: NotionGlassMode.auto, reduced: true),
    );
    await tester.tap(find.byKey(const ValueKey('notion_dock_network')));
    await tester.pump();
    final blur = _single(popoverBlur);
    final row = _single(find.text('Telegram'));
    expect(reveal(tester).revealing, isFalse);
    expect(_opacity(row), 1);
    // No Impeller in tests and reduced motion: the opaque fallback, steady.
    expect((blur.widget as BackdropFilter).enabled, isFalse);
    expect(popoverFill(tester).a, 1);
    await tester.pumpAndSettle();
    expect(_single(popoverBlur), same(blur));
    expect(_single(find.text('Telegram')), same(row));
  });

  testWidgets('the source sheet blurs while it slides and drags', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      NotionGlassScope(
        mode: NotionGlassMode.on,
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showConversationSourcePicker(
                  context,
                  sources: const [
                    ConversationSourceOption(
                      conversation: ConversationRef(
                        accountId: 'fictional-account',
                        roomId: 'fictional-room-a',
                        network: 'telegram',
                      ),
                      title: 'Fictional chat',
                    ),
                    ConversationSourceOption(
                      conversation: ConversationRef(
                        accountId: 'fictional-account',
                        roomId: 'fictional-room-b',
                        network: 'whatsapp',
                      ),
                      title: 'Another fictional chat',
                    ),
                  ],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    final sheetBlur = find.ancestor(
      of: find.text('Send via'),
      matching: find.byType(BackdropFilter),
    );
    final blur = _single(sheetBlur);
    final row = _single(find.text('Fictional chat'));
    void frame() {
      expect(_single(sheetBlur), same(blur));
      expect((blur.widget as BackdropFilter).enabled, isTrue);
      _expectNoFadeOrScaleAbove(blur);
      expect(_single(find.text('Fictional chat')), same(row));
    }

    var frames = 0;
    while (tester.hasRunningAnimations && frames++ < 60) {
      frame();
      await tester.pump(_frame);
    }
    frame();
    // Drag the sheet down by its header and let it spring back.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Send via')),
    );
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(_frame);
      frame();
    }
    await gesture.up();
    frames = 0;
    while (tester.hasRunningAnimations && frames++ < 60) {
      frame();
      await tester.pump(_frame);
    }
    frame();
  });

  testWidgets('a dialog settles into its blur without a remount or a tone '
      'change', (tester) async {
    await tester.pumpWidget(
      NotionGlassScope(
        mode: NotionGlassMode.on,
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showNotionDialog<void>(context: context, title: 'Glass'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(_frame);
    final dialogBlur = find.descendant(
      of: find.byType(NotionDialog),
      matching: find.byType(BackdropFilter),
    );
    final blur = _single(dialogBlur);
    final title = _single(find.text('Glass'));
    final context = tester.element(find.byType(NotionDialog));
    final route = ModalRoute.of(context)!;
    final tokens = context.notion;
    BoxDecoration decoration() =>
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: dialogBlur,
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect((blur.widget as BackdropFilter).enabled, isFalse);
    // While it grows: the tint over the barrier over the page, i.e. what
    // the settled glass shows over an empty page.
    final animating = decoration().color!;
    expect(
      animating,
      Color.alphaBlend(
        tokens.glass.overlayTint,
        Color.alphaBlend(route.barrierColor!, tokens.colors.background),
      ),
    );
    await tester.pumpAndSettle();
    expect(_single(dialogBlur), same(blur));
    expect(_single(find.text('Glass')), same(title));
    expect((blur.widget as BackdropFilter).enabled, isTrue);
    expect(
      Color.alphaBlend(
        decoration().color!,
        Color.alphaBlend(route.barrierColor!, tokens.colors.background),
      ),
      animating,
    );
    Navigator.of(context).pop();
    await tester.pump();
    await tester.pump(_frame);
    expect(_single(dialogBlur), same(blur));
    expect((blur.widget as BackdropFilter).enabled, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('a network change never blanks the list under the glass', (
    tester,
  ) async {
    Widget page(String? network) => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: NotionInboxPage(
        rows: [for (var i = 0; i < 3; i++) Text('Chat $i', key: ValueKey(i))],
        pins: const [],
        onSettings: () {},
        onSearch: () {},
        onNetworkSelected: (_) {},
        networks: const ['telegram'],
        selectedNetwork: network,
      ),
    );
    await tester.pumpWidget(page(null));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page('telegram'));
    final fade = find.byType(SliverFadeTransition);
    var frames = 0;
    do {
      final opacity = tester.widget<SliverFadeTransition>(fade).opacity.value;
      expect(opacity, greaterThanOrEqualTo(NotionMotion.refreshFrom));
      await tester.pump(_frame);
    } while (tester.hasRunningAnimations && frames++ < 60);
    expect(tester.widget<SliverFadeTransition>(fade).opacity.value, 1);
  });
}

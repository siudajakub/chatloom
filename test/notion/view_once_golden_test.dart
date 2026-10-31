// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden references for view-once media (Instagram): the "Tap to view" card
// in incoming and own media bubbles, and opened media with the "Not marked
// as opened on Instagram" badge. The photo is a fictional stand-in.
// Run and update through scripts/verify-notion-ui.py so fonts match.
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _boundary = Key('golden');
void _noop() {}

Future<void> _golden(
  WidgetTester tester,
  String name,
  Widget child, {
  Size size = const Size(390, 760),
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        theme: NotionTheme.build(brightness),
        home: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull, reason: name);
  await expectLater(
    find.byKey(_boundary),
    matchesGoldenFile('goldens/primitives/$name.png'),
  );
}

BorderRadius _radius(BuildContext context, {required bool outgoing}) =>
    ConversationBubble.radiusFor(
      outgoing: outgoing,
      position: ConversationGroupPosition.single,
    ).resolve(Directionality.of(context));

Widget _sealed(String title, String label, {bool outgoing = false}) => Builder(
  builder: (context) => ConversationBubble(
    outgoing: outgoing,
    media: true,
    body: NotionViewOnceCard(
      title: title,
      semanticLabel: label,
      borderRadius: _radius(context, outgoing: outgoing),
      onTap: _noop,
    ),
    footer: Text('12:04', style: context.notion.typography.captionMuted),
  ),
);

/// Opened: the ordinary photo (a flat stand-in) with the badge.
Widget _opened() => Builder(
  builder: (context) {
    final colors = context.notion.colors;
    final radius = _radius(context, outgoing: false);
    return ConversationBubble(
      outgoing: false,
      media: true,
      body: Stack(
        children: [
          ClipRRect(
            borderRadius: radius,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [colors.cover, colors.selected],
                ),
              ),
              child: SizedBox(
                width: 220,
                height: 260,
                child: Icon(
                  Icons.landscape_outlined,
                  size: NotionSize.iconLg * 2,
                  color: colors.textTertiary,
                ),
              ),
            ),
          ),
          const PositionedDirectional(
            top: NotionSpace.xs,
            end: NotionSpace.xs,
            child: NotionViewOnceBadge(
              label: 'Not marked as opened on Instagram',
            ),
          ),
        ],
      ),
      footer: Text('12:05', style: context.notion.typography.captionMuted),
    );
  },
);

Widget _page() => Scaffold(
  body: SafeArea(
    child: ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.sm,
        vertical: NotionSpace.md,
      ),
      children: [
        _sealed('Photo · View once', 'View-once photo'),
        const SizedBox(height: NotionBubble.seriesGap),
        _sealed('Video · Replay allowed', 'View-once video'),
        const SizedBox(height: NotionBubble.seriesGap),
        _sealed('Photo · View once', 'View-once photo', outgoing: true),
        const SizedBox(height: NotionBubble.seriesGap),
        _opened(),
      ],
    ),
  ),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('view-once card and opened badge (dark)', (tester) async {
    await _golden(tester, 'view-once-dark', _page());
  });
  testWidgets('view-once card and opened badge (light)', (tester) async {
    await _golden(
      tester,
      'view-once-light',
      _page(),
      brightness: Brightness.light,
    );
  });
}

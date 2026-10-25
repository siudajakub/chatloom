// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(
  Widget child,
  NotionDisplayPreferences preferences, {
  double scale = 1,
}) {
  final theme = NotionTheme.build(Brightness.dark);
  return MaterialApp(
    theme: theme.copyWith(
      extensions: [...theme.extensions.values, preferences],
    ),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            child: SizedBox(width: 320, child: child),
          ),
        ),
      ),
    ),
  );
}

void main() {
  Widget row() => NotionInboxRow(
    key: const Key('row'),
    avatar: const SizedBox(key: Key('avatar')),
    name: 'Anna',
    preview: 'Hello',
    time: '12:04',
    unreadCount: 2,
    networks: const ['telegram'],
    onTap: () {},
  );

  testWidgets('default inbox is 25 percent shorter and remains accessible', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(row(), const NotionDisplayPreferences(inboxScale: 1)),
    );
    final before = tester.getSize(find.byKey(const Key('row'))).height;
    await tester.pumpWidget(host(row(), NotionDisplayPreferences.standard));
    await tester.pumpAndSettle();
    final after = tester.getSize(find.byKey(const Key('row'))).height;
    expect(before, 88);
    expect(after, closeTo(66, .5));
    expect(after / before, closeTo(.75, .01));
    await tester.pumpWidget(
      host(row(), const NotionDisplayPreferences(inboxScale: .65), scale: 2),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('row'))).height,
      greaterThanOrEqualTo(NotionSize.touchTarget),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inbox visibility preferences preserve unread state and semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          row(),
          const NotionDisplayPreferences(
            inboxAvatars: false,
            inboxPreviews: false,
            inboxTimestamps: false,
            inboxNetworkBadges: false,
            inboxUnreadHighlight: false,
          ),
        ),
      );
      expect(find.byKey(const Key('avatar')), findsNothing);
      expect(find.text('Hello'), findsNothing);
      expect(find.text('12:04'), findsNothing);
      expect(find.text('2'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Anna, Hello, 12:04')),
        findsOneWidget,
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('message size, width, avatar and spacing follow preferences', (
    tester,
  ) async {
    const bubble = ConversationBubble(
      key: Key('bubble'),
      outgoing: false,
      avatar: SizedBox(key: Key('sender')),
      body: Text(
        'A long message that wraps across several lines to check its width.',
        style: NotionType.body,
      ),
    );
    await tester.pumpWidget(host(bubble, NotionDisplayPreferences.standard));
    final original = tester.getSize(find.byKey(const Key('bubble')));
    expect(find.byKey(const Key('sender')), findsOneWidget);
    await tester.pumpWidget(
      host(
        bubble,
        const NotionDisplayPreferences(
          messageTextScale: 1.2,
          messageAvatars: false,
          bubbleWidth: .6,
          messageSpacing: 1.5,
          bubbleRadius: 28,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sender')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('bubble'))).height,
      greaterThan(original.height),
    );
    final context = tester.element(
      find.text(
        'A long message that wraps across several lines to check its width.',
      ),
    );
    expect(MediaQuery.textScalerOf(context).scale(16), closeTo(19.2, .001));
    final fill = find.descendant(
      of: find.byKey(const Key('bubble')),
      matching: find.byType(ClipRRect),
    );
    expect(tester.getSize(fill).width, lessThanOrEqualTo(320 * .6));
    expect(
      tester
          .widget<ClipRRect>(fill)
          .borderRadius
          .resolve(TextDirection.ltr)
          .bottomLeft
          .x,
      28,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('effects respect user overrides', (tester) async {
    late bool reduced;
    late bool glass;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            reduced = NotionMotion.reduced(context);
            glass = notionGlassEnabled(context);
            return const SizedBox();
          },
        ),
        const NotionDisplayPreferences(reduceMotion: true, glassEnabled: false),
      ),
    );
    expect(reduced, isTrue);
    expect(glass, isFalse);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Motion of the inbox surfaces: every animation settles to identity, rows
// built later never animate, loaders do not flash and reduced motion is
// instant.
import 'package:chatloom/config/routes.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/personal/ui/notion_inbox_dock.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/layouts/two_column_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  builder: (context, content) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: content!,
  ),
  home: Scaffold(body: child),
);

Widget _row({
  int count = 0,
  bool unread = false,
  bool muted = false,
  String preview = 'Preview',
  Object? highlight,
}) => NotionInboxRow(
  avatar: const SizedBox.shrink(),
  name: 'Ada',
  preview: preview,
  time: '09:12',
  unreadCount: count,
  unread: unread,
  muted: muted,
  highlight: highlight,
  onTap: () {},
);

NotionInboxPage _page({
  bool loading = false,
  List<Widget> rows = const [],
  String? empty,
}) => NotionInboxPage(
  rows: rows,
  loading: loading,
  emptyMessage: empty,
  pins: const [],
  onCompose: () {},
  onSettings: () {},
  onSearch: () {},
  onNetworkSelected: (_) {},
  networks: const ['telegram'],
);

/// True when no transform below [finder]'s root is mid-animation.
void _expectSettled(WidgetTester tester, Finder finder) {
  for (final fade in tester.widgetList<FadeTransition>(
    find.descendant(of: finder, matching: find.byType(FadeTransition)),
  )) {
    expect(fade.opacity.value, 1);
  }
  for (final scale in tester.widgetList<ScaleTransition>(
    find.descendant(of: finder, matching: find.byType(ScaleTransition)),
  )) {
    expect(scale.scale.value, 1);
  }
}

void main() {
  testWidgets('unread badge pops in, rolls its count and settles', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_row()));
    expect(find.byType(NotionAnimatedCount), findsNothing);

    await tester.pumpWidget(_host(_row(count: 3)));
    await tester.pump(const Duration(milliseconds: 30));
    final popping = tester.widget<ScaleTransition>(
      find
          .ancestor(
            of: find.byType(NotionPop),
            matching: find.byType(ScaleTransition),
          )
          .first,
    );
    expect(popping.scale.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    _expectSettled(tester, find.byType(NotionInboxRow));

    await tester.pumpWidget(_host(_row(count: 4)));
    await tester.pump(const Duration(milliseconds: 40));
    // Both numbers are on screen while the count rolls.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('3'), findsNothing);
    expect(find.text('4'), findsOneWidget);

    await tester.pumpWidget(_host(_row()));
    await tester.pumpAndSettle();
    expect(find.byType(NotionAnimatedCount), findsNothing);
  });

  testWidgets('a row first built with a badge shows it without animating', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_row(count: 2, muted: true)));
    // No pump: the first frame is already at rest (scrolled-in rows).
    _expectSettled(tester, find.byType(NotionInboxRow));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion swaps badge, dot and preview instantly', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_row(unread: true), reduced: true));
    await tester.pumpWidget(
      _host(_row(count: 5, preview: 'New'), reduced: true),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('notion_inbox_unread_dot')), findsNothing);
    expect(find.text('Preview'), findsNothing);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('a new incoming message flashes the row once', (tester) async {
    await tester.pumpWidget(_host(_row()));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(_host(_row(highlight: 1, preview: 'Hi')));
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Hi'), findsOneWidget);
    expect(find.text('Preview'), findsNothing);
  });

  testWidgets('first load shows skeleton rows, then the rows rise in', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(_page(loading: true)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(NotionSkeleton), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('Loading chats'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        _page(
          rows: [
            for (var i = 0; i < 3; i++)
              KeyedSubtree(key: ValueKey('row$i'), child: _row()),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(NotionSkeleton), findsNothing);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(NotionInboxRow), findsNWidgets(3));
    for (final opacity in tester.widgetList<SliverFadeTransition>(
      find.byType(SliverFadeTransition),
    )) {
      expect(opacity.opacity.value, 1);
    }
    semantics.dispose();
  });

  testWidgets('an empty view uses the animated empty state', (tester) async {
    await tester.pumpWidget(_host(_page(empty: 'No chats in Groups.')));
    await tester.pumpAndSettle();
    expect(find.byType(NotionEmptyState), findsOneWidget);
    expect(find.text('No chats in Groups.'), findsOneWidget);
  });

  testWidgets('network selector grows from the dock as a popover', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_page(rows: [_row()])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notion_dock_network')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final menu = find.byType(NotionNetworkMenu);
    expect(menu, findsOneWidget);
    expect(
      ModalRoute.of(tester.element(menu)),
      isA<NotionPopoverRoute<String>>(),
    );
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    _expectSettled(tester, menu);
    await tester.tap(find.text('Telegram'));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
  });

  testWidgets('dock label fades through when the network changes', (
    tester,
  ) async {
    Widget dock(String? network) => _host(
      Align(
        alignment: Alignment.bottomCenter,
        child: NotionInboxDock(
          onSettings: () {},
          onSearch: () {},
          onNetworkSelected: (_) {},
          networks: const ['telegram'],
          selectedNetwork: network,
        ),
      ),
    );
    await tester.pumpWidget(dock(null));
    await tester.pumpWidget(dock('telegram'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('All networks'), findsOneWidget);
    expect(find.text('Telegram'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('All networks'), findsNothing);
  });

  testWidgets('two-column side pane fades in on navigation and settles', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/rooms',
      routes: [
        ShellRoute(
          pageBuilder: (context, state, child) =>
              AppRoutes.noTransitionPageBuilder(
                context,
                state,
                TwoColumnLayout(
                  mainView: const Scaffold(body: Text('Main')),
                  sideView: child,
                ),
              ),
          routes: [
            GoRoute(
              path: '/rooms',
              pageBuilder: (context, state) => AppRoutes.defaultPageBuilder(
                context,
                state,
                const Scaffold(body: Text('Empty pane')),
              ),
              routes: [
                GoRoute(
                  path: 'detail',
                  pageBuilder: (context, state) =>
                      AppRoutes.defaultPageBuilder(
                        context,
                        state,
                        const Scaffold(body: Text('Detail pane')),
                      ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(ChatLoomThemes.isColumnMode(tester.element(find.text('Main'))), true);
    // The layout's own fade: the one that keeps semantics while it runs.
    FadeTransition pane() => tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.text('Detail pane'),
            matching: find.byType(FadeTransition),
          ),
        )
        .singleWhere((fade) => fade.alwaysIncludeSemantics);

    router.go('/rooms/detail');
    await tester.pump();
    expect(pane().opacity.value, lessThan(.5));
    await tester.pumpAndSettle();
    expect(pane().opacity.value, 1);
    // Exactly one live copy of the pane: no switcher.
    expect(find.text('Detail pane'), findsOneWidget);
  });
}

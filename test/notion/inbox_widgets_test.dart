// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_inbox_dock.dart';
import 'package:fluffychat/personal/ui/notion_inbox_page.dart';
import 'package:fluffychat/personal/ui/notion_inbox_pins.dart';
import 'package:fluffychat/personal/ui/notion_inbox_row.dart';
import 'package:fluffychat/personal/ui/notion_search_controls.dart';
import 'package:personal_core/personal_core.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(Widget child, {double scale = 1}) => MaterialApp(
  theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
  builder: (context, content) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      padding: const EdgeInsets.only(top: 44, bottom: 34),
    ),
    child: content!,
  ),
  home: Scaffold(body: child),
);

Widget avatar() => const ColoredBox(color: Color(0xFF555555));
void main() {
  setUpAll(() async {
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Medium.ttf'))
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Bold.ttf'));
    await fonts.load();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'view and network selection remain independent at text scale $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var view = InboxFilter.inbox;
        String? network = 'telegram';
        var managed = 0;
        await tester.pumpWidget(
          host(
            StatefulBuilder(
              builder: (context, update) => Align(
                alignment: Alignment.bottomCenter,
                child: NotionInboxDock(
                  onSettings: () {},
                  onSearch: () {},
                  networks: const ['telegram', 'whatsapp'],
                  selectedNetwork: network,
                  selectedView: view,
                  onNetworkSelected: (value) => update(() => network = value),
                  onViewSelected: (value) => update(() => view = value),
                  onManageNetworks: () => managed++,
                ),
              ),
            ),
            scale: scale,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('notion_dock_network')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ignored'));
        await tester.pumpAndSettle();
        expect(view, InboxFilter.ignored);
        expect(network, 'telegram');
        await tester.tap(find.byKey(const ValueKey('notion_dock_network')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('All networks'), 150);
        await tester.tap(find.text('All networks'));
        await tester.pumpAndSettle();
        expect(view, InboxFilter.ignored);
        expect(network, isNull);
        await tester.tap(find.byKey(const ValueKey('notion_dock_network')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Manage networks'), 150);
        await tester.tap(find.text('Manage networks'));
        await tester.pumpAndSettle();
        expect(managed, 1);
        expect(find.text('Show chats'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('typing stays local; remote discovery needs an explicit press', (
    tester,
  ) async {
    final text = TextEditingController();
    final focus = FocusNode();
    var local = 0;
    var remote = 0;
    var history = 0;
    await tester.pumpWidget(
      host(
        NotionInboxSearch(
          controller: text,
          focusNode: focus,
          onChanged: (_) => local++,
          onClose: () {},
          onHistorySearch: () => history++,
          onPublicDiscovery: () => remote++,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'colleague');
    await tester.pump(const Duration(seconds: 1));
    expect(local, 1);
    expect(remote, 0);
    expect(history, 0);
    await tester.tap(find.text('Discover publicly'));
    expect(remote, 1);
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(text.text, isEmpty);
    expect(local, 2);
    expect(remote, 1);
    await tester.pumpWidget(const SizedBox());
    text.dispose();
    focus.dispose();
  });
  for (final composing in [false, true]) {
    testWidgets('search Escape respects active IME composition: $composing', (
      tester,
    ) async {
      final text = TextEditingController();
      final focus = FocusNode();
      var closed = 0;
      var remote = 0;
      await tester.pumpWidget(
        host(
          NotionInboxSearch(
            controller: text,
            focusNode: focus,
            onChanged: (_) {},
            onClose: () => closed++,
            onHistorySearch: () => remote++,
            onPublicDiscovery: () => remote++,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'fictional query');
      if (composing) {
        text.value = text.value.copyWith(
          composing: const TextRange(start: 0, end: 3),
        );
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, composing ? 0 : 1);
      expect(text.text, 'fictional query');
      expect(remote, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      text.dispose();
      focus.dispose();
    });
  }
  testWidgets('outside dismissal consumes the tap and restores network focus', (
    tester,
  ) async {
    var chatsOpened = 0;
    await tester.pumpWidget(
      host(
        Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => chatsOpened++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 46,
              child: NotionInboxDock(
                onSettings: () {},
                onSearch: () {},
                onNetworkSelected: (_) {},
                networks: const ['whatsapp', 'slack'],
              ),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('All networks'));
    await tester.pumpAndSettle();
    expect(find.text('Show chats'), findsOneWidget);
    await tester.tapAt(const Offset(30, 150));
    await tester.pumpAndSettle();
    expect(find.text('Show chats'), findsNothing);
    expect(chatsOpened, 0);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'Inbox network filter',
    );
    await tester.tap(find.text('All networks'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Show chats'), findsNothing);
  });
  testWidgets('selection fires once and modal Back dismisses', (tester) async {
    final selected = <String?>[];
    await tester.pumpWidget(
      host(
        Align(
          alignment: Alignment.bottomCenter,
          child: NotionInboxDock(
            onSettings: () {},
            onSearch: () {},
            onNetworkSelected: selected.add,
            networks: const ['slack'],
          ),
        ),
      ),
    );
    await tester.tap(find.text('All networks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slack'));
    await tester.pumpAndSettle();
    expect(selected, ['slack']);
    expect(find.text('Show chats'), findsNothing);
    await tester.tap(find.text('All networks'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Show chats'), findsNothing);
  });
  testWidgets(
    'pins collapse when empty, order persists and chats stay in Messages',
    (tester) async {
      Widget page(List<NotionPinnedShortcut> pins) => NotionInboxPage(
        rows: [
          NotionInboxRow(
            avatar: avatar(),
            name: 'Early',
            preview: 'Loaded preview',
            onTap: () {},
          ),
        ],
        pins: pins,
        onCompose: () {},
        onSettings: () {},
        onSearch: () {},
        onNetworkSelected: (_) {},
        networks: const [],
      );
      await tester.pumpWidget(host(page([])));
      expect(find.text('Pinned'), findsNothing);
      await tester.pumpWidget(
        host(
          page([
            NotionPinnedShortcut(
              name: 'Late',
              avatar: avatar(),
              onTap: () {},
              order: 9,
            ),
            NotionPinnedShortcut(
              name: 'Early',
              avatar: avatar(),
              onTap: () {},
              order: 1,
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Early'), findsNWidgets(2));
      final early = tester.getTopLeft(find.text('Early').first);
      final late = tester.getTopLeft(find.text('Late'));
      expect(early.dx, lessThan(late.dx));
      expect(find.text('Messages'), findsOneWidget);
    },
  );
  testWidgets(
    'large text at small width keeps controls and final row above dock',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scroll = ScrollController();
      await tester.pumpWidget(
        host(
          NotionInboxPage(
            scrollController: scroll,
            rows: [
              for (var i = 0; i < 12; i++)
                NotionInboxRow(
                  avatar: avatar(),
                  name: 'A very long conversation name $i',
                  preview: 'A long loaded preview from this conversation',
                  time: '16:45',
                  unreadCount: 2,
                  onTap: () {},
                ),
            ],
            pins: const [],
            onCompose: () {},
            onSettings: () {},
            onSearch: () {},
            onNetworkSelected: (_) {},
            networks: const ['unknown'],
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final row = tester.getBottomLeft(
        find.ancestor(
          of: find.text('A very long conversation name 11'),
          matching: find.byType(NotionInboxRow),
        ),
      );
      final dock = tester.getTopLeft(find.byType(NotionInboxDock));
      expect(row.dy, lessThan(dock.dy));
      expect(find.text('Search'), findsOneWidget);
      final searchText = tester.widget<Text>(find.text('Search'));
      expect(searchText.maxLines, 1);
      expect(searchText.softWrap, false);
      expect(
        tester
            .renderObject<RenderParagraph>(find.text('Search'))
            .didExceedMaxLines,
        false,
      );
      for (final region in ['settings', 'search', 'network']) {
        final target = tester.getSize(
          find.byKey(ValueKey('notion_dock_$region')),
        );
        expect(target.width, greaterThanOrEqualTo(44));
        expect(target.height, greaterThanOrEqualTo(44));
      }
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
  testWidgets('row exposes full unread identity in semantics despite ellipsis', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        NotionInboxRow(
          avatar: avatar(),
          name: 'Long conversation name',
          preview: 'Complete preview',
          time: '16:45',
          unreadCount: 3,
          onTap: () {},
        ),
      ),
    );
    expect(
      find.bySemanticsLabel(
        'Long conversation name, Complete preview, 16:45, 3 unread messages',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(
      host(
        NotionInboxRow(
          avatar: avatar(),
          name: 'Private preference',
          preview: 'Loaded preview',
          muted: true,
          notificationLabel: 'Marked muted in private preferences',
          onTap: () {},
        ),
      ),
    );
    expect(
      find.bySemanticsLabel(
        'Private preference, Loaded preview, Marked muted in private preferences',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });
}

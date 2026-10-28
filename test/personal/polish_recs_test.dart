// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5b lane polish-recs: Report only in native Matrix rooms (CS-24),
// inbox view chips (UX-16), network badges (UX-17, FT-12), row swipes
// (UX-14) and Android conversation shortcuts (FT-21). Fictional offline
// fixtures only.
import 'dart:ui' show Tristate;

import 'package:chatloom/personal/conversation_shortcuts.dart';
import 'package:chatloom/personal/report_policy.dart';
import 'package:chatloom/personal/ui/notion_inbox_network_badge.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/personal/ui/notion_inbox_view_chips.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

Widget _host(Widget child, {bool accessible = false, bool reduced = false}) =>
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            accessibleNavigation: accessible,
            disableAnimations: reduced,
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(alignment: Alignment.topCenter, child: child),
            ),
          ),
        ),
      ),
    );

Widget _row({List<String> networks = const []}) => NotionInboxRow(
  avatar: const ColoredBox(color: Color(0xFF555555)),
  name: 'Fictional person',
  preview: 'Fictional preview',
  networks: networks,
  onTap: () {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Report (CS-24)', () {
    late ConversationClient client;
    setUp(() => client = ConversationClient());

    test('hidden in bridged chats and for bridge ghosts and bots, kept in '
        'native Matrix rooms and for Matrix users', () {
      final bridged = ConversationRoom(client, '!bridged:example.invalid');
      bridged.state('m.bridge', {
        'bridgebot': '@whatsappbot:beeper.invalid',
        'protocol': {'id': 'whatsapp'},
      }, key: 'portal');
      final unknownNetwork = ConversationRoom(
        client,
        '!unknown:example.invalid',
        network: 'linkedin',
      );
      final native = Room(
        id: '!native:example.invalid',
        client: client,
        membership: Membership.join,
      );
      final declaredMatrix = ConversationRoom(
        client,
        '!matrix:example.invalid',
        network: 'matrix',
      );

      expect(canReportInRoom(bridged), isFalse);
      expect(canReportInRoom(unknownNetwork), isFalse);
      expect(canReportInRoom(native), isTrue);
      expect(canReportInRoom(declaredMatrix), isTrue);

      expect(
        canReportUser(client, '@whatsapp_48600000000:beeper.invalid'),
        isFalse,
        reason: 'A bridge ghost: the report would reach Beeper',
      );
      expect(canReportUser(client, '@whatsappbot:beeper.invalid'), isFalse);
      expect(canReportUser(client, client.userID), isFalse);
      expect(
        canReportUser(client, '@someone:matrix.invalid', room: bridged),
        isFalse,
      );
      expect(
        canReportUser(client, '@someone:matrix.invalid', room: native),
        isTrue,
      );
    });

    test('a Matrix user without a bridged direct chat can be reported', () {
      final native = Room(
        id: '!native:example.invalid',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(native);
      expect(canReportUser(client, '@stranger:matrix.invalid'), isTrue);
      expect(
        canReportUser(client, '@stranger:matrix.invalid', room: native),
        isTrue,
      );
    });
  });

  group('View chips (UX-16)', () {
    testWidgets('select the shared view, show the unread count and keep a '
        'view chosen elsewhere labelled', (tester) async {
      var view = InboxFilter.inbox;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, update) => NotionInboxViewChips(
              selected: view,
              unreadCount: 3,
              onViewSelected: (value) => update(() => view = value),
            ),
          ),
        ),
      );
      expect(find.text('All'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.text('Unread'));
      await tester.pumpAndSettle();
      expect(view, InboxFilter.unread);
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expect(view, InboxFilter.groups);
      // Tapping the selected chip changes nothing.
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expect(view, InboxFilter.groups);

      await tester.pumpWidget(
        _host(
          NotionInboxViewChips(
            selected: InboxFilter.archive,
            onViewSelected: (_) {},
          ),
        ),
      );
      expect(find.text('Archive'), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('notion_inbox_chip_archive')),
            )
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Network badge (UX-17, FT-12)', () {
    test('badge networks skip unnamed ones and keep a stable order', () {
      expect(notionBadgeNetworks(['whatsapp', 'other', 'telegram']), [
        'telegram',
        'whatsapp',
      ]);
      expect(notionBadgeNetworks(['unknown']), isEmpty);
      expect(notionNetworksAnnouncement(const []), isNull);
      expect(notionNetworksAnnouncement(['telegram']), 'On Telegram');
      expect(
        notionNetworksAnnouncement(['signal', 'telegram', 'whatsapp']),
        'On Signal, Telegram and WhatsApp',
      );
    });

    testWidgets('one mark per chat, two stacked for a merged person, none '
        'without networks; announced with the row', (tester) async {
      await tester.pumpWidget(_host(_row()));
      expect(
        find.byKey(const ValueKey('notion_inbox_network_badge')),
        findsNothing,
      );

      await tester.pumpWidget(_host(_row(networks: ['whatsapp'])));
      final single = tester.getSize(
        find.byKey(const ValueKey('notion_inbox_network_badge')),
      );
      expect(single.width, notionInboxBadgeSize);

      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_row(networks: ['telegram', 'whatsapp'])));
      final stacked = tester.getSize(
        find.byKey(const ValueKey('notion_inbox_network_badge')),
      );
      expect(stacked.width, greaterThan(single.width));
      expect(
        find.bySemanticsLabel(RegExp('On Telegram and WhatsApp')),
        findsOneWidget,
      );
      handle.dispose();
      expect(tester.takeException(), isNull);
    });
  });

  group('Row swipe (UX-14)', () {
    late List<String> committed;
    late List<String> haptics;

    setUp(() {
      committed = [];
      haptics = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add('${call.arguments}');
            }
            return null;
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    // A phone-width row (arm point at 30 % of it).
    void narrow(WidgetTester tester) {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Widget swipe({bool accessible = false, bool reduced = false}) => _host(
      NotionSwipeAction(
        key: const ValueKey('swipe'),
        endToStart: NotionSwipeActionSide(
          icon: Icons.archive_outlined,
          label: 'Archive',
          onCommit: () => committed.add('archive'),
        ),
        startToEnd: NotionSwipeActionSide(
          icon: Icons.mark_chat_read_outlined,
          label: 'Read',
          onCommit: () => committed.add('read'),
        ),
        child: _row(),
      ),
      accessible: accessible,
      reduced: reduced,
    );

    testWidgets('left past the arm point archives, right marks read, a short '
        'swipe does nothing; the row springs back', (tester) async {
      narrow(tester);
      await tester.pumpWidget(swipe());
      final row = find.byKey(const ValueKey('swipe'));
      final rest = tester.getTopLeft(find.text('Fictional person'));

      final gesture = await tester.startGesture(tester.getCenter(row));
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-120, 0));
      await tester.pump();
      expect(find.text('Archive'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Fictional person')).dx,
        lessThan(rest.dx),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(committed, ['archive']);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      expect(tester.getTopLeft(find.text('Fictional person')), rest);
      expect(find.text('Archive'), findsNothing);

      await tester.drag(row, const Offset(30, 0));
      await tester.pumpAndSettle();
      expect(committed, ['archive'], reason: 'Released before arming');

      await tester.drag(row, const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(committed, ['archive', 'read']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('starting and ending a swipe never remounts the row', (
      tester,
    ) async {
      narrow(tester);
      final mounts = <int>[];
      await tester.pumpWidget(
        _host(
          NotionSwipeAction(
            key: const ValueKey('swipe'),
            endToStart: NotionSwipeActionSide(
              icon: Icons.archive_outlined,
              label: 'Archive',
              onCommit: () => committed.add('archive'),
            ),
            child: _SwipeMountProbe(mounts),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('swipe'))),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(mounts, [1]);
    });

    testWidgets('a dismissing side flies off, closes its slot, then commits; '
        'a row that stays comes back', (tester) async {
      narrow(tester);
      await tester.pumpWidget(
        _host(
          NotionSwipeAction(
            key: const ValueKey('swipe'),
            endToStart: NotionSwipeActionSide(
              icon: Icons.archive_outlined,
              label: 'Archive',
              dismisses: true,
              onCommit: () => committed.add('archive'),
            ),
            child: _row(),
          ),
        ),
      );
      final swipe = find.byKey(const ValueKey('swipe'));
      final height = tester.getSize(swipe).height;
      final rest = tester.getTopLeft(find.text('Fictional person'));
      await tester.drag(swipe, const Offset(-200, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(committed, isEmpty, reason: 'Commits after the slot closed');
      expect(
        tester.getTopLeft(find.text('Fictional person')).dx,
        lessThan(rest.dx - 200),
      );
      // Fly-off spring plus the collapse.
      for (var i = 0; i < 40 && committed.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(committed, ['archive']);
      expect(tester.getSize(swipe).height, 0);
      // Nobody removed the row: it grows and slides back.
      await tester.pumpAndSettle();
      expect(tester.getSize(swipe).height, height);
      expect(tester.getTopLeft(find.text('Fictional person')), rest);
      expect(find.text('Archive'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a dismissing row removed by its list leaves nothing behind', (
      tester,
    ) async {
      narrow(tester);
      var shown = true;
      late StateSetter update;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (shown)
                    NotionSwipeAction(
                      key: const ValueKey('swipe'),
                      endToStart: NotionSwipeActionSide(
                        icon: Icons.archive_outlined,
                        label: 'Archive',
                        dismisses: true,
                        onCommit: () => update(() => shown = false),
                      ),
                      child: _row(),
                    ),
                  const Text('Below'),
                ],
              );
            },
          ),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('swipe')),
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('swipe')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a swipe from the back-gesture edge is the system\'s', (
      tester,
    ) async {
      narrow(tester);
      await tester.pumpWidget(swipe());
      final y = tester.getCenter(find.byKey(const ValueKey('swipe'))).dy;
      await tester.dragFrom(Offset(8, y), const Offset(250, 0));
      await tester.pumpAndSettle();
      expect(committed, isEmpty);
    });

    testWidgets('reduced motion returns the row at once', (tester) async {
      narrow(tester);
      await tester.pumpWidget(swipe(reduced: true));
      final rest = tester.getTopLeft(find.text('Fictional person'));
      await tester.drag(
        find.byKey(const ValueKey('swipe')),
        const Offset(-200, 0),
      );
      await tester.pump();
      expect(committed, ['archive']);
      expect(tester.getTopLeft(find.text('Fictional person')), rest);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('with a screen reader the swipe is off and the actions are '
        'custom semantics actions', (tester) async {
      final handle = tester.ensureSemantics();
      narrow(tester);
      await tester.pumpWidget(swipe(accessible: true));
      final row = find.byKey(const ValueKey('swipe'));
      await tester.drag(row, const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(committed, isEmpty);
      final data = tester.getSemantics(row).getSemanticsData();
      expect(data.customSemanticsActionIds, hasLength(2));
      handle.dispose();
    });
  });

  group('Conversation shortcuts (FT-21)', () {
    test('action strings round-trip; other launcher actions pass through', () {
      const shortcut = ConversationShortcut(
        entity: 'person:fictional',
        label: 'Fictional person',
      );
      expect(conversationShortcutEntity(shortcut.action), 'person:fictional');
      expect(conversationShortcutEntity('https://example.invalid'), isNull);
      expect(conversationShortcutEntity(conversationShortcutPrefix), isNull);
    });

    test('published only on change, at most every few minutes; removed at '
        'once when not allowed', () {
      var now = DateTime.utc(2026, 10, 22, 9);
      final published = <List<ConversationShortcut>>[];
      var cleared = 0;
      final publisher = ConversationShortcutPublisher(
        publish: (shortcuts) async => published.add(shortcuts),
        clear: () async => cleared++,
        now: () => now,
      );
      const a = ConversationShortcut(entity: '!a:example.invalid', label: 'A');
      const b = ConversationShortcut(entity: '!b:example.invalid', label: 'B');

      publisher.offer([a, b], allowed: true);
      expect(published, hasLength(1));
      publisher.offer([a, b], allowed: true);
      expect(published, hasLength(1), reason: 'Unchanged');
      now = now.add(const Duration(minutes: 1));
      publisher.offer([b, a], allowed: true);
      expect(published, hasLength(1), reason: 'Too soon');
      now = now.add(publisher.minInterval);
      publisher.offer([b, a], allowed: true);
      expect(published.last, [b, a]);

      publisher.offer([a], allowed: false);
      expect(cleared, 1);
      publisher.offer([a], allowed: false);
      expect(cleared, 1, reason: 'Already removed');
      publisher.offer([a], allowed: true);
      expect(published.last, [a], reason: 'Back after removal at once');
    });
  });
}

/// Counts the mounts of a swiped row's content.
class _SwipeMountProbe extends StatefulWidget {
  const _SwipeMountProbe(this.mounts);

  final List<int> mounts;

  @override
  State<_SwipeMountProbe> createState() => _SwipeMountProbeState();
}

class _SwipeMountProbeState extends State<_SwipeMountProbe> {
  @override
  void initState() {
    super.initState();
    widget.mounts.add(widget.mounts.length + 1);
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 64, child: Text('Probe'));
}

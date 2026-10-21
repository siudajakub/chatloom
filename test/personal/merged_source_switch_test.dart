// SPDX-License-Identifier: AGPL-3.0-or-later
// Switching the send network of a merged person chat (the network chip in the
// composer). The page is hosted like `PersonChatRoutePage`: every private
// store notification re-reads the person, i.e. hands over a new PersonGroup
// object for the same group. Fictional offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_event_list.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/events/message.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/person_group_identity.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// Like the production client: a saved draft changes the replica, and every
/// replica change notifies listeners.
class _Personal extends ConversationPersonal {
  _Personal(super.client);
  @override
  Future<void> savePersonalDraft(
    String key,
    SendTarget target,
    String text,
  ) async {
    await super.savePersonalDraft(key, target, text);
    poke();
  }

  void poke() => notifyListeners();
}

/// Records typing notifications instead of sending them.
class _Room extends ConversationRoom {
  final typing = <bool>[];
  _Room(super.client, super.id, {super.network});
  @override
  Future<void> setTyping(bool isTyping, {int? timeout}) async =>
      typing.add(isTyping);
}

/// The worst case of a host: like `PersonChatRoutePage` before this fix,
/// each store notification (or a changed stored group) rebuilds and parses
/// the group again from its JSON, i.e. hands over a new object.
class _RouteHost extends StatefulWidget {
  final _Personal personal;
  final ValueNotifier<PersonGroup> group;
  const _RouteHost({required this.personal, required this.group});
  @override
  State<_RouteHost> createState() => _RouteHostState();
}

class _RouteHostState extends State<_RouteHost> {
  @override
  void initState() {
    super.initState();
    widget.personal.addListener(_changed);
    widget.group.addListener(_changed);
  }

  @override
  void dispose() {
    widget.personal.removeListener(_changed);
    widget.group.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) => MergedChatPage(
    personal: widget.personal,
    group: PersonGroup.fromJson(
      Map<String, dynamic>.from(widget.group.value.toJson()),
    ),
  );
}

Future<void> _mount(WidgetTester tester, Widget child, Client client) async {
  final state = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: state,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Counts rebuilds of message rows while [body] runs.
Future<int> _rowRebuilds(Future<void> Function() body) async {
  var count = 0;
  debugOnRebuildDirtyWidget = (element, _) {
    if (element.widget is Message) count++;
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return count;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late ConversationClient client;
  late _Room whatsapp, telegram, messenger;
  late _Personal personal;
  late ValueNotifier<PersonGroup> group;

  setUp(() {
    client = ConversationClient();
    whatsapp = _Room(client, '!switch-wa:example.invalid');
    telegram = _Room(client, '!switch-tg:example.invalid', network: 'telegram');
    messenger = _Room(
      client,
      '!switch-fb:example.invalid',
      network: 'messenger',
    );
    // Interleaved fictional history; the newest message is from WhatsApp.
    for (var i = 0; i < 18; i++) {
      final room = [telegram, messenger, whatsapp][i % 3];
      room.message('\$switch-$i', 'Fictional message $i', minute: i);
    }
    personal = _Personal(client);
    group = ValueNotifier(
      PersonGroup(
        id: 'switch-person',
        name: 'Anna',
        members: [
          personal.ref(whatsapp),
          personal.ref(telegram),
          personal.ref(messenger),
        ],
        defaultRoomId: whatsapp.id,
      ),
    );
  });
  tearDown(() {
    group.dispose();
    personal.dispose();
  });

  Future<void> mountRoute(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _mount(tester, _RouteHost(personal: personal, group: group), client);
  }

  ConversationSourceChip chip(WidgetTester tester) =>
      tester.widget(find.byType(ConversationSourceChip));

  TextField editor(WidgetTester tester) =>
      tester.widget(find.byType(TextField));

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.byType(ConversationSourceChip));
    await tester.pumpAndSettle();
    expect(find.text('Send via'), findsOneWidget);
  }

  Future<void> choose(WidgetTester tester, String network) async {
    await openPicker(tester);
    await tester.tap(find.text(network).last);
  }

  ScrollPosition timelinePosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(ChatEventList),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  testWidgets(
    'a switch applies at once and keeps text, focus and scroll position',
    (tester) async {
      await mountRoute(tester);
      expect(chip(tester).network, 'whatsapp');
      expect(find.text('Message via WhatsApp'), findsOneWidget);

      await tester.showKeyboard(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Kept fictional draft');
      // The debounced draft save notifies the store like production.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.drag(find.byType(ChatEventList), const Offset(0, 160));
      await tester.pumpAndSettle();
      final offset = timelinePosition(tester).pixels;
      expect(offset, greaterThan(0));
      final mounted = find.byType(Message, skipOffstage: false);
      final rows = mounted.evaluate().length;
      expect(rows, greaterThan(3));

      late int settlePumps;
      final rebuilds = await _rowRebuilds(() async {
        await choose(tester, 'Messenger');
        // The chip changes in the frame of the tap, while the sheet leaves.
        await tester.pump();
        expect(chip(tester).network, 'messenger');
        settlePumps = await tester.pumpAndSettle();
      });
      expect(settlePumps, lessThan(60));
      expect(tester.takeException(), isNull);
      // Every visible row is rebuilt at most once (the list shows the new
      // target's encryption footer), never again for the draft save.
      expect(rebuilds, lessThanOrEqualTo(rows));
      expect(editor(tester).controller!.text, 'Kept fictional draft');
      expect(editor(tester).focusNode!.hasFocus, isTrue);
      expect(editor(tester).decoration!.hintText, 'Message via Messenger');
      expect(timelinePosition(tester).pixels, offset);
      expect(personal.drafts.last.target.conversation, personal.ref(messenger));
      expect(personal.drafts.last.text, 'Kept fictional draft');
    },
  );

  testWidgets('the network glyph morphs to the new source', (tester) async {
    await mountRoute(tester);
    final glyphs = find.descendant(
      of: find.byType(ConversationSourceChip),
      matching: find.byType(NotionNetworkGlyph),
    );
    expect(glyphs, findsOneWidget);
    await choose(tester, 'Telegram');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // Old and new glyph during the swap, then only the new one.
    expect(glyphs, findsNWidgets(2));
    await tester.pumpAndSettle();
    expect(glyphs, findsOneWidget);
    expect(tester.widget<NotionNetworkGlyph>(glyphs).network, 'telegram');
    expect(find.text('Message via Telegram'), findsOneWidget);
  });

  testWidgets('the previous network stops showing typing at once', (
    tester,
  ) async {
    final incognito = AppSettings.personalIncognito.value;
    final typing = AppSettings.sendTypingNotifications.value;
    await AppSettings.personalIncognito.setItem(false);
    await AppSettings.sendTypingNotifications.setItem(true);
    addTearDown(() async {
      await AppSettings.personalIncognito.setItem(incognito);
      await AppSettings.sendTypingNotifications.setItem(typing);
    });
    await mountRoute(tester);
    await tester.enterText(find.byType(TextField), 'Fictional');
    await tester.pump(const Duration(milliseconds: 600));
    expect(whatsapp.typing, [true]);
    await choose(tester, 'Messenger');
    await tester.pump();
    // In the frame of the switch, not after the two-second cool-down.
    expect(whatsapp.typing, [true, false]);
    await tester.pumpAndSettle();
    expect(messenger.typing, isEmpty);
  });

  testWidgets('a store change while the picker is open keeps the choice', (
    tester,
  ) async {
    await mountRoute(tester);
    await openPicker(tester);
    // An acknowledgement or heartbeat arrives: the route re-reads the person.
    personal.poke();
    await tester.pump();
    await tester.tap(find.text('Telegram').last);
    await tester.pumpAndSettle();
    expect(chip(tester).network, 'telegram');
    expect(personal.drafts.last.target.conversation, personal.ref(telegram));
  });

  testWidgets('store notifications under the route do not rebuild the rows', (
    tester,
  ) async {
    await mountRoute(tester);
    final rebuilds = await _rowRebuilds(() async {
      for (var i = 0; i < 3; i++) {
        personal.poke();
        await tester.pump();
      }
    });
    expect(rebuilds, 0);
  });

  testWidgets(
    'choosing the network in use is a no-op; fast switches settle once each',
    (tester) async {
      await mountRoute(tester);
      await choose(tester, 'Messenger');
      await tester.pumpAndSettle();
      final saves = personal.drafts.length;
      expect(saves, 1);

      final again = await _rowRebuilds(() async {
        await choose(tester, 'Messenger');
        await tester.pumpAndSettle();
      });
      expect(again, 0);
      expect(personal.drafts.length, saves);

      // A double tap on the chip opens one picker.
      await tester.tap(find.byType(ConversationSourceChip));
      await tester.tap(
        find.byType(ConversationSourceChip),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Send via'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel source selection'));
      await tester.pumpAndSettle();

      // Quick successive switches, each started while the last sheet leaves.
      for (final network in ['Telegram', 'WhatsApp', 'Messenger', 'Telegram']) {
        await tester.tap(find.byType(ConversationSourceChip));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text(network).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Send via'), findsNothing);
      expect(chip(tester).network, 'telegram');
      expect(
        personal.drafts.skip(saves).map((d) => d.target.conversation.roomId),
        [telegram.id, whatsapp.id, messenger.id, telegram.id],
      );
    },
  );

  testWidgets('a source removed while selected no longer receives messages', (
    tester,
  ) async {
    await mountRoute(tester);
    await choose(tester, 'Messenger');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Fictional draft');
    await tester.pump(const Duration(milliseconds: 600));
    expect(chip(tester).network, 'messenger');

    // Another device removes Messenger from the person.
    group.value = PersonGroup(
      id: 'switch-person',
      name: 'Anna',
      members: [personal.ref(whatsapp), personal.ref(telegram)],
      defaultRoomId: whatsapp.id,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The draft must be routed again by the user, never into the old source.
    expect(chip(tester).hint, ConversationSourceHint.choose);
    expect(editor(tester).controller!.text, 'Fictional draft');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    expect(personal.sends, isEmpty);

    await choose(tester, 'Telegram');
    await tester.pumpAndSettle();
    expect(chip(tester).hint, ConversationSourceHint.none);
    expect(chip(tester).network, 'telegram');
  });

  testWidgets(
    'an unavailable source does not reload the chat on every store change',
    (tester) async {
      final missing = ConversationRoom(client, '!switch-gone:example.invalid');
      client.rooms.remove(missing);
      group.value = PersonGroup(
        id: 'switch-person',
        name: 'Anna',
        members: [
          personal.ref(whatsapp),
          personal.ref(telegram),
          personal.ref(missing),
        ],
        defaultRoomId: whatsapp.id,
      );
      await mountRoute(tester);
      const notice =
          'Some sources are unavailable. History from available networks is shown.';
      expect(find.text(notice), findsOneWidget);
      final l10n = L10n.of(tester.element(find.byType(ChatEventList)));
      await tester.tap(find.byTooltip(l10n.close).first);
      await tester.pumpAndSettle();
      expect(find.text(notice), findsNothing);

      await choose(tester, 'Telegram');
      await tester.pumpAndSettle();
      personal.poke();
      await tester.pumpAndSettle();
      // No reload: the dismissed notice stays dismissed, sending stays on.
      expect(find.text(notice), findsNothing);
      expect(chip(tester).network, 'telegram');
    },
  );

  test('person identity compares the stored group, not the object', () {
    final client = ConversationClient();
    final a = ConversationRoom(client, '!identity-a:example.invalid');
    final b = ConversationRoom(
      client,
      '!identity-b:example.invalid',
      network: 'telegram',
    );
    final personal = ConversationPersonal(client);
    addTearDown(personal.dispose);
    final stored = PersonGroup(
      id: 'identity',
      name: 'Anna',
      members: [personal.ref(a), personal.ref(b)],
      defaultRoomId: a.id,
    );
    PersonGroup reread(PersonGroup g) =>
        PersonGroup.fromJson(Map<String, dynamic>.from(g.toJson()));
    final copy = reread(stored);
    expect(identical(copy, stored), isFalse);
    expect(samePersonGroup(copy, stored), isTrue);
    expect(samePersonMembers(copy, stored), isTrue);
    expect(samePersonGroup(null, null), isTrue);
    expect(samePersonGroup(stored, null), isFalse);

    final renamed = PersonGroup(
      id: 'identity',
      name: 'Anna B',
      members: stored.members,
      defaultRoomId: a.id,
    );
    expect(samePersonGroup(renamed, stored), isFalse);
    expect(samePersonMembers(renamed, stored), isTrue);

    final reordered = PersonGroup(
      id: 'identity',
      name: 'Anna',
      members: [personal.ref(b), personal.ref(a)],
      defaultRoomId: a.id,
    );
    expect(samePersonMembers(reordered, stored), isFalse);

    final relabelled = PersonGroup(
      id: 'identity',
      name: 'Anna',
      members: [
        personal.ref(a),
        ConversationRef(
          accountId: client.userID,
          roomId: b.id,
          network: 'other',
        ),
      ],
      defaultRoomId: a.id,
    );
    expect(samePersonMembers(relabelled, stored), isTrue);
    expect(samePersonGroup(relabelled, stored), isFalse);
  });
}

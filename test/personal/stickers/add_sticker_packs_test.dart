// SPDX-License-Identifier: AGPL-3.0-or-later
// "Add stickers" (wave 11): browse/search Telegram's catalogue through the
// bridge fork, its states (loading, results, old bridge, error, offline),
// pasted links and packs of joined rooms. Fake transports, fictional packs.
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/stickers/add_sticker_packs.dart';
import 'package:chatloom/personal/stickers/room_sticker_packs.dart';
import 'package:chatloom/personal/stickers/sticker_catalog.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_pack_import.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../notion/conversation_test_support.dart';
import 'catalog_test_support.dart';
import 'sticker_test_support.dart';

class _Harness {
  _Harness() {
    library = fakeLibrary(FakeStickerBackend());
    catalog = TelegramStickerCatalog(
      client,
      transport: catalogTransport,
      bridges: const [telegramBridge],
      useDirectory: false,
      retryDelay: Duration.zero,
    );
    provisioning = StickerPackProvisioning(
      client,
      transport: importTransport,
      bridges: const [telegramBridge],
    );
  }

  final client = ConversationClient();
  final catalogTransport = CatalogTransport();
  final importTransport = CatalogTransport();
  late final StickerLibrary library;
  late final TelegramStickerCatalog catalog;
  late final StickerPackProvisioning provisioning;

  Widget app() => MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    home: Scaffold(
      body: AddStickerPacksSheet(
        client: client,
        library: library,
        catalog: catalog,
        provisioning: provisioning,
        roomLoader: RoomPackLoader.of(client),
      ),
    ),
  );
}

final _list = find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

Map<String, Object?> _page(List<int> ids, {int? next}) => {
  'sets': [for (final i in ids) catalogSet(i)],
  'next_offset': ?next,
};

void main() {
  testWidgets('trending: skeleton, then sets; Show more pages', (tester) async {
    final h = _Harness();
    addTearDown(h.library.dispose);
    final first = Completer<Object?>();
    h.catalogTransport.answer = (r) =>
        (r.body!['offset'] == 0) ? first.future : _page([5, 6]);
    await tester.pumpWidget(h.app());
    await tester.pump();
    expect(find.text('Trending on Telegram'), findsOneWidget);
    expect(find.text('Fictional set 1'), findsNothing);
    first.complete(_page([1, 2], next: 2));
    await tester.pumpAndSettle();
    expect(find.text('Fictional set 1'), findsOneWidget);
    expect(find.text('Fictional set 2'), findsOneWidget);
    expect(find.text('11 stickers'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('featured-more')),
      200,
      scrollable: _list,
    );
    await tester.tap(find.byKey(const ValueKey('featured-more')));
    await tester.pumpAndSettle();
    expect(find.text('Fictional set 6'), findsOneWidget);
    expect(find.byKey(const ValueKey('featured-more')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('add-own-pack')),
      200,
      scrollable: _list,
    );
    expect(find.text('Your Telegram packs'), findsOneWidget);
    expect(find.text('Create a pack from images'), findsOneWidget);
  });

  testWidgets('typing searches once after the pause; Add installs', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.library.dispose);
    h.catalogTransport.answer = (r) =>
        r.path.endsWith('search') ? _page([7, 8]) : _page([]);
    h.importTransport.answer = (r) => r.method == 'POST'
        ? {'room_id': '!space:example.invalid', 'state_key': 'FictionalSet7'}
        : pack('Fictional set 7', {
            'smile': packImage('s7'),
          }, url: 'https://t.me/addstickers/FictionalSet7').toJson();
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fict');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'fictional');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final searches = [
      for (final r in h.catalogTransport.requests)
        if (r.path.endsWith('search')) r.body!['query'],
    ];
    expect(searches, ['fictional'], reason: 'debounced into one search');
    expect(find.text('2 packs on Telegram'), findsOneWidget);
    expect(find.text('Fictional set 7'), findsOneWidget);

    await tester.tap(find.widgetWithText(NotionButton, 'Add').first);
    await tester.pumpAndSettle();
    expect(
      h.library.isInstalled('https://t.me/addstickers/FictionalSet7'),
      isTrue,
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
    // A second tap on the same pack can't import again.
    expect(
      h.importTransport.requests.where((r) => r.method == 'POST'),
      hasLength(1),
    );
  });

  testWidgets('no results', (tester) async {
    final h = _Harness();
    addTearDown(h.library.dispose);
    h.catalogTransport.answer = (_) => _page([]);
    await tester.pumpWidget(h.app());
    await tester.enterText(find.byType(TextField), 'nothing');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('No packs found'), findsOneWidget);
  });

  testWidgets(
    'an old bridge: one request, then a calm note; links still work',
    (tester) async {
      final h = _Harness();
      addTearDown(h.library.dispose);
      h.catalogTransport.answer = (_) =>
          throw const BridgeProvisioningException(
            404,
            errcode: 'M_UNRECOGNIZED',
          );
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      expect(
        find.textContaining('needs an update of your Telegram bridge'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'cats');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(h.catalogTransport.requests, hasLength(1));
      expect(find.textContaining('paste a t.me/addstickers'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'https://t.me/addstickers/FictionalPack',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-pack-link')), findsOneWidget);
      expect(find.text('FictionalPack'), findsOneWidget);
    },
  );

  testWidgets('a search error and offline read as sentences with Try again', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.library.dispose);
    var offline = false;
    h.catalogTransport.answer = (r) {
      if (r.path.endsWith('featured')) return _page([]);
      if (offline) throw const BridgeProvisioningException(0);
      throw const BridgeProvisioningException(500, errcode: 'M_UNKNOWN');
    };
    await tester.pumpWidget(h.app());
    await tester.enterText(find.byType(TextField), 'cats');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(
      find.text('Telegram’s sticker packs couldn’t be loaded. Try again.'),
      findsOneWidget,
    );
    offline = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('You’re offline'), findsOneWidget);
    offline = false;
    h.catalogTransport.answer = (r) => _page([3]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Fictional set 3'), findsOneWidget);
  });

  testWidgets('no Telegram bridge: links and other sources only', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.library.dispose);
    final catalog = TelegramStickerCatalog(
      h.client,
      transport: h.catalogTransport,
      bridges: const [],
      useDirectory: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: AddStickerPacksSheet(
            client: h.client,
            library: h.library,
            catalog: catalog,
            provisioning: h.provisioning,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Trending on Telegram'), findsNothing);
    expect(find.text('Paste a sticker pack link'), findsOneWidget);
    expect(h.catalogTransport.requests, isEmpty);
  });

  testWidgets('packs in joined rooms can be added without a request', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.library.dispose);
    h.catalogTransport.answer = (_) => _page([]);
    ConversationRoom(h.client, '!group:example.invalid').state(
      'im.ponies.room_emotes',
      pack('Fictional group pack', {
        'a': packImage('g1', tagged: false),
      }).toJson(),
      key: 'group',
    );
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();
    expect(find.text('Packs in your rooms'), findsOneWidget);
    expect(find.text('Fictional group pack'), findsOneWidget);
    await tester.tap(find.widgetWithText(NotionButton, 'Add'));
    await tester.pumpAndSettle();
    expect(h.library.packs.single.title, 'Fictional group pack');
    // Added: no longer a suggestion.
    expect(find.text('Packs in your rooms'), findsNothing);
  });
}

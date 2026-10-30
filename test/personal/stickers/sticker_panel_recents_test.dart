// SPDX-License-Identifier: AGPL-3.0-or-later
// The composer panel's scrolling and recents: the sticker grid flings, a
// sent sticker is recent at once, emoji pickers open on the recents, and
// every Telegram pack (custom emoji sets too) can be added. Offline
// fixtures, no network.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/stickers/gif_tab.dart';
import 'package:chatloom/personal/stickers/notion_emoji_picker.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_pack_import.dart';
import 'package:chatloom/personal/stickers/sticker_panel.dart';
import 'package:chatloom/personal/stickers/sticker_tab.dart';
import 'package:chatloom/personal/stickers/telegram_pack_import_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

/// A room whose sends never get an answer from the server.
class _SlowRoom extends ConversationRoom {
  _SlowRoom(super.client, super.id, {super.network});
  final pending = Completer<String?>();
  int sends = 0;

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) {
    sends++;
    return pending.future;
  }
}

class _Host implements ConversationComposerHost {
  _Host(this.room);

  @override
  final Room room;
  @override
  final FocusNode inputFocus = FocusNode();
  @override
  final TextEditingController sendController = TextEditingController();
  @override
  bool showEmojiPicker = true;
  @override
  Event? replyEvent;

  @override
  String? get activeThreadId => null;
  @override
  String? get threadLastEventId => null;
  @override
  void cancelReplyEventAction() {}
  @override
  void onEmojiSelected(Category? category, Emoji? emoji) =>
      sendController.text += emoji?.emoji ?? '';
  @override
  void emojiPickerBackspace() {}
  @override
  void emojiPickerAction() => showEmojiPicker = !showEmojiPicker;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers the bridge's image pack API from fixtures.
class _FakeTransport implements BridgeProvisioningTransport {
  final imported = <String>[];

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) async {
    if (request.path == '/v3/image_pack/list') {
      return [
        for (final (name, usage) in [
          ('FictionalPack', 'sticker'),
          ('OtherPack', 'sticker'),
          ('FictionalEmoji', 'emoticon'),
        ])
          {
            'display_name': name,
            'usage': [usage],
            'fi.mau.bridged_pack': {
              'network': 'telegram',
              'url':
                  'https://t.me/add${usage == 'sticker' ? 'stickers' : 'emoji'}/$name',
            },
          },
      ];
    }
    final url = request.query['pack_url']!;
    final name = url.split('/').last;
    if (request.method == 'GET') {
      return {
        'images': {'${name}_a': packImage(name)},
        'pack': {'display_name': name},
      };
    }
    imported.add(url);
    return {
      'room_id': '!space:example.invalid',
      'state_keys': [name],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  // The emoji picker's tab bar is Flutter's Material TabBar.
  localizationsDelegates: const [
    DefaultMaterialLocalizations.delegate,
    fm.DefaultMaterialLocalizations.delegate,
    DefaultWidgetsLocalizations.delegate,
  ],
  home: Scaffold(body: child),
);

void main() {
  late FakeStickerBackend backend;
  late StickerLibrary library;
  late _SlowRoom room;
  late _Host host;

  // One preferences store for the file: AppSettings keeps the first one.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() {
    final client = ConversationClient();
    room = _SlowRoom(client, '!chat:example.invalid', network: 'telegram');
    host = _Host(room);
    backend = FakeStickerBackend();
    library = fakeLibrary(backend);
    StickerLibrary.debugSet(client, library);
    StickerPanel.debugResetTab(StickerPanelTab.stickers);
    StickerTab.debugResetPosition();
    GifTab.debugResetPosition();
  });
  tearDown(() {
    library.dispose();
    host.inputFocus.dispose();
    host.sendController.dispose();
  });

  void installPack({int count = 60}) {
    backend.rooms['!space:example.invalid'] = {
      'FictionalPack': pack('Fictional pack', {
        for (var i = 0; i < count; i++)
          'FictionalPack_$i': packImage('s$i', emoji: i == 0 ? '😂' : '😀'),
      }, url: 'https://t.me/addstickers/FictionalPack'),
    };
    library.addPack(
      const StickerPackRef(
        roomId: '!space:example.invalid',
        stateKey: 'FictionalPack',
      ),
    );
  }

  Widget panel() => SizedBox(
    height: 320,
    child: StickerPanel(host: host, searchFocus: FocusNode()),
  );

  testWidgets('the sticker grid keeps moving after a fling', (tester) async {
    installPack();
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    final grid = find.byType(CustomScrollView);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: grid, matching: find.byType(Scrollable)).first,
        )
        .position;
    await tester.fling(grid, const Offset(0, -120), 3000);
    await tester.pumpAndSettle();
    // A grid under TickerMode(false) stopped where the finger let go.
    expect(position.pixels, greaterThan(200));
  });

  testWidgets('a sent sticker is recent before the server answers', (
    tester,
  ) async {
    installPack(count: 5);
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Sticker 😂'));
    await tester.pumpAndSettle();
    expect(room.sends, 1);
    expect(library.recentStickers.single.emoji, '😂');
    expect(find.text('Recent'), findsOneWidget);
  });

  testWidgets('emoji pickers open on the recents once there are some', (
    tester,
  ) async {
    StickerPanel.debugResetTab(StickerPanelTab.emoji);
    EmojiRecents.debugReset();
    expect(EmojiRecents.any, isFalse);
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    // No empty "recents" section: the smileys are there at once.
    expect(find.text('Recently used'), findsNothing);
    expect(find.text('Smileys & people'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('😂').first);
    await tester.pumpAndSettle();
    expect(host.sendController.text, '😂');
    // Stored at once, in the preference earlier versions used.
    expect(AppSettings.store.getString('recent'), contains('😂'));
    expect(EmojiRecents.any, isTrue);

    // Reopened: the recents first, with the emoji just used.
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    expect(find.text('Recently used'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Recently used')).dy,
      lessThan(tester.getTopLeft(find.text('Smileys & people')).dy),
    );
    expect(find.bySemanticsLabel('😂'), findsWidgets);
  });

  test('a Telegram custom emoji set is usable as stickers', () {
    final emoji = ImagePackContent.fromJson({
      'images': {
        'FictionalEmoji_a': packImage('e1'),
        'FictionalEmoji_b': packImage('e2'),
      },
      'pack': {
        'display_name': 'Fictional emoji',
        'usage': ['emoticon'],
        'fi.mau.bridged_pack': {
          'network': 'telegram',
          'url': 'https://t.me/addemoji/FictionalEmoji',
        },
      },
    });
    final installed = StickerPack.fromContent(
      emoji,
      key: 'k',
      source: StickerPackSource.installed,
    );
    expect(installed.stickers, hasLength(2));
    // A chat's own emote pack stays out of the sticker panel.
    final roomEmotes = ImagePackContent.fromJson({
      'images': {'wave': packImage('e3')},
      'pack': {
        'usage': ['emoticon'],
      },
    });
    expect(
      StickerPack.fromContent(
        roomEmotes,
        key: 'r',
        source: StickerPackSource.room,
      ).stickers,
      isEmpty,
    );
  });

  testWidgets('Telegram packs: a settings page that adds every pack', (
    tester,
  ) async {
    final transport = _FakeTransport();
    final provisioning = StickerPackProvisioning(
      room.client,
      transport: transport,
      bridges: const [
        BridgeEndpoint(
          botId: '@telegrambot:example.invalid',
          network: 'telegram',
          label: 'Telegram',
        ),
      ],
    );
    await tester.pumpWidget(
      _app(
        TelegramPackImportPage(
          client: room.client,
          provisioning: provisioning,
          library: library,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stickers'), findsOneWidget);
    expect(find.text('Custom emoji'), findsOneWidget);
    expect(find.text('FictionalEmoji'), findsOneWidget);
    expect(find.text('Add all 3 packs'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('telegram-add-all')));
    await tester.pumpAndSettle();
    expect(transport.imported, [
      'https://t.me/addstickers/FictionalPack',
      'https://t.me/addstickers/OtherPack',
      'https://t.me/addemoji/FictionalEmoji',
    ]);
    expect(library.doc.packs, hasLength(3));
    expect(find.text('All packs added'), findsOneWidget);
    expect(find.text('3 packs added'), findsOneWidget);
  });
}

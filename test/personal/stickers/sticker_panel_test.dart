// SPDX-License-Identifier: AGPL-3.0-or-later
// The composer's Emoji · GIFs · Stickers panel (ST-03, ST-07, ST-10 D1) and
// its keyboard-height slot (ST-13/UX-04). Offline fixtures, no network.
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/stickers/composer_panel.dart';
import 'package:chatloom/personal/stickers/gif_tab.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_message_actions.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_panel.dart';
import 'package:chatloom/personal/stickers/sticker_tab.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

class _SendingRoom extends ConversationRoom {
  _SendingRoom(super.client, super.id, {super.network});
  final sent = <(String, Map<String, Object?>)>[];

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
  }) async {
    sent.add((type, Map<String, Object?>.of(content)));
    return r'$sent';
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
  int replyCancels = 0;

  @override
  String? get activeThreadId => null;
  @override
  String? get threadLastEventId => null;
  @override
  void cancelReplyEventAction() {
    replyCancels++;
    replyEvent = null;
  }

  @override
  void onEmojiSelected(Category? category, Emoji? emoji) {}
  @override
  void emojiPickerBackspace() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(body: child),
);

void main() {
  late FakeStickerBackend backend;
  late StickerLibrary library;
  late _SendingRoom room;
  late _Host host;

  setUp(() {
    final client = ConversationClient();
    room = _SendingRoom(client, '!chat:example.invalid', network: 'telegram');
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

  void installPack() {
    backend.rooms['!space:example.invalid'] = {
      'FictionalPack': pack('Fictional pack', {
        'FictionalPack_grin': packImage('a'),
        'FictionalPack_joy': packImage('b', emoji: '😂'),
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

  testWidgets('no packs: an empty state that offers to add packs', (
    tester,
  ) async {
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    expect(find.text('No sticker packs yet'), findsOneWidget);
    expect(find.text('Add sticker packs'), findsOneWidget);
    expect(find.text('Emoji'), findsOneWidget);
    expect(find.text('GIFs'), findsOneWidget);
    expect(find.text('Stickers'), findsOneWidget);
  });

  testWidgets('tap sends the sticker natively and keeps the panel', (
    tester,
  ) async {
    installPack();
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    expect(find.text('Fictional pack'), findsWidgets);
    final tiles = find.bySemanticsLabel('Sticker 😂');
    expect(tiles, findsOneWidget);
    await tester.tap(tiles);
    await tester.pumpAndSettle();
    expect(room.sent, hasLength(1));
    final (type, content) = room.sent.single;
    expect(type, EventTypes.Sticker);
    expect(
      (content['info'] as Map)['fi.mau.bridged_sticker'],
      isA<Map>(),
    );
    await library.flush();
    await tester.pumpAndSettle();
    // The sticker is the newest recent, and the panel stays open.
    expect(library.recentStickers.single.emoji, '😂');
    expect(find.text('Recent'), findsOneWidget);
  });

  testWidgets('a reply goes with the sticker as a plain relation', (
    tester,
  ) async {
    installPack();
    host.replyEvent = room.message(r'$reply', 'Fictional message');
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Sticker 😀'));
    await tester.pumpAndSettle();
    final content = room.sent.single.$2;
    expect(content['m.relates_to'], {
      'm.in_reply_to': {'event_id': r'$reply'},
    });
    expect(host.replyCancels, 1);
  });

  testWidgets('long-press previews and adds to favourites', (tester) async {
    installPack();
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    await tester.longPress(find.bySemanticsLabel('Sticker 😀'));
    await tester.pumpAndSettle();
    expect(find.text('Send'), findsOneWidget);
    await tester.tap(find.text('Add to favourites'));
    await tester.pumpAndSettle();
    expect(library.favourites.single.emoji, '😀');
    expect(find.text('Favourites'), findsOneWidget);
    expect(room.sent, isEmpty);
  });

  testWidgets('a sticker the room cannot take explains why and sends nothing', (
    tester,
  ) async {
    room.state(bridgeFeaturesEventType, {
      'file': {
        'm.image': {
          'mime_types': {'image/jpeg': 2},
        },
        'm.sticker': {
          'mime_types': {'image/webp': 2},
        },
      },
    }, key: 'fixture');
    backend.rooms['!space:example.invalid'] = {
      'P': pack('Lottie pack', {
        'p_one': packImage('l', mime: 'application/x-tgsticker'),
      }),
    };
    library.addPack(
      const StickerPackRef(roomId: '!space:example.invalid', stateKey: 'P'),
    );
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Sticker 😀'));
    await tester.pump();
    expect(find.text('This sticker can’t be sent to Telegram.'), findsOneWidget);
    expect(room.sent, isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('GIFs tab: empty state, then saved GIFs; the tab is remembered', (
    tester,
  ) async {
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-tab-gifs')));
    await tester.pumpAndSettle();
    expect(StickerPanel.lastTab, StickerPanelTab.gifs);
    expect(find.text('No saved GIFs yet'), findsOneWidget);
    library.saveGif(imageGif('g'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('GIF'));
    await tester.pumpAndSettle();
    expect(room.sent.single.$2['msgtype'], MessageTypes.Image);
    await library.flush();
    expect(library.recentGifs, hasLength(1));
  });

  testWidgets('search finds stickers by emoji word', (tester) async {
    installPack();
    await tester.pumpWidget(_app(panel()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search stickers'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'joy');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sticker 😂'), findsOneWidget);
    expect(find.bySemanticsLabel('Sticker 😀'), findsNothing);
  });

  group('message menu', () {
    Event event(String type, Map<String, Object?> content) => Event(
      type: type,
      content: content,
      room: room,
      eventId: r'$m',
      senderId: '@anna:example.invalid',
      originServerTs: DateTime.utc(2026),
    );

    testWidgets('a pack sticker: favourite with Undo and View sticker pack', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final actions = stickerMessageActions(
        context,
        event(EventTypes.Sticker, packImage('a')),
      );
      expect(actions.map((a) => a.label), [
        'Add to favourites',
        'View sticker pack',
      ]);
      actions.first.onSelected();
      await tester.pumpAndSettle();
      expect(library.favourites, hasLength(1));
      expect(find.text('Added to favourite stickers'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(library.favourites, isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('a GIF can be saved; other messages get nothing', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final gif = event(EventTypes.Message, {
        'msgtype': MessageTypes.Video,
        'body': 'gif.mp4',
        'url': 'mxc://example.invalid/g',
        'info': {'mimetype': 'video/mp4', 'fi.mau.gif': true},
      });
      final actions = stickerMessageActions(context, gif);
      expect(actions.single.label, 'Save GIF');
      actions.single.onSelected();
      expect(library.savedGifs, hasLength(1));
      expect(
        stickerMessageActions(
          context,
          event(EventTypes.Message, {'msgtype': 'm.text', 'body': 'hi'}),
        ),
        isEmpty,
      );
      await tester.pumpAndSettle();
    });
  });

  group('keyboard-height slot', () {
    late FocusNode input;
    late bool visible;
    late StateSetter rebuild;
    const composer = ValueKey('composer');
    const content = ValueKey('panel-content');

    setUp(() {
      ComposerKeyboardMetrics.reset();
      input = FocusNode();
      visible = false;
    });
    tearDown(() => input.dispose());

    Future<void> mount(WidgetTester tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(400, 800)
        ..viewPadding = const FakeViewPadding(bottom: 20)
        ..padding = const FakeViewPadding(bottom: 20);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: SafeArea(
              top: false,
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return Column(
                    children: [
                      const Expanded(child: SizedBox.expand()),
                      SizedBox(
                        key: composer,
                        height: 56,
                        child: TextField(focusNode: input),
                      ),
                      ComposerPanelSlot(
                        visible: visible,
                        inputFocus: input,
                        softKeyboard: true,
                        builder: (context, height) =>
                            const SizedBox.expand(key: content),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    Future<void> keyboard(WidgetTester tester, double inset) async {
      tester.view
        ..viewInsets = FakeViewPadding(bottom: inset)
        // The engine reports padding minus the keyboard.
        ..padding = FakeViewPadding(bottom: inset >= 20 ? 0 : 20 - inset);
      await tester.pump();
      await tester.pump();
    }

    double composerBottom(WidgetTester tester) =>
        tester.getBottomLeft(find.byKey(composer)).dy;

    testWidgets('keyboard → panel → keyboard keeps the composer still', (
      tester,
    ) async {
      await mount(tester);
      input.requestFocus();
      await keyboard(tester, 300);
      // The keyboard rests: its height is remembered.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(composerBottom(tester), 500);
      expect(
        ComposerKeyboardMetrics.heightFor(Orientation.portrait),
        300,
      );

      // Keyboard → panel: shown at once, uncovered as the keyboard leaves.
      input.unfocus();
      rebuild(() => visible = true);
      await tester.pump();
      for (final inset in [300.0, 220.0, 120.0, 40.0, 0.0]) {
        await keyboard(tester, inset);
        expect(composerBottom(tester), 500, reason: 'inset $inset');
      }
      expect(tester.getSize(find.byKey(content)).height, 280);

      // Panel → keyboard: the panel stays until the keyboard covers it.
      input.requestFocus();
      rebuild(() => visible = false);
      await tester.pump();
      for (final inset in [0.0, 90.0, 210.0, 300.0]) {
        await keyboard(tester, inset);
        expect(composerBottom(tester), 500, reason: 'inset $inset');
      }
      await tester.pumpAndSettle();
      expect(find.byKey(content), findsNothing);
    });

    testWidgets('without a keyboard it opens and closes with its own motion', (
      tester,
    ) async {
      await mount(tester);
      rebuild(() => visible = true);
      await tester.pumpAndSettle();
      // No keyboard seen yet: 40 % of the screen.
      expect(tester.getSize(find.byKey(content)).height, 320);
      rebuild(() => visible = false);
      await tester.pumpAndSettle();
      expect(find.byKey(content), findsNothing);
    });

    testWidgets('a keyboard that never comes does not leave the panel', (
      tester,
    ) async {
      await mount(tester);
      rebuild(() => visible = true);
      await tester.pumpAndSettle();
      input.requestFocus();
      rebuild(() => visible = false);
      await tester.pumpAndSettle();
      expect(find.byKey(content), findsNothing);
    });
  });
}

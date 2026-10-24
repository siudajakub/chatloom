// SPDX-License-Identifier: AGPL-3.0-or-later
// Emoji → sticker suggestions above the composer (MD-16). Offline fixtures.
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_search.dart';
import 'package:chatloom/personal/stickers/sticker_suggestions.dart';
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
  Event? replyEvent;
  @override
  Event? editEvent;
  @override
  bool composerEnabled = true;
  final changes = <String>[];

  @override
  String? get activeThreadId => null;
  @override
  String? get threadLastEventId => null;
  @override
  void cancelReplyEventAction() => replyEvent = null;
  @override
  void onInputBarChanged(String text) => changes.add(text);
  @override
  void onEmojiSelected(Category? category, Emoji? emoji) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('stickerSuggestionsFor', () {
    final grin = sticker('grin');
    final grin2 = sticker('grin2');
    final heart = sticker('heart', emoji: '❤');
    final family = sticker('family', emoji: '👨‍👩‍👧');
    final index = StickerSearchIndex([grin, grin2, heart, family]);
    List<StickerItem> search(String q) => index.search(q);

    test('one emoji suggests its stickers in library order', () {
      expect(stickerSuggestionsFor('😀', search), [grin, grin2]);
      expect(stickerSuggestionsFor(' 😀 ', search), [grin, grin2]);
      // Variation selector and a ZWJ sequence are one emoji.
      expect(stickerSuggestionsFor('❤️', search), [heart]);
      expect(stickerSuggestionsFor('👨‍👩‍👧', search), [family]);
    });

    test('anything else suggests nothing', () {
      expect(stickerSuggestionsFor('', search), isEmpty);
      expect(stickerSuggestionsFor('😀😀', search), isEmpty);
      expect(stickerSuggestionsFor('hi 😀', search), isEmpty);
      expect(stickerSuggestionsFor('grin', search), isEmpty);
      expect(stickerSuggestionsFor('1', search), isEmpty);
      expect(stickerSuggestionsFor('🙈', search), isEmpty);
    });

    test('limit, GIFs and the room filter', () {
      expect(stickerSuggestionsFor('😀', search, limit: 1), [grin]);
      expect(stickerSuggestionsFor('😀', search, allowed: (i) => i != grin), [
        grin2,
      ]);
      final gif = imageGif('gif');
      expect(stickerSuggestionsFor('😀', (_) => [gif, grin]), [grin]);
    });
  });

  group('StickerSuggestionStrip', () {
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
    });
    tearDown(() {
      library.dispose();
      host.inputFocus.dispose();
      host.sendController.dispose();
    });

    Widget app() => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: StickerSuggestionStrip(host: host),
        ),
      ),
    );

    testWidgets('appears for a matching emoji, hides for other text', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      expect(find.bySemanticsLabel('Sticker 😂'), findsNothing);
      host.sendController.text = '😂';
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Sticker 😂'), findsOneWidget);
      expect(find.bySemanticsLabel('Sticker 😀'), findsNothing);

      host.sendController.text = '😂 ok';
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Sticker 😂'), findsNothing);

      // Editing a message never suggests.
      host.editEvent = room.message(r'$edit', 'Fictional message');
      host.sendController.text = '😂';
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Sticker 😂'), findsNothing);
    });

    testWidgets('a tap sends the sticker and clears the emoji', (tester) async {
      await tester.pumpWidget(app());
      host.sendController.text = '😀';
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Sticker 😀'));
      await tester.pumpAndSettle();
      expect(room.sent, hasLength(1));
      expect(room.sent.single.$1, EventTypes.Sticker);
      expect(host.sendController.text, isEmpty);
      expect(host.changes, ['']);
      expect(find.bySemanticsLabel('Sticker 😀'), findsNothing);
    });
  });
}

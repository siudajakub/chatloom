// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/composer_recipient_notice.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/pages/chat/voice_draft_preview.dart';
import 'package:chatloom/personal/send_later.dart';
import 'package:chatloom/personal/ui/due_time_picker.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'conversation_test_support.dart';

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(body: child),
);

class _FakePlayer implements VoiceDraftPlayer {
  final opened = <String>[];
  final seeks = <Duration>[];
  final _position = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  bool disposed = false;

  @override
  Future<Duration?> open(String path) async {
    opened.add(path);
    return const Duration(seconds: 10);
  }

  @override
  Future<void> play() async => _playing.add(true);
  @override
  Future<void> pause() async => _playing.add(false);
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  void at(Duration value) => _position.add(value);
  @override
  Future<void> dispose() async {
    disposed = true;
    await _position.close();
    await _playing.close();
  }
}

void main() {
  final now = DateTime(2026, 10, 21, 10, 15);

  testWidgets('Send later defaults to tomorrow morning and validates inline', (
    tester,
  ) async {
    late BuildContext page;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            page = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final result = showSendLaterSheet(
      page,
      chatName: 'Fictional chat',
      text: 'See you then',
      clock: () => now,
    );
    await tester.pumpAndSettle();
    expect(find.text('See you then'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Choose a time in the future.'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('send-later-preset-In 1 hour')));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    await tester.tap(find.text('Schedule message'));
    await tester.pumpAndSettle();
    final choice = await result;
    expect(choice!.at, DateTime(2026, 10, 21, 11, 15));
    expect(choice.attachment, isFalse);
  });

  testWidgets('Send later without text only offers an attachment', (
    tester,
  ) async {
    late BuildContext page;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            page = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final result = showSendLaterSheet(
      page,
      chatName: 'Fictional chat',
      text: '  ',
      clock: () => now,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Write a message first, or schedule an attachment.'),
      findsOneWidget,
    );
    final primary = tester.widget<NotionButton>(
      find.widgetWithText(NotionButton, 'Schedule message'),
    );
    expect(primary.onPressed, isNull);
    await tester.tap(find.text('Schedule an attachment'));
    await tester.pumpAndSettle();
    expect((await result)!.attachment, isTrue);
  });

  testWidgets('due time picker explains a past time inline', (tester) async {
    await tester.pumpWidget(
      _app(
        DueTimePicker(
          at: now.subtract(const Duration(minutes: 5)),
          preset: null,
          presets: const [],
          clock: () => now,
          onChanged: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose a time in the future.'), findsOneWidget);
    expect(DueTimePicker.valid(now.add(const Duration(hours: 1)), now), isTrue);
  });

  testWidgets(
    'recipient notice waits for members and keys, keeps the composer',
    (tester) async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!keys:example.invalid')
        ..state(EventTypes.Encryption, {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
        });
      final loaded = Completer<void>();
      await tester.pumpWidget(
        _app(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ComposerRecipientNotice(
                room: room,
                confirm: (_) => loaded.future,
              ),
              const TextField(),
            ],
          ),
        ),
      );
      await tester.pump();
      // Not yet: the device list may still be loading.
      expect(
        find.text(ComposerRecipientNotice.text).hitTestable(),
        findsNothing,
      );
      loaded.complete();
      await tester.pumpAndSettle();
      expect(find.text(ComposerRecipientNotice.text), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    },
  );

  testWidgets('recipient notice stays hidden for an unencrypted chat', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!plain:example.invalid');
    var confirms = 0;
    await tester.pumpWidget(
      _app(
        ComposerRecipientNotice(room: room, confirm: (_) async => confirms++),
      ),
    );
    await tester.pumpAndSettle();
    expect(confirms, 0);
    expect(find.text(ComposerRecipientNotice.text).hitTestable(), findsNothing);
  });

  testWidgets('send button long press and secondary click open the menu', (
    tester,
  ) async {
    var sends = 0, menus = 0;
    await tester.pumpWidget(
      _app(
        Center(
          child: NotionSendButton(
            onPressed: () => sends++,
            onLongPress: () => menus++,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.longPress(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    expect((sends, menus), (1, 1));
    // The tooltip stays (hover), but never on the long press.
    expect(find.byTooltip('Send message'), findsOneWidget);
    await tester.pumpWidget(
      _app(
        Center(
          child: NotionSendButton(
            busy: true,
            onPressed: () => sends++,
            onLongPress: () => menus++,
          ),
        ),
      ),
    );
    await tester.longPress(find.byKey(const Key('send_button')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(menus, 1, reason: 'a busy send offers no menu');
  });

  testWidgets('inline actions sit beside plus and respect enabled', (
    tester,
  ) async {
    var emoji = 0;
    Widget composer(bool enabled) => _app(
      CompactComposer(
        input: const TextField(),
        source: const SizedBox.shrink(),
        addAction: IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
        inlineActions: [
          ComposerAction(
            icon: Icons.add_reaction_outlined,
            label: 'Emoji picker',
            onPressed: () => emoji++,
          ),
        ],
        actionsEnabled: enabled,
        primaryAction: const SizedBox.shrink(),
      ),
    );
    await tester.pumpWidget(composer(true));
    final plus = tester.getCenter(find.byIcon(Icons.add)).dx;
    final smiley = tester.getCenter(find.byTooltip('Emoji picker')).dx;
    expect(smiley, greaterThan(plus));
    expect(smiley - plus, closeTo(NotionSize.touchTarget, 1));
    await tester.tap(find.byTooltip('Emoji picker'));
    expect(emoji, 1);
    await tester.pumpWidget(composer(false));
    await tester.tap(find.byTooltip('Emoji picker'), warnIfMissed: false);
    expect(emoji, 1);
  });

  testWidgets('voice draft preview finishes once, plays and scrubs', (
    tester,
  ) async {
    final player = _FakePlayer();
    var prepares = 0;
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 320,
          child: VoiceDraftPreview(
            prepare: () async {
              prepares++;
              return '/tmp/fictional-voice.ogg';
            },
            duration: const Duration(seconds: 9),
            waveform: const [.2, .8, .5],
            createPlayer: () => player,
          ),
        ),
      ),
    );
    expect(find.text('0:09'), findsOneWidget);
    expect(prepares, 0, reason: 'pausing alone keeps the recording open');
    await tester.tap(find.byTooltip('Listen to recording'));
    await tester.pumpAndSettle();
    expect(prepares, 1);
    expect(player.opened, ['/tmp/fictional-voice.ogg']);
    expect(find.byTooltip('Pause recording'), findsOneWidget);
    player.at(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump();
    expect(find.text('0:05'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause recording'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Listen to recording'), findsOneWidget);
    final slider = find.byKey(const Key('voice_preview_seek'));
    await tester.tapAt(tester.getTopLeft(slider) + const Offset(12, 14));
    await tester.pumpAndSettle();
    expect(player.seeks, isNotEmpty);
    expect(prepares, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(player.disposed, isTrue);
  });
}

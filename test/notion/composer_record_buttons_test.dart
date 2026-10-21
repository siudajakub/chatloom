// SPDX-License-Identifier: AGPL-3.0-or-later
// Voice and round video record buttons sit side by side in the empty
// composer (wave 3, 21.10): no voice ↔ round mode, no notice covering the
// chat. Fictional offline fixtures only.
import 'package:chatloom/pages/chat/chat_input_row.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/personal/round_video/round_availability.dart';
import 'package:chatloom/personal/round_video/round_record_button.dart';
import 'package:chatloom/personal/round_video/telegram_room_binding.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late VoiceRecordHold hold;
  late TextEditingController editor;
  late ValueNotifier<bool> round;

  setUp(() {
    hold = VoiceRecordHold();
    editor = TextEditingController();
    round = ValueNotifier(true);
  });
  tearDown(() {
    hold.dispose();
    editor.dispose();
    round.dispose();
  });

  Widget shell({
    bool selectableSource = false,
    double scale = 1,
    bool reduceMotion = false,
  }) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ValueListenableBuilder<bool>(
              valueListenable: round,
              builder: (context, showRound, _) => CompactComposer(
                input: TextField(
                  controller: editor,
                  decoration: const InputDecoration(
                    hintText: 'Message…',
                    hintMaxLines: 1,
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
                source: ConversationSourceChip(
                  network: 'telegram',
                  onPressed: selectableSource ? () {} : null,
                ),
                actions: [
                  ComposerAction(
                    icon: Icons.attach_file_outlined,
                    label: 'Attach media or a file',
                    onPressed: () {},
                  ),
                  ComposerAction(
                    icon: Icons.add_reaction_outlined,
                    label: 'Emoji picker',
                    onPressed: () {},
                  ),
                ],
                secondaryAction: showRound
                    ? RoundRecordButton(onRecord: (_) async {})
                    : null,
                primaryAction: VoiceRecordButton(
                  hold: hold,
                  // Starts at once, so a quick tap is a too-short hold.
                  onStart: () async => true,
                  onSend: () async {},
                  onCancel: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Finder roundButton() => find.byType(RoundRecordButton);
  Finder mic() => find.byType(VoiceRecordButton);

  for (final width in [360.0, 411.0]) {
    for (final selectable in [false, true]) {
      testWidgets(
        '${width.toInt()}dp: round and mic side by side, source stays inline '
        '(${selectable ? 'merged' : 'ordinary'} chip)',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 700));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(shell(selectableSource: selectable));
          await tester.pumpAndSettle();
          final roundRect = tester.getRect(roundButton());
          final micRect = tester.getRect(mic());
          expect(roundRect.size, const Size.square(NotionSize.touchTarget));
          expect(micRect.size, const Size.square(NotionSize.touchTarget));
          // Next to each other, the mic at the end edge (Telegram's place).
          expect(roundRect.right, micRect.left);
          expect(roundRect.center.dy, micRect.center.dy);
          // Single-line row: the source chip stays inside the field.
          expect(tester.getSize(find.byType(CompactComposer)).height, 62);
          expect(
            tester.getSize(find.byType(TextField)).width,
            greaterThan(100),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('320dp at 200 percent text does not overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shell(selectableSource: true, scale: 2));
    await tester.pumpAndSettle();
    expect(roundButton(), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The open action tray still fits beside both buttons.
    await tester.tap(find.byTooltip('More message actions'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the round slot shrinks smoothly when text appears; editor survives',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(shell());
      await tester.pumpAndSettle();
      final editable = tester.state(find.byType(EditableText));
      final open = tester.getSize(find.byType(TextField)).width;
      final composerHeight = tester.getSize(find.byType(CompactComposer)).height;

      // The host drops the round button with the first letter.
      editor.text = 'H';
      round.value = false;
      await tester.pump();
      await tester.pump(NotionMotion.short ~/ 2);
      final mid = tester.getSize(find.byType(TextField)).width;
      expect(mid, greaterThan(open));
      expect(mid, lessThan(open + NotionSize.touchTarget));
      // Closing: still painted, but it takes no taps.
      expect(roundButton(), findsOneWidget);
      expect(
        tester.getSize(find.byType(CompactComposer)).height,
        composerHeight,
      );
      await tester.pumpAndSettle();
      expect(roundButton(), findsNothing);
      expect(
        tester.getSize(find.byType(TextField)).width,
        open + NotionSize.touchTarget,
      );
      expect(tester.state(find.byType(EditableText)), same(editable));

      // Cleared again: it grows back beside the mic.
      editor.clear();
      round.value = true;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(TextField)).width, open);
      expect(tester.getRect(roundButton()).right, tester.getRect(mic()).left);
      expect(tester.state(find.byType(EditableText)), same(editable));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a closing round button ignores taps', (tester) async {
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    final center = tester.getCenter(roundButton());
    round.value = false;
    await tester.pump();
    await tester.pump(NotionMotion.quick ~/ 4);
    expect(roundButton().hitTestable(), findsNothing);
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.text(RoundRecordButton.defaultTapHint), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion hides and shows the round button at once', (
    tester,
  ) async {
    await tester.pumpWidget(shell(reduceMotion: true));
    await tester.pump();
    round.value = false;
    await tester.pump();
    expect(roundButton(), findsNothing);
    round.value = true;
    await tester.pump();
    expect(tester.getSize(roundButton()), const Size.square(48));
  });

  testWidgets('quick taps explain holding in tooltips, never a snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    var pointer = await tester.startGesture(tester.getCenter(roundButton()));
    await tester.pump(const Duration(milliseconds: 60));
    await pointer.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(RoundRecordButton.defaultTapHint), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // The next touch hides it; a quick tap on the mic shows its own hint.
    pointer = await tester.startGesture(tester.getCenter(mic()));
    await tester.pump();
    await pointer.up(timeStamp: const Duration(milliseconds: 80));
    await tester.pumpAndSettle();
    expect(find.text(RoundRecordButton.defaultTapHint), findsNothing);
    expect(find.text(VoiceRecordButton.defaultTapHint), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  group('composerRecordButtons', () {
    const available = RoundAvailability.available;
    final trust = RoundAvailability.fromReport(
      const RoundGateReport(RoundGateCode.needsTrust),
    );
    final refused = RoundAvailability.fromReport(
      const RoundGateReport(RoundGateCode.bridgeLacksRoundSupport),
    );
    ({bool voice, bool round}) buttons({
      bool platform = true,
      bool editing = false,
      bool enabled = true,
      bool text = false,
      bool holding = false,
      RoundAvailability? round = available,
    }) => composerRecordButtons(
      platformCanRecord: platform,
      editing: editing,
      enabled: enabled,
      hasText: text,
      holdingVoice: holding,
      round: round,
    );

    test('empty Telegram composer with round video shows both', () {
      expect(buttons(), (voice: true, round: true));
      // Trust is asked on the first recording, so the button is offered.
      expect(buttons(round: trust), (voice: true, round: true));
    });

    test('without round video only the mic shows', () {
      expect(buttons(round: null), (voice: true, round: false));
      expect(buttons(round: refused), (voice: true, round: false));
    });

    test('text, editing, a disabled composer or no recorder hide both', () {
      for (final state in [
        buttons(text: true),
        buttons(editing: true),
        buttons(enabled: false),
        buttons(platform: false),
      ]) {
        expect(state, (voice: false, round: false));
      }
    });

    test('a held voice message hides the round button only', () {
      expect(buttons(holding: true), (voice: true, round: false));
    });
  });
}

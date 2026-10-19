import 'dart:async';
import 'dart:ui' as ui;

import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/pages/chat/voice_record_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Recorder {
  int starts = 0, sends = 0, cancels = 0;
  Duration recorded = Duration.zero;
  Completer<bool>? pendingStart;
  Future<bool> start() {
    starts++;
    return pendingStart?.future ?? Future.value(true);
  }

  Future<void> send() async => sends++;
  void cancel() => cancels++;
}

void main() {
  late VoiceRecordHold hold;
  late _Recorder recorder;

  setUp(() {
    hold = VoiceRecordHold();
    recorder = _Recorder();
  });
  tearDown(() => hold.dispose());

  Widget shell({
    TextDirection direction = TextDirection.ltr,
    bool reduceMotion = false,
    VoidCallback? onToggleMode,
    VoidCallback? onTapHint,
  }) => MaterialApp(
    theme: ThemeData.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 300,
                height: 50,
                child: ListenableBuilder(
                  listenable: hold,
                  builder: (context, _) => hold.capturing
                      ? VoiceRecordHoldOverlay(
                          hold: hold,
                          duration: const Duration(seconds: 3),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              VoiceRecordButton(
                hold: hold,
                onStart: recorder.start,
                onSend: recorder.send,
                onCancel: recorder.cancel,
                recorded: () => recorder.recorded,
                onToggleMode: onToggleMode,
                onTapHint: onTapHint,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Finder button() => find.byType(VoiceRecordButton);

  testWidgets('hold records and release after 800 ms sends once', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    expect(recorder.starts, 1);
    expect(hold.phase, VoiceRecordPhase.holding);
    expect(find.text('Slide to cancel'), findsOneWidget);
    expect(find.text('0:03'), findsOneWidget);
    recorder.recorded = const Duration(milliseconds: 900);
    await gesture.up(timeStamp: const Duration(seconds: 1));
    await tester.pump();
    expect(recorder.sends, 1);
    expect(recorder.cancels, 0);
    expect(hold.phase, VoiceRecordPhase.idle);
    expect(find.text('Slide to cancel'), findsNothing);
  });

  testWidgets('release before 800 ms discards without sending', (tester) async {
    await tester.pumpWidget(shell());
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    recorder.recorded = const Duration(milliseconds: 500);
    await gesture.up(timeStamp: const Duration(milliseconds: 600));
    await tester.pump();
    expect(recorder.sends, 0);
    expect(recorder.cancels, 1);
    expect(hold.phase, VoiceRecordPhase.idle);
  });

  testWidgets('slide toward the start cancels; RTL mirrors the direction', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    var gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    // 800 px wide: min(35 % of the width, 140 dp) = 140 dp to cancel.
    expect(hold.cancelDistance, 140);
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    expect(hold.cancelProgress, closeTo(0.5, 0.01));
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    expect(recorder.cancels, 1);
    expect(hold.phase, VoiceRecordPhase.idle);
    recorder.recorded = const Duration(seconds: 2);
    await gesture.up(timeStamp: const Duration(seconds: 2));
    await tester.pump();
    expect(recorder.sends, 0);

    await tester.pumpWidget(shell(direction: TextDirection.rtl));
    gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    // Away from the start edge in RTL: still recording.
    expect(hold.phase, VoiceRecordPhase.holding);
    await gesture.moveBy(const Offset(240, 0));
    await tester.pump();
    expect(recorder.cancels, 2);
    await gesture.up(timeStamp: const Duration(seconds: 2));
  });

  testWidgets('slide up locks into hands-free recording', (tester) async {
    await tester.pumpWidget(shell());
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.locked);
    recorder.recorded = const Duration(seconds: 2);
    await gesture.up(timeStamp: const Duration(seconds: 2));
    await tester.pump();
    // The caller's full recording controls own sending from here.
    expect(recorder.sends, 0);
    expect(recorder.cancels, 0);
  });

  testWidgets('releasing past 55 % of the cancel distance discards', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.holding);
    recorder.recorded = const Duration(seconds: 3);
    await gesture.up(timeStamp: const Duration(seconds: 3));
    await tester.pump();
    expect(recorder.sends, 0);
    expect(recorder.cancels, 1);
    expect(hold.phase, VoiceRecordPhase.idle);
  });

  testWidgets('lock needs 57 dp up and is ignored once slid 30 % away', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    var gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.holding);
    await gesture.moveBy(const Offset(0, -8));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.locked);
    await gesture.up(timeStamp: const Duration(seconds: 2));
    hold.reset();

    gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    await gesture.moveBy(const Offset(-50, -70));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.holding);
    await gesture.up(timeStamp: const Duration(seconds: 4));
  });

  testWidgets('a quick tap records nothing and shows the hold hint', (
    tester,
  ) async {
    var hints = 0;
    await tester.pumpWidget(shell(onTapHint: () => hints++));
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    await gesture.up(timeStamp: const Duration(milliseconds: 100));
    await tester.pump();
    expect(recorder.starts, 1);
    expect(recorder.sends, 0);
    expect(recorder.cancels, 1);
    expect(hold.phase, VoiceRecordPhase.idle);
    expect(hints, 1);
  });

  testWidgets(
    'with video available a tap switches mode and only a 150 ms hold records',
    (tester) async {
      var toggles = 0;
      await tester.pumpWidget(shell(onToggleMode: () => toggles++));
      var gesture = await tester.startGesture(tester.getCenter(button()));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up(timeStamp: const Duration(milliseconds: 100));
      await tester.pump();
      expect(toggles, 1);
      expect(recorder.starts, 0);
      expect(hold.phase, VoiceRecordPhase.idle);

      gesture = await tester.startGesture(tester.getCenter(button()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.starts, 0);
      await tester.pump(const Duration(milliseconds: 60));
      expect(recorder.starts, 1);
      expect(hold.phase, VoiceRecordPhase.holding);
      recorder.recorded = const Duration(seconds: 1);
      await gesture.up(timeStamp: const Duration(seconds: 2));
      await tester.pump();
      expect(toggles, 1);
      expect(recorder.sends, 1);
    },
  );

  testWidgets('release while the recorder is still starting discards it', (
    tester,
  ) async {
    recorder.pendingStart = Completer<bool>();
    await tester.pumpWidget(shell());
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.starting);
    await gesture.up(timeStamp: const Duration(seconds: 1));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.canceled);
    recorder.pendingStart!.complete(true);
    await tester.pump();
    expect(recorder.cancels, 1);
    expect(recorder.sends, 0);
    expect(hold.phase, VoiceRecordPhase.idle);
  });

  testWidgets('failed start returns to idle without callbacks', (tester) async {
    recorder.pendingStart = Completer<bool>()..complete(false);
    await tester.pumpWidget(shell());
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.idle);
    await gesture.up(timeStamp: const Duration(seconds: 1));
    await tester.pump();
    expect(recorder.sends + recorder.cancels, 0);
  });

  testWidgets('semantics tap starts hands-free and keeps a 48dp target', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(shell());
    expect(tester.getSize(button()), const Size(48, 48));
    final node = tester.getSemantics(button());
    expect(node.label, contains('Hold to record'));
    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, ui.SemanticsAction.tap);
    await tester.pump();
    expect(recorder.starts, 1);
    expect(hold.phase, VoiceRecordPhase.locked);
    semantics.dispose();
  });

  testWidgets('screen readers get a switch action when video is available', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var toggles = 0;
    await tester.pumpWidget(shell(onToggleMode: () => toggles++));
    final node = tester.getSemantics(button());
    expect(node.label, contains('Tap to switch to video messages'));
    final data = node.getSemanticsData();
    expect(data.customSemanticsActionIds, hasLength(1));
    node.owner!.performAction(
      node.id,
      ui.SemanticsAction.customAction,
      data.customSemanticsActionIds!.single,
    );
    await tester.pump();
    expect(toggles, 1);
    expect(recorder.starts, 0);
    semantics.dispose();
  });

  testWidgets('removing the button mid-hold discards after the frame', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    expect(hold.phase, VoiceRecordPhase.holding);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(recorder.cancels, 1);
    expect(recorder.sends, 0);
    expect(hold.phase, VoiceRecordPhase.idle);
    await gesture.up(timeStamp: const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  Finder pill() => find.byKey(const Key('voice_lock_pill'));

  testWidgets('held mic shows a lock pill above it that follows the finger', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(shell());
    final label = tester.getSemantics(button()).label;
    expect(pill(), findsNothing);
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    await tester.pump(VoiceRecordLayout.enter);
    expect(pill(), findsOneWidget);
    expect(tester.getSize(pill()), const Size(36, 72));
    final mic = tester.getRect(button());
    var rect = tester.getRect(pill());
    // Centred above the enlarged mic, clear of its 1.6x fill.
    expect(rect.center.dx, closeTo(mic.center.dx, 0.5));
    expect(
      rect.bottom,
      lessThanOrEqualTo(
        mic.center.dy - mic.height * VoiceRecordLayout.heldScale / 2,
      ),
    );
    expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
    // The enlarged fill lives in the overlay, so the composer cannot clip it.
    final scales = tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.byIcon(Icons.mic_none_outlined),
            matching: find.byType(Transform),
          ),
        )
        .map((t) => t.transform.getMaxScaleOnAxis());
    expect(
      scales.any((s) => (s - VoiceRecordLayout.heldScale).abs() < 0.01),
      isTrue,
    );
    final top = rect.top;
    // 70 % of the 57 dp lock distance: the lock closes, nothing locks yet.
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    rect = tester.getRect(pill());
    expect(rect.top, lessThan(top));
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    // The pill and the enlarged mic add nothing to semantics.
    expect(tester.getSemantics(button()).label, label);
    expect(
      find.ancestor(
        of: pill(),
        matching: find.byWidgetPredicate(
          (widget) => widget is ExcludeSemantics && widget.excluding,
        ),
      ),
      findsOneWidget,
    );
    recorder.recorded = const Duration(seconds: 2);
    await gesture.up(timeStamp: const Duration(seconds: 2));
    await tester.pump();
    expect(recorder.sends, 1);
    expect(pill(), findsNothing);
    semantics.dispose();
  });

  testWidgets('reduced motion shows the pill and full scale at once; RTL', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(direction: TextDirection.rtl, reduceMotion: true),
    );
    final gesture = await tester.startGesture(tester.getCenter(button()));
    await tester.pump();
    expect(pill(), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: pill(), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1);
    expect(
      tester.getCenter(pill()).dx,
      closeTo(tester.getCenter(button()).dx, 0.5),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 500));
    await tester.pump();
    expect(pill(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording clocks use m:ss with a live recording dot', (
    tester,
  ) async {
    // RecordingInputRow.formatDuration delegates to the same formatter.
    expect(notionAudioTime(Duration.zero), '0:00');
    expect(notionAudioTime(const Duration(seconds: 7)), '0:07');
    expect(notionAudioTime(const Duration(minutes: 12)), '12:00');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 50,
            child: VoiceRecordHoldOverlay(
              hold: hold,
              duration: const Duration(minutes: 1, seconds: 5),
            ),
          ),
        ),
      ),
    );
    expect(find.text('1:05'), findsOneWidget);
    expect(find.byType(RecordingDot), findsOneWidget);
    expect(tester.widget<RecordingDot>(find.byType(RecordingDot)).active, true);
  });
}

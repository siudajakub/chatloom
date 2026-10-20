// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:ui' as ui;

import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/round_record_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget app(
  Future<void> Function(RoundCaptureGestureController) onRecord, {
  VoidCallback? onToggleMode,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  home: Directionality(
    textDirection: direction,
    child: Scaffold(
      body: Center(
        child: RoundRecordButton(
          onRecord: onRecord,
          onToggleMode: onToggleMode,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'original hold releases while permission is pending without a second gesture',
    (tester) async {
      final permission = Completer<void>();
      RoundCaptureGestureController? signal;
      RoundCaptureGesturePhase? phaseAfterPermission;
      var calls = 0;
      await tester.pumpWidget(
        app((gesture) async {
          calls++;
          signal = gesture;
          await permission.future;
          phaseAfterPermission = gesture.phase;
        }),
      );
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(RoundRecordButton)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      expect(signal!.phase, RoundCaptureGesturePhase.holding);
      expect(calls, 1);
      await pointer.up();
      await tester.pump();
      expect(signal!.phase, RoundCaptureGesturePhase.released);
      permission.complete();
      await tester.pumpAndSettle();
      expect(phaseAfterPermission, RoundCaptureGesturePhase.released);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lock movement survives pending permission and the original release',
    (tester) async {
      final permission = Completer<void>();
      RoundCaptureGestureController? signal;
      RoundCaptureGesturePhase? phaseAfterPermission;
      await tester.pumpWidget(
        app((gesture) async {
          signal = gesture;
          await permission.future;
          phaseAfterPermission = gesture.phase;
        }),
      );
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(RoundRecordButton)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      await pointer.moveBy(const Offset(0, -81));
      await tester.pump();
      expect(signal!.phase, RoundCaptureGesturePhase.locked);
      await pointer.up();
      await tester.pump();
      expect(signal!.phase, RoundCaptureGesturePhase.locked);
      permission.complete();
      await tester.pumpAndSettle();
      expect(phaseAfterPermission, RoundCaptureGesturePhase.locked);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel movement cannot be undone when permission completes', (
    tester,
  ) async {
    final permission = Completer<void>();
    RoundCaptureGestureController? signal;
    RoundCaptureGesturePhase? phaseAfterPermission;
    await tester.pumpWidget(
      app((gesture) async {
        signal = gesture;
        await permission.future;
        phaseAfterPermission = gesture.phase;
      }),
    );
    final pointer = await tester.startGesture(
      tester.getCenter(find.byType(RoundRecordButton)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
    await pointer.moveBy(const Offset(-81, 0));
    await tester.pump();
    await pointer.up();
    expect(signal!.phase, RoundCaptureGesturePhase.canceled);
    permission.complete();
    await tester.pumpAndSettle();
    expect(phaseAfterPermission, RoundCaptureGesturePhase.canceled);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an in-flight callback keeps its frozen source when the composer rebuilds',
    (tester) async {
      final permission = Completer<void>();
      final callbacks = <String>[];
      RoundCaptureGestureController? signal;
      String? deliveredTo;
      await tester.pumpWidget(
        app((gesture) async {
          const frozenSource = 'synthetic-source-A';
          signal = gesture;
          callbacks.add(frozenSource);
          await permission.future;
          deliveredTo = frozenSource;
        }),
      );
      await tester.tap(find.byType(RoundRecordButton));
      await tester.pump();
      await tester.pumpWidget(
        app((gesture) async {
          callbacks.add('synthetic-source-B');
        }),
      );
      await tester.tap(find.byType(RoundRecordButton));
      await tester.pump();
      expect(callbacks, ['synthetic-source-A']);
      expect(signal!.phase, RoundCaptureGesturePhase.locked);
      permission.complete();
      await tester.pumpAndSettle();
      expect(deliveredTo, 'synthetic-source-A');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'accessible tap starts locked and disposing cancels pending capture',
    (tester) async {
      final permission = Completer<void>();
      RoundCaptureGestureController? signal;
      await tester.pumpWidget(
        app((gesture) async {
          signal = gesture;
          await permission.future;
        }),
      );
      await tester.tap(find.byType(RoundRecordButton));
      await tester.pump();
      expect(signal!.phase, RoundCaptureGesturePhase.locked);
      await tester.pumpWidget(const SizedBox());
      expect(signal!.phase, RoundCaptureGesturePhase.canceled);
      permission.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  group('Telegram gestures', () {
    late Completer<void> recording;
    late List<RoundCaptureGestureController> gestures;
    Future<void> onRecord(RoundCaptureGestureController gesture) {
      gestures.add(gesture);
      return recording.future;
    }

    // Created inside each test: a completer from setUp lives outside the
    // fake-async zone and would never complete under pump.
    void reset() {
      recording = Completer<void>();
      gestures = [];
    }

    Future<TestGesture> hold(WidgetTester tester) async {
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(RoundRecordButton)),
      );
      await tester.pump(RoundCaptureGestureController.holdDelay);
      await tester.pump();
      return pointer;
    }

    Future<void> finish(WidgetTester tester) async {
      recording.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    testWidgets('a tap under 150 ms switches to voice and records nothing', (
      tester,
    ) async {
      reset();
      var toggles = 0;
      await tester.pumpWidget(app(onRecord, onToggleMode: () => toggles++));
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(RoundRecordButton)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await pointer.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(toggles, 1);
      expect(gestures, isEmpty);
      await finish(tester);
    });

    testWidgets('holding 150 ms records with the button anchor and width', (
      tester,
    ) async {
      reset();
      await tester.pumpWidget(app(onRecord, onToggleMode: () {}));
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(RoundRecordButton)),
      );
      await tester.pump(const Duration(milliseconds: 140));
      expect(gestures, isEmpty);
      await tester.pump(const Duration(milliseconds: 20));
      expect(gestures, hasLength(1));
      final gesture = gestures.single;
      expect(gesture.phase, RoundCaptureGesturePhase.holding);
      expect(
        gesture.anchor!.center,
        tester.getCenter(find.byType(RoundRecordButton)),
      );
      // 800 px test surface: min(0.35 × 800, 140).
      expect(gesture.cancelDistance, 140);
      await pointer.up();
      await tester.pump();
      expect(gesture.phase, RoundCaptureGesturePhase.released);
      await finish(tester);
    });

    testWidgets('swipe up 57 dp locks, 50 dp does not', (tester) async {
      reset();
      await tester.pumpWidget(app(onRecord, onToggleMode: () {}));
      final pointer = await hold(tester);
      final gesture = gestures.single;
      await pointer.moveBy(const Offset(0, -50));
      await tester.pump();
      expect(gesture.phase, RoundCaptureGesturePhase.holding);
      expect(gesture.lockProgress, closeTo(50 / 57, 0.01));
      await pointer.moveBy(const Offset(0, -8));
      await tester.pump();
      expect(gesture.phase, RoundCaptureGesturePhase.locked);
      await pointer.up();
      await tester.pump();
      expect(gesture.phase, RoundCaptureGesturePhase.locked);
      await finish(tester);
    });

    testWidgets('slide the full distance cancels at once; RTL mirrors it', (
      tester,
    ) async {
      reset();
      await tester.pumpWidget(
        app(onRecord, onToggleMode: () {}, direction: TextDirection.rtl),
      );
      final pointer = await hold(tester);
      final gesture = gestures.single;
      await pointer.moveBy(const Offset(-150, 0));
      await tester.pump();
      // Toward the end edge in RTL: still recording, at rest.
      expect(gesture.phase, RoundCaptureGesturePhase.holding);
      expect(gesture.slideProgress, 1);
      await pointer.moveBy(const Offset(220, 0));
      await tester.pump();
      expect(gesture.slideProgress, closeTo(0.5, 0.01));
      await pointer.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(gesture.phase, RoundCaptureGesturePhase.canceled);
      await pointer.up();
      await finish(tester);
    });

    testWidgets('a system pointer cancel locks unless slid away', (
      tester,
    ) async {
      reset();
      await tester.pumpWidget(app(onRecord, onToggleMode: () {}));
      var pointer = await hold(tester);
      await pointer.cancel();
      await tester.pump();
      expect(gestures.single.phase, RoundCaptureGesturePhase.locked);
      await finish(tester);

      recording = Completer<void>();
      pointer = await hold(tester);
      await pointer.moveBy(const Offset(-60, 0));
      await tester.pump();
      await pointer.cancel();
      await tester.pump();
      expect(gestures.last.phase, RoundCaptureGesturePhase.canceled);
      await finish(tester);
    });

    testWidgets('screen readers record hands-free or switch mode', (
      tester,
    ) async {
      reset();
      final semantics = tester.ensureSemantics();
      var toggles = 0;
      await tester.pumpWidget(app(onRecord, onToggleMode: () => toggles++));
      final node = tester.getSemantics(find.byType(RoundRecordButton));
      expect(node.label, contains('Tap to switch to voice messages'));
      final data = node.getSemanticsData();
      node.owner!.performAction(
        node.id,
        ui.SemanticsAction.customAction,
        data.customSemanticsActionIds!.single,
      );
      await tester.pump();
      expect(toggles, 1);
      expect(gestures, isEmpty);
      node.owner!.performAction(node.id, ui.SemanticsAction.tap);
      await tester.pump();
      expect(gestures.single.phase, RoundCaptureGesturePhase.locked);
      expect(
        tester.getSize(find.byType(RoundRecordButton)).shortestSide,
        greaterThanOrEqualTo(48),
      );
      await finish(tester);
      semantics.dispose();
    });
  });
}

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
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  home: Directionality(
    textDirection: direction,
    child: Scaffold(
      body: Center(child: RoundRecordButton(onRecord: onRecord)),
    ),
  ),
);

/// A screen reader activation: hands-free recording. A pointer tap only
/// shows the hold hint.
Future<void> accessibleTap(WidgetTester tester) async {
  final semantics = tester.ensureSemantics();
  await tester.pump();
  final node = tester.getSemantics(find.byType(RoundRecordButton));
  node.owner!.performAction(node.id, ui.SemanticsAction.tap);
  semantics.dispose();
}

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
      await accessibleTap(tester);
      await tester.pump();
      await tester.pumpWidget(
        app((gesture) async {
          callbacks.add('synthetic-source-B');
        }),
      );
      await accessibleTap(tester);
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
      await accessibleTap(tester);
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

    testWidgets('a tap under 150 ms records nothing and shows a small hint', (
      tester,
    ) async {
      reset();
      await tester.pumpWidget(app(onRecord));
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(RoundRecordButton)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await pointer.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(gestures, isEmpty);
      // The tooltip above the button, never a snackbar over the chat.
      expect(find.text(RoundRecordButton.defaultTapHint), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text(RoundRecordButton.defaultTapHint), findsNothing);
      await finish(tester);
    });

    testWidgets('holding 150 ms records with the button anchor and width', (
      tester,
    ) async {
      reset();
      await tester.pumpWidget(app(onRecord));
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
      await tester.pumpWidget(app(onRecord));
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
        app(onRecord, direction: TextDirection.rtl),
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
      await tester.pumpWidget(app(onRecord));
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

    testWidgets('screen readers record hands-free; no mode switch action', (
      tester,
    ) async {
      reset();
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(onRecord));
      final node = tester.getSemantics(find.byType(RoundRecordButton));
      expect(node.label, isNot(contains('switch')));
      expect(node.getSemanticsData().customSemanticsActionIds ?? [], isEmpty);
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

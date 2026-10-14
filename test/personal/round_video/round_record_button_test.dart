// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/round_video/round_capture_controller.dart';
import 'package:fluffychat/personal/round_video/round_record_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget app(Future<void> Function(RoundCaptureGestureController) onRecord) =>
    MaterialApp(
      home: Scaffold(
        body: Center(child: RoundRecordButton(onRecord: onRecord)),
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
}

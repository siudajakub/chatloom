// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/avatar_viewer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
);

void main() {
  testWidgets('cached private photo survives an unavailable full photo', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: AvatarViewer(
          name: 'Fictional person',
          initialBytes: _pixel,
          loadPhoto: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Photo unavailable'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('photo preserves its full bounds and supports zooming', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: AvatarViewer(
          name: 'Fictional person',
          loadPhoto: () async => _pixel,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final left = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    await left.moveTo(center - const Offset(100, 0));
    await right.moveTo(center + const Offset(100, 0));
    await tester.pump();
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await left.up();
    await right.up();
    expect(find.byTooltip('Close photo'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unavailable photo has a working explicit retry', (tester) async {
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: AvatarViewer(
          name: 'Fictional person',
          loadPhoto: () async {
            requests++;
            return requests == 1 ? null : Uint8List.fromList(_pixel);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Photo unavailable'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

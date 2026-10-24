// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pump();
}

MouseCursor _cursorAt(WidgetTester tester, Finder finder) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(
    result,
    tester.getCenter(finder),
    tester.view.viewId,
  );
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderMouseRegion && target.cursor != MouseCursor.defer) {
      return target.cursor;
    }
  }
  return MouseCursor.defer;
}

void main() {
  Widget app(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('a right click does what a long press does', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      app(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NotionTapTarget(
              onTap: () => calls.add('tap'),
              onLongPress: () => calls.add('long'),
              child: const Text('Tile'),
            ),
            NotionPressable(
              onTap: () => calls.add('sticker'),
              onLongPress: () => calls.add('preview'),
              child: const Text('Sticker'),
            ),
            NotionTapTarget(
              onLongPress: () => calls.add('long only'),
              onSecondaryTap: () => calls.add('menu'),
              child: const Text('Own'),
            ),
          ],
        ),
      ),
    );
    await _rightClick(tester, find.text('Tile'));
    await _rightClick(tester, find.text('Sticker'));
    await _rightClick(tester, find.text('Own'));
    await tester.tap(find.text('Tile'));
    expect(calls, ['long', 'preview', 'menu', 'tap']);
  });

  testWidgets('tappable targets show the click cursor; others defer', (
    tester,
  ) async {
    var tappable = true;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return NotionTapTarget(
              onTap: tappable ? () {} : null,
              child: const SizedBox.square(dimension: 40, child: _Probe()),
            );
          },
        ),
      ),
    );
    final probe = tester.state<_ProbeState>(find.byType(_Probe));
    expect(_cursorAt(tester, find.byType(_Probe)), SystemMouseCursors.click);
    update(() => tappable = false);
    await tester.pump();
    expect(_cursorAt(tester, find.byType(_Probe)), MouseCursor.defer);
    // The child keeps its element (and state) when tapping turns off.
    expect(tester.state<_ProbeState>(find.byType(_Probe)), same(probe));
  });
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0x00000000));
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swipe_to_action/swipe_to_action.dart';

void main() {
  testWidgets('queued swipe layout update is safe after message disposal', (
    tester,
  ) async {
    final swipeKey = GlobalKey();
    late BuildContext sizedContext;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            Swipeable(
              key: swipeKey,
              onSwipe: (_) {},
              child: const SizedBox(width: 100, height: 40),
            ),
            MediaQuery(
              data: const MediaQueryData(size: Size(400, 800)),
              child: Builder(
                builder: (context) {
                  sizedContext = context;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
    final state = swipeKey.currentState!;
    // The first mount has no MediaQuery. Rendering with one now queues the
    // real package's width update. The next frame removes the message before
    // that pending post-frame callback runs, as a timeline replacement can.
    // ignore: invalid_use_of_protected_member
    state.build(sizedContext);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(state.mounted, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('mounted message remains usable after a width update',
      (tester) async {
    var swipes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Swipeable(
        key: const ValueKey('message'),
        onSwipe: (_) => swipes++,
        child: const SizedBox(width: 100, height: 40),
      ),
    ));
    await tester.pump();
    expect(find.byType(Swipeable), findsOneWidget);
    expect(swipes, 0);
    expect(tester.takeException(), isNull);
  });
}

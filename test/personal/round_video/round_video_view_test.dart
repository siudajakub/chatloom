import 'package:fluffychat/pages/chat/events/round_video_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'limited placeholder has no playback, seek, speed or action controls',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RoundVideoView(
              blockedReason:
                  'Wiadomość jednorazowa nie jest jeszcze obsługiwana.',
            ),
          ),
        ),
      );
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(
        find.text('Wiadomość jednorazowa nie jest jeszcze obsługiwana.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('large text and narrow width retain usable round controls', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 180,
              child: RoundVideoView(
                duration: const Duration(seconds: 60),
                onToggle: () => taps++,
                onSpeedChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Play round video'));
    expect(taps, 1);
    expect(find.text('0:00 / 1:00'), findsOneWidget);
  });

  testWidgets('Android speed control exposes the .2 to 3.0 profile', (
    tester,
  ) async {
    double? speed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoundVideoView(onSpeedChanged: (value) => speed = value),
        ),
      ),
    );
    await tester.tap(find.text('1×'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, .2);
    expect(slider.max, 3);
    await tester.tap(find.text('1.7×'));
    expect(speed, 1.7);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel and explicit played remain independent actions', (
    tester,
  ) async {
    var cancelled = 0;
    var reported = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoundVideoView(
            loading: true,
            downloadProgress: .4,
            onCancel: () => cancelled++,
            onReportPlayed: () => reported++,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Cancel download'));
    expect(cancelled, 1);
    expect(reported, 0);
    await tester.tap(find.text('Send playback receipt'));
    expect(reported, 1);
  });
}

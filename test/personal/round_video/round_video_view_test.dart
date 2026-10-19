import 'dart:typed_data';

import 'package:fluffychat/pages/chat/events/round_video_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child, {double width = 390, double scale = 1}) =>
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            textScaler: TextScaler.linear(scale),
          ),
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

Finder _circle() => find.byKey(const Key('circle'));

void main() {
  testWidgets(
    'limited placeholder has no playback, seek, speed or action controls',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const RoundVideoView(
            blockedReason: 'View-once or timed messages are not supported yet.',
            actions: [RoundSideAction(icon: Icons.download, tooltip: 'Save')],
          ),
        ),
      );
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(
        find.text('View-once or timed messages are not supported yet.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('large text and narrow width retain usable round controls', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 180,
          child: RoundVideoView(
            duration: const Duration(seconds: 60),
            onToggle: () => taps++,
          ),
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Play round video'));
    expect(taps, 1);
    expect(find.text('1:00'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Round video')), findsOneWidget);
  });

  testWidgets('inline diameter follows the Telegram clamp', (tester) async {
    for (final (width, expected) in [
      (390.0, 234.0),
      (240.0, 160.0),
      (800.0, 240.0),
    ]) {
      await tester.pumpWidget(
        _host(const RoundVideoView(circleKey: Key('circle')), width: width),
      );
      expect(tester.getSize(_circle()), Size.square(expected));
    }
  });

  testWidgets('pending keeps the ready frame size with play disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        RoundVideoView(
          circleKey: const Key('circle'),
          pending: true,
          onToggle: () {},
          actions: const [RoundSideAction(icon: Icons.download, tooltip: 's')],
        ),
      ),
    );
    final pendingSize = tester.getSize(find.byType(RoundVideoView));
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.play_arrow),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Checking'), findsNothing);
    await tester.pumpWidget(
      _host(
        RoundVideoView(
          circleKey: const Key('circle'),
          onToggle: () {},
          actions: const [RoundSideAction(icon: Icons.download, tooltip: 's')],
        ),
      ),
    );
    expect(tester.getSize(find.byType(RoundVideoView)), pendingSize);
  });

  testWidgets('side actions face the screen centre on both sides', (
    tester,
  ) async {
    for (final outgoing in [false, true]) {
      await tester.pumpWidget(
        _host(
          RoundVideoView(
            circleKey: const Key('circle'),
            outgoing: outgoing,
            actions: const [
              RoundSideAction(
                icon: Icons.download_outlined,
                tooltip: 'Save round video',
              ),
            ],
          ),
        ),
      );
      final circle = tester.getRect(_circle());
      final save = tester.getRect(
        find.widgetWithIcon(IconButton, Icons.download_outlined),
      );
      expect(save.width, greaterThanOrEqualTo(48));
      if (outgoing) {
        expect(save.right, lessThanOrEqualTo(circle.left));
      } else {
        expect(save.left, greaterThanOrEqualTo(circle.right));
      }
    }
  });

  testWidgets('status and duration pills sit on the circle; below is bounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const RoundVideoView(
          circleKey: Key('circle'),
          duration: Duration(seconds: 7),
          mediaUnread: true,
          speed: 1.5,
          statusOverlay: Text('12:30'),
          below: SizedBox(key: Key('below'), width: 1000, height: 10),
        ),
      ),
    );
    final circle = tester.getRect(_circle());
    expect(find.text('0:07'), findsOneWidget);
    expect(find.text('1.5×'), findsOneWidget);
    expect(find.byKey(const ValueKey('round-unread-dot')), findsOneWidget);
    expect(tester.getSemantics(_circle()).value, contains('not played yet'));
    final status = tester.getRect(find.text('12:30'));
    expect(circle.contains(status.center), isTrue);
    expect(
      tester.getSize(find.byKey(const Key('below'))).width,
      lessThanOrEqualTo(circle.width),
    );
  });

  testWidgets('thumbnail is decoded at the rendered diameter', (tester) async {
    await tester.pumpWidget(
      _host(RoundVideoView(thumbnail: Uint8List.fromList(const [1, 2, 3]))),
    );
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    // The host MediaQuery reports a device pixel ratio of 1.
    expect(provider.width, 234);
    expect(image.gaplessPlayback, isTrue);
  });

  testWidgets('progress ring is determinate while downloading', (tester) async {
    await tester.pumpWidget(
      _host(const RoundVideoView(loading: true, downloadProgress: .4)),
    );
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<RoundProgressPainter>()
        .single;
    expect(painter.progress, .4);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('cancel and explicit played remain independent actions', (
    tester,
  ) async {
    var cancelled = 0;
    var reported = 0;
    await tester.pumpWidget(
      _host(
        RoundVideoView(
          loading: true,
          downloadProgress: .4,
          onCancel: () => cancelled++,
          onReportPlayed: () => reported++,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Cancel download'));
    expect(cancelled, 1);
    expect(reported, 0);
    await tester.tap(find.byTooltip('Send playback receipt'));
    expect(reported, 1);
  });

  testWidgets('Android speed control exposes the .2 to 3.0 profile', (
    tester,
  ) async {
    double? speed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRoundSpeedPicker(
                context,
                speed: 1,
                onChanged: (value) => speed = value,
              ),
              child: const Text('1×'),
            ),
          ),
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
}

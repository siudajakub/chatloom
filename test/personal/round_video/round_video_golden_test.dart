// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden references for the inline round video states (fictional data).
import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/events/round_video_view.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _boundary = Key('golden');
const _diameter = 140.0;

/// Synthetic frame: a soft diagonal gradient, no real media.
Future<Uint8List> _thumbnail() async {
  final recorder = ui.PictureRecorder();
  const side = 160.0;
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, side, side),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(side, side),
        const [Color(0xFFB9C7D6), Color(0xFF5C6F84)],
      ),
  );
  final image = await recorder.endRecording().toImage(
    side.toInt(),
    side.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Widget _cell(String label, Widget round) => SizedBox(
  width: 160,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Builder(
        builder: (context) => Text(
          label,
          style: context.notion.typography.captionMuted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: NotionSpace.xxs),
      round,
    ],
  ),
);

Widget _states(Uint8List thumbnail) {
  const duration = Duration(seconds: 12);
  void noop() {}
  return Scaffold(
    body: SingleChildScrollView(
      padding: NotionSpace.page,
      child: Wrap(
        spacing: NotionSpace.md,
        runSpacing: NotionSpace.md,
        children: [
          _cell(
            'Idle, placeholder',
            RoundVideoView(
              diameter: _diameter,
              duration: duration,
              onToggle: noop,
            ),
          ),
          _cell(
            'Idle, thumbnail',
            RoundVideoView(
              diameter: _diameter,
              thumbnail: thumbnail,
              duration: duration,
              outgoing: true,
              onToggle: noop,
              statusOverlay: const Text('12:04'),
            ),
          ),
          _cell(
            'Downloading 40 %',
            RoundVideoView(
              diameter: _diameter,
              thumbnail: thumbnail,
              loading: true,
              downloadProgress: .4,
              duration: duration,
              onCancel: noop,
            ),
          ),
          _cell(
            'Downloading',
            RoundVideoView(
              diameter: _diameter,
              loading: true,
              duration: duration,
              onCancel: noop,
            ),
          ),
          _cell(
            'Playing',
            RoundVideoView(
              diameter: _diameter,
              thumbnail: thumbnail,
              playing: true,
              position: const Duration(seconds: 4),
              duration: duration,
              speed: 1.25,
              onToggle: noop,
            ),
          ),
          _cell(
            'Unread, muted',
            RoundVideoView(
              diameter: _diameter,
              thumbnail: thumbnail,
              mediaUnread: true,
              muted: true,
              duration: duration,
              onToggle: noop,
            ),
          ),
          _cell(
            'Blocked',
            const RoundVideoView(
              diameter: _diameter,
              blockedReason: 'View-once messages are not supported yet.',
            ),
          ),
          _cell(
            'Error',
            RoundVideoView(
              diameter: _diameter,
              duration: duration,
              error: 'Couldn’t play this video.',
              onToggle: noop,
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final variant in [
    (name: 'dark-1x', brightness: Brightness.dark, scale: 1.0),
    (name: 'dark-2x', brightness: Brightness.dark, scale: 2.0),
    (name: 'light-1x', brightness: Brightness.light, scale: 1.0),
  ]) {
    testWidgets('round video states ${variant.name}', (tester) async {
      final thumbnail = (await tester.runAsync(_thumbnail))!;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(390, variant.scale > 1 ? 980 : 820);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('en'),
            theme: NotionTheme.build(variant.brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(variant.scale)),
              child: child!,
            ),
            home: _states(thumbnail),
          ),
        ),
      );
      // Decode the synthetic thumbnails outside the fake clock.
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          final image = element.widget as Image;
          await precacheImage(image.image, element);
        }
      });
      // Fixed frames: the indeterminate spinner never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('round-unread-dot')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('round-download-spinner')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.videocam_outlined), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/round-video-states-${variant.name}.png'),
      );
    });
  }
}

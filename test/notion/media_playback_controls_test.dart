// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Center(
      child: ColoredBox(
        color: NotionMediaColors.stageScrim,
        child: Padding(
          padding: const EdgeInsets.all(NotionSpace.md),
          child: child,
        ),
      ),
    ),
  ),
);

NotionMediaPlaybackControls _controls({
  VoidCallback? toggle,
  FutureOr<void> Function(Duration)? seek,
  Widget? trailing,
}) => NotionMediaPlaybackControls(
  playing: true,
  position: const Duration(seconds: 12),
  duration: const Duration(minutes: 1, seconds: 30),
  speed: 1,
  onToggle: toggle ?? () {},
  onSeek: seek ?? (_) {},
  onSpeedCycle: () {},
  trailing: trailing,
);

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

  testWidgets('transport toggles, previews a seek and recovers failed seeks', (
    tester,
  ) async {
    var toggles = 0;
    final seeks = <Duration>[];
    final pending = Completer<void>();
    await tester.pumpWidget(
      _app(
        _controls(
          toggle: () => toggles++,
          seek: (value) {
            seeks.add(value);
            return pending.future;
          },
        ),
      ),
    );
    await tester.tap(find.byTooltip('Pause'));
    expect(toggles, 1);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(45000);
    slider.onChanged!(45000);
    slider.onChangeEnd!(45000);
    await tester.pump();
    expect(seeks, [const Duration(seconds: 45)]);
    expect(find.text('0:45 / 1:30'), findsOneWidget);
    pending.completeError(StateError('native seek failed'));
    await tester.pump();
    expect(find.text('0:12 / 1:30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('secondary controls stay in the menu and run after it closes', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      _app(
        _controls(
          trailing: NotionMediaActionsButton(
            actions: [
              NotionMediaAction(
                label: 'Save video',
                icon: Icons.download_outlined,
                onPressed: () => saves++,
              ),
              const NotionMediaAction(
                label: 'Forward video',
                icon: Icons.forward_outlined,
                onPressed: null,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Save video'), findsNothing);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Save video'), findsOneWidget);
    await tester.tap(find.text('Save video'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('Save video'), findsNothing);
  });

  testWidgets('narrow large type transport fits and waveform replaces slider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        NotionMediaPlaybackControls(
          playing: false,
          position: const Duration(seconds: 12),
          duration: const Duration(minutes: 1, seconds: 30),
          speed: 1,
          seekControl: const SizedBox(height: 48, child: Text('Waveform')),
          onToggle: () {},
          onSpeedCycle: () {},
          trailing: IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
        ),
        textScale: 2,
      ),
    );
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Waveform'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('media playback controls golden ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('media-controls-golden'),
          child: _app(
            _controls(
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NotionMediaActionsButton(
                    actions: [
                      NotionMediaAction(
                        label: 'Save',
                        icon: Icons.download_outlined,
                        onPressed: () {},
                      ),
                    ],
                  ),
                  IconButton(
                    onPressed: () {},
                    tooltip: 'Close',
                    color: NotionMediaColors.onScrim,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            brightness: brightness,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const Key('media-controls-golden')),
        matchesGoldenFile(
          'goldens/primitives/media-controls-${brightness.name}.png',
        ),
      );
    });
  }
}

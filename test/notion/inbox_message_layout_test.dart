// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/personal/ui/notion_inbox_dock.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/layouts/two_column_layout.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUpAll(() async {
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Medium.ttf'))
      ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Bold.ttf'));
    await fonts.load();
  });
  for (final wide in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      for (final bottom in [0.0, 34.0]) {
        testWidgets(
          'inbox messages clear dock: wide=$wide scale=$scale safe=$bottom',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(wide ? 1200 : 320, 800);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final boundary = GlobalKey();
            final messenger = GlobalKey<ScaffoldMessengerState>();
            var settings = 0;
            var closed = 0;
            Widget inbox() => Builder(
              builder: (context) => NotionInboxPage(
                pins: const [],
                networks: const [],
                onCompose: () {},
                onSettings: () => settings++,
                onSearch: () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(days: 1),
                    content: const Text('One of your devices is not verified'),
                    action: SnackBarAction(
                      label: 'Review',
                      onPressed: () => closed++,
                    ),
                  ),
                ),
                onNetworkSelected: (_) {},
              ),
            );
            await tester.pumpWidget(
              MaterialApp(
                scaffoldMessengerKey: messenger,
                theme: NotionTheme.build(Brightness.dark),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    padding: EdgeInsets.only(top: 24, bottom: bottom),
                  ),
                  child: RepaintBoundary(key: boundary, child: child),
                ),
                home: wide
                    ? TwoColumnLayout(
                        mainView: inbox(),
                        sideView: const Scaffold(body: Text('Conversation')),
                      )
                    : inbox(),
              ),
            );
            await tester.tap(find.byKey(const ValueKey('notion_dock_search')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.byType(SnackBar), findsOneWidget);
            final message = tester.getRect(
              find
                  .descendant(
                    of: find.byType(SnackBar),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            final dock = tester.getRect(find.byType(NotionInboxDock));
            expect(message.bottom, lessThan(dock.top));
            expect(dock.bottom, closeTo(800 - bottom - NotionSpace.sm, 0.1));
            expect(message.top, greaterThanOrEqualTo(24));
            if (wide) {
              expect(
                message.right,
                lessThanOrEqualTo(dock.right + NotionSpace.md),
              );
            }
            final capture = Platform.environment['NOTION_CAPTURE_DIR'];
            if (capture != null && !wide && scale == 2 && bottom == 34) {
              final render = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(boundary),
              );
              await tester.runAsync(() async {
                final image = await render.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await Directory(capture).create(recursive: true);
                await File(
                  '$capture/inbox-message-above-dock.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            await tester.tap(
              find.byKey(const ValueKey('notion_dock_settings')),
            );
            expect(settings, 1);
            await tester.tap(find.text('Review'));
            await tester.pumpAndSettle();
            expect(closed, 1);
            expect(find.byType(SnackBar), findsNothing);
          },
        );
      }
    }
  }
}

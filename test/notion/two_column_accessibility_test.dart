// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:fluffychat/config/routes.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/widgets/layouts/two_column_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final hasNavigationRail in [true, false]) {
    testWidgets(
      'main pane stays accessible through child navigation and resize, rail $hasNavigationRail',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1365, 900);
        final semantics = tester.ensureSemantics();
        var mainActions = 0;
        var childActions = 0;
        const mainLabel = 'Fixture main navigation';
        const childLabel = 'Fixture child action';

        Widget mainView() => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => mainActions++,
              child: const Text(mainLabel),
            ),
          ),
        );

        final router = GoRouter(
          initialLocation: '/rooms',
          routes: [
            ShellRoute(
              pageBuilder: (context, state, child) =>
                  AppRoutes.noTransitionPageBuilder(
                    context,
                    state,
                    FluffyThemes.isColumnMode(context)
                        ? TwoColumnLayout(
                            mainView: mainView(),
                            sideView: child,
                            hasNavigationRail: hasNavigationRail,
                          )
                        : child,
                  ),
              routes: [
                GoRoute(
                  path: '/rooms',
                  pageBuilder: (context, state) => AppRoutes.defaultPageBuilder(
                    context,
                    state,
                    FluffyThemes.isColumnMode(context)
                        ? const Scaffold(body: Text('Fixture empty pane'))
                        : mainView(),
                  ),
                  routes: [
                    GoRoute(
                      path: 'detail',
                      pageBuilder: (context, state) =>
                          AppRoutes.defaultPageBuilder(
                            context,
                            state,
                            Scaffold(
                              body: Center(
                                child: TextButton(
                                  onPressed: () => childActions++,
                                  child: const Text(childLabel),
                                ),
                              ),
                            ),
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        void activateNamedButton(String label) {
          final finder = find.semantics.byLabel(label);
          expect(finder, findsOne);
          final node = finder.evaluate().single;
          final data = node.getSemanticsData();
          expect(data.label, label);
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          tester.semantics.tap(finder);
        }

        try {
          await tester.pumpWidget(MaterialApp.router(routerConfig: router));
          await tester.pumpAndSettle();
          expect(find.byType(TwoColumnLayout), findsOneWidget);
          expect(find.text('Fixture empty pane'), findsOneWidget);
          activateNamedButton(mainLabel);
          expect(mainActions, 1);

          router.go('/rooms/detail');
          await tester.pumpAndSettle();
          activateNamedButton(mainLabel);
          expect(mainActions, 2);
          activateNamedButton(childLabel);
          expect(childActions, 1);

          final dialog = showDialog<void>(
            context: tester.element(find.byType(TwoColumnLayout)),
            builder: (context) => AlertDialog(
              title: const Text('Fixture modal'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Fixture close dialog'),
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();
          expect(find.semantics.byLabel(mainLabel), findsNothing);
          expect(find.semantics.byLabel(childLabel), findsNothing);
          activateNamedButton('Fixture close dialog');
          await tester.pumpAndSettle();
          await dialog;
          expect(find.semantics.byLabel(mainLabel), findsOne);
          expect(find.semantics.byLabel(childLabel), findsOne);

          tester.view.physicalSize = const Size(390, 844);
          await tester.pumpAndSettle();
          expect(find.byType(TwoColumnLayout), findsNothing);
          expect(find.semantics.byLabel(mainLabel), findsNothing);
          activateNamedButton(childLabel);
          expect(childActions, 2);

          router.go('/rooms');
          await tester.pumpAndSettle();
          activateNamedButton(mainLabel);
          expect(mainActions, 3);

          tester.view.physicalSize = const Size(1365, 900);
          await tester.pumpAndSettle();
          expect(find.byType(TwoColumnLayout), findsOneWidget);
          activateNamedButton(mainLabel);
          expect(mainActions, 4);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
          semantics.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }
}

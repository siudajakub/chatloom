// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:async/async.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/adaptive_bottom_sheet.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Fictional host: returns the context below the navigator.
Future<BuildContext> _host(WidgetTester tester, {bool reduced = false}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          captured = context;
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    ),
  );
  // Localizations load asynchronously before the home page builds.
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('ok/cancel dialog uses the Notion route and still returns', (
    tester,
  ) async {
    final context = await _host(tester);
    final result = showOkCancelAlertDialog(
      context: context,
      title: 'Fictional question',
      okLabel: 'Yes',
      cancelLabel: 'No',
    );
    await tester.pump();
    expect(find.byType(NotionDialogTransition), findsOneWidget);
    // Mid-entrance the dialog is scaled below identity.
    await tester.pump(const Duration(milliseconds: 40));
    final scale = tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.text('Fictional question'),
            matching: find.byType(Transform),
          ),
        )
        .map((t) => t.transform.storage[0])
        .reduce((a, b) => a < b ? a : b);
    expect(scale, lessThan(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(await result, OkCancelResult.ok);
    expect(find.text('Fictional question'), findsNothing);
  });

  testWidgets('text input dialog shakes on rejection and keeps the error', (
    tester,
  ) async {
    final context = await _host(tester);
    final result = showTextInputDialog(
      context: context,
      title: 'Fictional name',
      okLabel: 'Save',
      validator: (input) => input.length < 3 ? 'Too short' : null,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Too short'), findsOneWidget);
    expect(find.byType(NotionShake), findsOneWidget);
    await tester.pumpAndSettle();
    // A rebuild of the dialog (keyboard, theme) keeps the shown error.
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.text('Too short'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Fictional');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await result, 'Fictional');
  });

  testWidgets('modal action popup and adaptive sheet return their value', (
    tester,
  ) async {
    final context = await _host(tester);
    final action = showModalActionPopup<int>(
      context: context,
      title: 'Fictional actions',
      actions: [
        AdaptiveModalAction(label: 'First', value: 1),
        AdaptiveModalAction(label: 'Second', value: 2),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byType(NotionEntrance), findsNWidgets(4));
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(await action, 2);

    final sheet = showAdaptiveBottomSheet<String>(
      context: context,
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).pop('picked'),
        child: const Text('Pick'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    expect(await sheet, 'picked');
  });

  testWidgets('fast work never flashes a loading dialog', (tester) async {
    final context = await _host(tester);
    final result = showFutureLoadingDialog<int>(
      context: context,
      future: () async => 7,
    );
    await tester.pump();
    expect(find.byType(LoadingDialog<int>), findsNothing);
    expect((await result).result, 7);
    // The grace timer was cancelled: nothing is pending.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LoadingDialog<int>), findsNothing);
  });

  testWidgets('slow work shows the dialog, then a check, then closes', (
    tester,
  ) async {
    final context = await _host(tester);
    final work = Completer<int>();
    final result = showFutureLoadingDialog<int>(
      context: context,
      future: () => work.future,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LoadingDialog<int>), findsNothing);
    await tester.pump(NotionMotion.loaderGrace);
    await tester.pump(NotionMotion.medium);
    expect(find.byType(LoadingDialog<int>), findsOneWidget);
    work.complete(42);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(LoadingDialog<int>), findsNothing);
    expect((await result).result, 42);
  });

  testWidgets('reduced motion closes the loading dialog without a check', (
    tester,
  ) async {
    final context = await _host(tester, reduced: true);
    final work = Completer<int>();
    final result = showFutureLoadingDialog<int>(
      context: context,
      future: () => work.future,
    );
    await tester.pump(NotionMotion.loaderGrace);
    await tester.pump(NotionMotion.medium);
    expect(find.byType(LoadingDialog<int>), findsOneWidget);
    work.complete(1);
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    await tester.pumpAndSettle();
    expect((await result).result, 1);
  });

  testWidgets('failed work fades through to the error and returns it', (
    tester,
  ) async {
    final context = await _host(tester);
    final work = Completer<int>();
    final result = showFutureLoadingDialog<int>(
      context: context,
      future: () => work.future,
    );
    await tester.pump(NotionMotion.loaderGrace);
    await tester.pump(NotionMotion.medium);
    work.completeError(Exception('fictional failure'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline_outlined), findsOneWidget);
    await tester.tap(find.text(L10n.of(context).close));
    await tester.pumpAndSettle();
    final value = await result;
    expect(value, isA<ErrorResult>());
    expect(find.byType(LoadingDialog<int>), findsNothing);
  });

  testWidgets('settings body staggers its sections and settles to identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: const Scaffold(
          body: NotionSettingsBody(
            child: Column(children: [Text('One'), Text('Two'), Text('Three')]),
          ),
        ),
      ),
    );
    expect(find.byType(NotionEntrance), findsNWidgets(3));
    await tester.pump(const Duration(milliseconds: 30));
    double opacityOf(String text) => tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.text(text),
            matching: find.byType(FadeTransition),
          ),
        )
        .fold(1.0, (value, fade) => value * fade.opacity.value);
    // The first section leads the cascade.
    expect(opacityOf('One'), greaterThan(opacityOf('Three')));
    await tester.pumpAndSettle();
    for (final text in ['One', 'Two', 'Three']) {
      expect(opacityOf(text), 1);
    }
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 6 dialogs-settings: every dialog helper renders the glass Notion
// dialog on every platform (no Cupertino on macOS), loading dialogs use the
// Notion spinner, and settings sub-pages have the glass header.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/ui/capabilities_dialog.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/show_update_snackbar.dart';
import 'package:chatloom/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:chatloom/widgets/permission_slider_dialog.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:personal_core/bridge_capabilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fictional host on [platform]: returns the context below the navigator.
Future<BuildContext> _host(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  Brightness brightness = Brightness.dark,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(brightness).copyWith(platform: platform),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) {
          captured = context;
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void _expectNoCupertino() {
  expect(find.byType(CupertinoAlertDialog), findsNothing);
  expect(find.byType(CupertinoActionSheet), findsNothing);
  expect(find.byType(CupertinoDialogAction), findsNothing);
  expect(find.byType(CupertinoTextField), findsNothing);
  expect(find.byType(CupertinoActivityIndicator), findsNothing);
  expect(find.byType(AlertDialog), findsNothing);
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    testWidgets('ok/cancel is a glass NotionDialog on ${platform.name}', (
      tester,
    ) async {
      final context = await _host(tester, platform: platform);
      final result = showOkCancelAlertDialog(
        context: context,
        title: 'Fictional question',
        message: 'Fictional details',
        okLabel: 'Yes',
        cancelLabel: 'No',
      );
      await tester.pumpAndSettle();
      expect(find.byType(NotionDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NotionDialog),
          matching: find.byType(NotionGlassPanel),
        ),
        findsOneWidget,
      );
      _expectNoCupertino();
      // The legacy keys stay on the buttons for flows and tests.
      expect(
        find.byKey(const Key('ok_cancel_alert_dialog_ok_button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('ok_cancel_alert_dialog_cancel_button')),
      );
      await tester.pumpAndSettle();
      expect(await result, OkCancelResult.cancel);
    });

    testWidgets('text input is glass with a Notion field on ${platform.name}', (
      tester,
    ) async {
      final context = await _host(tester, platform: platform);
      final result = showTextInputDialog(
        context: context,
        title: 'Fictional name',
        labelText: 'Name',
        maxLines: 1,
      );
      await tester.pumpAndSettle();
      expect(find.byType(NotionDialog), findsOneWidget);
      _expectNoCupertino();
      // The field has focus at once and Return submits a single line.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofocus, isTrue);
      await tester.enterText(find.byType(TextField), 'Fictional');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(await result, 'Fictional');
    });

    testWidgets('loading dialog uses the Notion spinner on ${platform.name}', (
      tester,
    ) async {
      final context = await _host(tester, platform: platform);
      final work = Completer<int>();
      final result = showFutureLoadingDialog<int>(
        context: context,
        future: () => work.future,
      );
      await tester.pump(NotionMotion.loaderGrace);
      await tester.pump(NotionMotion.medium);
      expect(find.byType(LoadingDialog<int>), findsOneWidget);
      expect(find.byType(NotionDialogFrame), findsOneWidget);
      expect(find.byType(NotionDelayedSpinner), findsOneWidget);
      _expectNoCupertino();
      work.complete(3);
      await tester.pumpAndSettle();
      expect((await result).result, 3);
    });
  }

  testWidgets('loading spinner rests after the loop cap', (tester) async {
    final context = await _host(tester);
    final work = Completer<int>();
    final result = showFutureLoadingDialog<int>(
      context: context,
      future: () => work.future,
    );
    await tester.pump(NotionMotion.loaderGrace);
    await tester.pump(NotionMotion.medium);
    final spinner = find.byType(NotionDelayedSpinner);
    expect(spinner, findsOneWidget);
    expect(tester.widget<NotionDelayedSpinner>(spinner).maxSpin, isNotNull);
    // An endless wait stops drawing frames.
    await tester.pump(NotionMotion.loopCap + const Duration(seconds: 1));
    expect(tester.hasRunningAnimations, isFalse);
    work.complete(1);
    await tester.pumpAndSettle();
    expect((await result).result, 1);
  });

  testWidgets('Return confirms a question, never a destructive one', (
    tester,
  ) async {
    final context = await _host(tester, platform: TargetPlatform.macOS);
    final plain = showOkCancelAlertDialog(context: context, title: 'Plain');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await plain, OkCancelResult.ok);

    final destructive = showOkCancelAlertDialog(
      context: context,
      title: 'Destructive',
      okLabel: 'Delete',
      isDestructive: true,
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Destructive'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(await destructive, OkCancelResult.ok);
  });

  testWidgets('action popup is a centred glass dialog on macOS', (
    tester,
  ) async {
    final context = await _host(tester, platform: TargetPlatform.macOS);
    final action = showModalActionPopup<int>(
      context: context,
      title: 'Fictional actions',
      cancelLabel: 'Cancel',
      actions: [
        AdaptiveModalAction(label: 'First', value: 1),
        AdaptiveModalAction(label: 'Remove', value: 2, isDestructive: true),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byType(NotionDialogFrame), findsOneWidget);
    expect(find.byType(NotionGlassMenuRow), findsNWidgets(3));
    expect(find.byType(BottomSheet), findsNothing);
    _expectNoCupertino();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(await action, 2);
  });

  testWidgets('action popup is a glass sheet of menu rows on Android', (
    tester,
  ) async {
    final context = await _host(tester);
    final action = showModalActionPopup<int>(
      context: context,
      actions: [AdaptiveModalAction(label: 'Only', value: 7)],
      cancelLabel: 'Cancel',
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(NotionGlassMenuRow), findsNWidgets(2));
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await action, isNull);
  });

  testWidgets('legacy dialog actions are Notion buttons on macOS', (
    tester,
  ) async {
    final context = await _host(tester, platform: TargetPlatform.macOS);
    unawaited(
      showNotionCustomDialog<void>(
        context: context,
        builder: (context) => NotionAlertDialog(
          title: const Text('Fictional legacy'),
          actions: [
            AdaptiveDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    _expectNoCupertino();
    expect(find.byType(TextButton), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Fictional legacy'), findsNothing);
  });

  testWidgets('permission level dialog validates and returns the level', (
    tester,
  ) async {
    final context = await _host(tester, platform: TargetPlatform.macOS);
    final level = showPermissionChooser(context, currentLevel: 0);
    await tester.pumpAndSettle();
    expect(find.byType(NotionDialog), findsOneWidget);
    _expectNoCupertino();
    final l10n = L10n.of(context);
    await tester.enterText(find.byType(TextField), 'x');
    await tester.tap(find.text(l10n.setPowerLevel));
    await tester.pump();
    expect(find.text(l10n.pleaseEnterANumber), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '50');
    await tester.tap(find.text(l10n.setPowerLevel));
    await tester.pumpAndSettle();
    expect(await level, 50);
  });

  testWidgets('settings sub-pages have a glass header with rows under it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.light),
        home: const NotionSettingsScaffold(
          title: 'Fictional settings',
          child: Column(children: [Text('First row')]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.extendBodyBehindAppBar, isTrue);
    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.backgroundColor, Colors.transparent);
    expect(find.byType(NotionGlassBar), findsOneWidget);
    // The first row starts below the header, inside the scroll view that
    // passes under it.
    final header = tester.getRect(find.byType(AppBar));
    expect(
      tester.getTopLeft(find.text('First row')).dy,
      greaterThanOrEqualTo(header.bottom),
    );
    final scroll = tester.getRect(find.byType(SingleChildScrollView));
    expect(scroll.top, lessThan(header.bottom));
  });

  testWidgets('non-scrolling settings body adds the header height once', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: NotionSettingsScaffold(
          title: 'Fictional list',
          withScrolling: false,
          child: Column(
            children: [
              Expanded(child: ListView(children: const [Text('Listed row')])),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final header = tester.getRect(find.byType(AppBar));
    final top = tester.getTopLeft(find.text('Listed row')).dy;
    expect(top, greaterThanOrEqualTo(header.bottom));
    expect(top, lessThan(header.bottom + NotionSpace.xxl));
  });

  testWidgets('an update says so once in a snackbar, never a dialog', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      UpdateNotifier.versionStoreKey: '1.0.0',
    });
    await AppSettings.init(loadWebConfigFile: false);
    PackageInfo.setMockInitialValues(
      appName: 'ChatLoom',
      packageName: 'example.invalid',
      version: '1.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final context = await _host(tester);
    await UpdateNotifier.showUpdateDialog(context);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text(UpdateNotifier.updatedText('1.1.0')), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    // The snackbar times out on its own (its timer starts once it is in).
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    // The same version again: nothing.
    await UpdateNotifier.showUpdateDialog(context);
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a first install shows no update notice', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    PackageInfo.setMockInitialValues(
      appName: 'ChatLoom',
      packageName: 'example.invalid',
      version: '1.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final context = await _host(tester);
    await UpdateNotifier.showUpdateDialog(context);
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('reduced-motion size changes snap without a layout error', (
    tester,
  ) async {
    Widget box(double height) => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Center(
          child: NotionAnimatedSize(child: SizedBox(width: 10, height: height)),
        ),
      ),
    );
    await tester.pumpWidget(box(10));
    await tester.pumpWidget(box(40));
    // One frame later the new size is there.
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(NotionAnimatedSize)).height, 40);
    // A relayout at rest (a glass dialog settling) is just as quiet.
    await tester.pumpWidget(box(40));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('every bridge feature has a readable name', () {
    for (final feature in BridgeFeature.values) {
      final label = bridgeFeatureLabel(feature);
      expect(label, isNot(feature.name), reason: feature.name);
      expect(label[0], label[0].toUpperCase());
    }
  });
}

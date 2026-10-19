// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/ui/notion/notion_theme.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/lock_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app({bool reduced = false}) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: const AppLockWidget(
    pincode: '2468',
    useBiometrics: false,
    isLoggedIn: true,
    child: Scaffold(body: Text('private content')),
  ),
);

double _lockOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(LockScreen),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

Future<void> _enterPin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byType(TextField), pin);
  await tester.testTextInput.receiveAction(TextInputAction.go);
  await tester.pump();
}

void main() {
  testWidgets('the lock covers instantly and only dissolves after unlock', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    // Wait for localizations, then the lock is there and fully opaque.
    await tester.pumpAndSettle();
    expect(find.byType(LockScreen), findsOneWidget);
    expect(_lockOpacity(tester), 1);
    expect(PersonalPrivacy.surfaceUnlocked, isFalse);

    // A wrong PIN draws one dot per digit, shakes and blocks input.
    await tester.enterText(find.byType(TextField), '13');
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(LockScreen),
        matching: find.byType(NotionPop),
      ),
      findsNWidgets(2),
    );
    await _enterPin(tester, '1357');
    expect(find.byType(LockScreen), findsOneWidget);
    expect(_lockOpacity(tester), 1);
    expect(PersonalPrivacy.surfaceUnlocked, isFalse);
    // The cool-down ends; the lock is still fully opaque.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(_lockOpacity(tester), 1);

    // The right PIN unlocks at once, then the lock fades without input.
    await _enterPin(tester, '2468');
    expect(PersonalPrivacy.surfaceUnlocked, isTrue);
    await tester.pump(NotionMotion.quick);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(_lockOpacity(tester), lessThan(1));
    final ignoring = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(LockScreen),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignoring.ignoring, isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(LockScreen), findsNothing);
    expect(find.text('private content'), findsOneWidget);

    // Locking again covers on the very next frame, with no fade-in.
    tester.state<AppLock>(find.byType(AppLockWidget)).showLockScreen();
    await tester.pump();
    expect(find.byType(LockScreen), findsOneWidget);
    expect(_lockOpacity(tester), 1);
    expect(PersonalPrivacy.surfaceUnlocked, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion removes the lock without a fade', (tester) async {
    await tester.pumpWidget(_app(reduced: true));
    await tester.pumpAndSettle();
    await _enterPin(tester, '2468');
    expect(find.byType(LockScreen), findsNothing);
    expect(PersonalPrivacy.surfaceUnlocked, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

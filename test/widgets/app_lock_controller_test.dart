// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/client_startup.dart';
import 'package:chatloom/widgets/lock_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fictional device biometrics: every answer is scripted, nothing reaches a
/// platform channel.
class _Biometrics extends AppLockBiometrics {
  _Biometrics(this.answer);
  Future<bool> Function() answer;
  int calls = 0;

  @override
  Future<bool> authenticate(String reason) {
    calls++;
    return answer();
  }

  @override
  Future<bool> usesFace() async => false;
}

Future<bool> Function() _throws(LocalAuthExceptionCode code) =>
    () async => throw LocalAuthException(code: code);

AppLockController _lock(_Biometrics biometrics) => AppLockController(
  pincode: '2468',
  useBiometrics: true,
  biometrics: biometrics,
);

Widget _app(AppLockController lock, {Key? key, String child = 'content'}) =>
    KeyedSubtree(
      key: key,
      child: MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: AppLockWidget(
          controller: lock,
          isLoggedIn: true,
          child: Scaffold(body: Text(child)),
        ),
      ),
    );

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    PersonalPrivacy.surfaceUnlocked = true;
  });

  group('AppLockController (CC-07)', () {
    testWidgets('a cancelled prompt keeps the lock and the privacy gate shut', (
      tester,
    ) async {
      final biometrics = _Biometrics(
        _throws(LocalAuthExceptionCode.userCanceled),
      );
      final lock = _lock(biometrics);
      addTearDown(lock.dispose);
      expect(lock.isLocked, isTrue);
      expect(PersonalPrivacy.surfaceUnlocked, isFalse);

      final result = await lock.unlockWithBiometrics();
      expect(result.outcome, AppLockBiometricOutcome.cancelled);
      expect(result.message, isNull);
      expect(lock.isLocked, isTrue);
      expect(PersonalPrivacy.surfaceUnlocked, isFalse);
      // The PIN remains the way in.
      expect(lock.unlock('2468'), isTrue);
      expect(lock.isLocked, isFalse);
      expect(PersonalPrivacy.surfaceUnlocked, isTrue);
    });

    testWidgets('every failure code maps to a result, never an exception', (
      tester,
    ) async {
      for (final code in LocalAuthExceptionCode.values) {
        final lock = _lock(_Biometrics(_throws(code)));
        final result = await lock.unlockWithBiometrics();
        expect(result.unlocked, isFalse, reason: code.name);
        expect(lock.isLocked, isTrue, reason: code.name);
        lock.dispose();
      }
      final plugin = _lock(
        _Biometrics(() async => throw MissingPluginException()),
      );
      expect(
        (await plugin.unlockWithBiometrics()).outcome,
        AppLockBiometricOutcome.failed,
      );
      plugin.dispose();
    });

    testWidgets('no enrolled biometrics turns the automatic prompt off', (
      tester,
    ) async {
      final biometrics = _Biometrics(
        _throws(LocalAuthExceptionCode.noBiometricsEnrolled),
      );
      final lock = _lock(biometrics);
      addTearDown(lock.dispose);
      final result = await lock.unlockWithBiometrics();
      expect(result.outcome, AppLockBiometricOutcome.unavailable);
      expect(result.message, contains('isn’t set up'));
      expect(lock.biometricsAvailable, isFalse);
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(biometrics.calls, 1);
    });

    testWidgets('one prompt at a time', (tester) async {
      final answer = Completer<bool>();
      final biometrics = _Biometrics(() => answer.future);
      final lock = _lock(biometrics);
      addTearDown(lock.dispose);
      final first = lock.unlockWithBiometrics();
      final second = lock.unlockWithBiometrics();
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(biometrics.calls, 1);
      answer.complete(true);
      expect((await first).unlocked, isTrue);
      expect((await second).unlocked, isTrue);
      expect(lock.isLocked, isFalse);
    });

    testWidgets('a prompt from an earlier lock cannot open a later one', (
      tester,
    ) async {
      final answer = Completer<bool>();
      final lock = _lock(_Biometrics(() => answer.future));
      addTearDown(lock.dispose);
      final prompt = lock.unlockWithBiometrics();
      expect(lock.unlock('2468'), isTrue);
      lock.showLockScreen();
      answer.complete(true);
      await prompt;
      expect(lock.isLocked, isTrue);
      expect(PersonalPrivacy.surfaceUnlocked, isFalse);
    });

    testWidgets('a PIN unlock re-arms the automatic prompt for the next lock', (
      tester,
    ) async {
      final biometrics = _Biometrics(
        _throws(LocalAuthExceptionCode.userCanceled),
      );
      final lock = _lock(biometrics);
      addTearDown(lock.dispose);
      await lock.unlockWithBiometrics();
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(biometrics.calls, 1); // Tried once for this lock.
      expect(lock.unlock('2468'), isTrue);
      lock.showLockScreen();
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(biometrics.calls, 2);
    });
  });

  testWidgets(
    'startup surface → app keeps one lock: one prompt, gate opens only on unlock',
    (tester) async {
      final answer = Completer<bool>();
      final biometrics = _Biometrics(() => answer.future);
      final lock = _lock(biometrics);
      addTearDown(lock.dispose);

      await tester.pumpWidget(
        _app(lock, key: const ValueKey('startup'), child: 'skeleton'),
      );
      await tester.pump(); // Post-frame automatic prompt.
      expect(biometrics.calls, 1);
      expect(find.text(LockScreen.title), findsOneWidget);

      // The app replaces the startup surface while the prompt is open.
      await tester.pumpWidget(
        _app(lock, key: const ValueKey('app'), child: 'private content'),
      );
      await tester.pump();
      expect(biometrics.calls, 1);
      expect(find.text(LockScreen.title), findsOneWidget);
      expect(PersonalPrivacy.surfaceUnlocked, isFalse);

      answer.complete(true);
      await tester.pumpAndSettle();
      expect(PersonalPrivacy.surfaceUnlocked, isTrue);
      expect(find.byType(LockScreen), findsNothing);
      expect(find.text('private content'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'lock screen: cancel hands over to the PIN, other failures explain once',
    (tester) async {
      final biometrics = _Biometrics(
        _throws(LocalAuthExceptionCode.userCanceled),
      );
      final lock = _lock(biometrics);
      addTearDown(lock.dispose);
      await tester.pumpWidget(_app(lock));
      await tester.pumpAndSettle();
      expect(biometrics.calls, 1); // The automatic prompt, cancelled.
      expect(find.textContaining('Wrong PIN'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );

      biometrics.answer = _throws(LocalAuthExceptionCode.temporaryLockout);
      await tester.tap(find.byTooltip('Unlock with biometrics'));
      await tester.pumpAndSettle();
      expect(find.text('Too many attempts. Enter your PIN.'), findsOneWidget);
      expect(find.textContaining('Wrong PIN'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );

      await tester.enterText(find.byType(TextField), '2468');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsNothing);
      expect(PersonalPrivacy.surfaceUnlocked, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a failed automatic prompt is explained and falls back to PIN', (
    tester,
  ) async {
    final lock = _lock(
      _Biometrics(_throws(LocalAuthExceptionCode.noBiometricsEnrolled)),
    );
    addTearDown(lock.dispose);
    await tester.pumpWidget(_app(lock));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Biometric unlock isn’t set up on this device. Enter your PIN.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Unlock with biometrics'), findsNothing);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a PIN-locked cold start shows a working lock over the startup skeleton',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        ClientManager.clientNamespace: ['saved'],
      });
      final store = await SharedPreferences.getInstance();
      final opening = Completer<Client>();
      final startup = ClientStartup(
        store: store,
        clientFactory: (_, _) => opening.future,
      );
      final restoring = startup.restore();
      await tester.pumpWidget(
        ClientStartupView(
          startup: startup,
          appLockSettings: (pincode: '2468', useBiometrics: false),
        ),
      );
      // No localizations exist yet on this surface: the lock must not need
      // them.
      expect(tester.takeException(), isNull);
      expect(find.text(LockScreen.title), findsOneWidget);
      expect(find.byType(ClientStartupSkeleton), findsOneWidget);
      expect(PersonalPrivacy.surfaceUnlocked, isFalse);

      await tester.enterText(find.byType(TextField), '2468');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(PersonalPrivacy.surfaceUnlocked, isTrue);

      opening.completeError(StateError('synthetic database failure'));
      await restoring;
      await tester.pumpAndSettle();
      expect(find.text('Could not restore your accounts.'), findsOneWidget);
      expect(find.byType(LockScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      startup.dispose();
    },
  );

  testWidgets('a hidden Mac window keeps voice only without a lock (MAC-04)', (
    tester,
  ) async {
    RoundPlaybackCoordinator.debugKeepsVoiceWhenHidden = true;
    addTearDown(
      () => RoundPlaybackCoordinator.debugKeepsVoiceWhenHidden = null,
    );
    final open = AppLockController();
    addTearDown(open.dispose);
    expect(open.sparesVoiceWhenHidden(AppLifecycleState.hidden), isTrue);
    expect(open.sparesVoiceWhenHidden(AppLifecycleState.paused), isFalse);

    final locked = _lock(_Biometrics(() async => false));
    addTearDown(locked.dispose);
    expect(
      locked.sparesVoiceWhenHidden(AppLifecycleState.hidden),
      isFalse,
      reason: 'a configured lock locks on hidden and stops voice',
    );

    RoundPlaybackCoordinator.debugKeepsVoiceWhenHidden = false;
    expect(
      open.sparesVoiceWhenHidden(AppLifecycleState.hidden),
      isFalse,
      reason: 'phones pause voice in the background',
    );
  });
}

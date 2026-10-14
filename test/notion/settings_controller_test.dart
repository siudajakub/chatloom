// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings/settings.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Account extends Client {
  final String account;
  final bool encrypted;
  final Completer<void>? accountGate;
  final profile = Completer<Profile>();
  int accountDataReads = 0;
  int profileWrites = 0;
  int logouts = 0;
  _Account({required this.account, required this.encrypted, this.accountGate})
    : super('fictional lifecycle account', database: _NoDatabase());
  @override
  String? get userID => account;
  @override
  bool get encryptionEnabled => encrypted;
  @override
  bool isLogged() => true;
  @override
  String? get prevBatch => 'fictional-sync';
  @override
  Future<void>? get accountDataLoading {
    accountDataReads++;
    return accountGate?.future ?? Future<void>.value();
  }

  @override
  Future<Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) => profile.future;
  @override
  Future<Map<String, Object?>> setProfileField(
    String userId,
    String keyName,
    Map<String, Object?> body,
  ) async {
    profileWrites++;
    return {};
  }

  @override
  Future<void> logout() async {
    logouts++;
  }
}

/// Supplies an active-client getter without running the application Matrix
/// startup, native storage, keys, transport, or real account registration.
class _ActiveMatrix extends MatrixState {
  Client active;
  _ActiveMatrix(this.active);
  @override
  Client get client => active;
}

class _SettingsHarness extends Settings {
  const _SettingsHarness({super.key});
  @override
  SettingsController createState() => _ControllerHarness();
}

class _ControllerHarness extends SettingsController {
  @override
  Widget build(BuildContext context) {
    super.build(context); // Run the actual cached-profile/account binding.
    return const Scaffold(body: SizedBox.shrink());
  }
}

Future<void> _mount(
  WidgetTester tester,
  _ActiveMatrix matrix,
  GlobalKey<SettingsController> key,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: const [Locale('en')],
      home: Provider<MatrixState>.value(
        value: matrix,
        child: _SettingsHarness(key: key),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'account change resets profile/recovery and ignores old bootstrap completion',
    (tester) async {
      final gate = Completer<void>();
      final first = _Account(
        account: '@first:example.invalid',
        encrypted: true,
        accountGate: gate,
      );
      final second = _Account(
        account: '@second:example.invalid',
        encrypted: false,
      );
      final matrix = _ActiveMatrix(first);
      final key = GlobalKey<SettingsController>();
      await _mount(tester, matrix, key);
      final oldProfile = key.currentState!.profileFuture;
      key.currentState!.cryptoIdentityConnected = true;
      matrix.active = second;
      await _mount(tester, matrix, key);
      expect(identical(key.currentState!.profileFuture, oldProfile), isFalse);
      expect(key.currentState!.cryptoIdentityConnected, isNull);
      expect(first.accountDataReads, 1);
      gate.complete();
      await tester.pump();
      await tester.pump();
      // The old bootstrap must stop before entering the SDK's crypto-state read,
      // which would read accountDataLoading a second time.
      expect(first.accountDataReads, 1);
      expect(key.currentState!.cryptoIdentityConnected, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late profile result cannot open an edit dialog for another account',
    (tester) async {
      final first = _Account(
        account: '@first:example.invalid',
        encrypted: false,
      );
      final second = _Account(
        account: '@second:example.invalid',
        encrypted: false,
      );
      final matrix = _ActiveMatrix(first);
      final key = GlobalKey<SettingsController>();
      await _mount(tester, matrix, key);
      final action = key.currentState!.setDisplaynameAction();
      matrix.active = second;
      await _mount(tester, matrix, key);
      first.profile.complete(
        Profile(userId: first.account, displayName: 'Fictional first account'),
      );
      await action;
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(first.profileWrites, 0);
      expect(second.profileWrites, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('logout confirmation cannot log out the newly active account', (
    tester,
  ) async {
    final first = _Account(account: '@first:example.invalid', encrypted: false);
    final second = _Account(
      account: '@second:example.invalid',
      encrypted: false,
    );
    final matrix = _ActiveMatrix(first);
    final key = GlobalKey<SettingsController>();
    await _mount(tester, matrix, key);
    final label = L10n.of(key.currentState!.context).logout;
    final action = key.currentState!.logoutAction();
    await tester.pumpAndSettle();
    matrix.active = second;
    await _mount(tester, matrix, key);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await action;
    expect(first.logouts, 0);
    expect(second.logouts, 0);
    expect(tester.takeException(), isNull);
  });
}

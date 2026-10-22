// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/settings/settings.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
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
  _Account() : super('fictional logout account', database: _NoDatabase());
  int logouts = 0;
  @override
  String? get userID => '@fixture:example.invalid';
  @override
  bool get encryptionEnabled => true;
  @override
  bool isLogged() => true;
  @override
  String? get prevBatch => 'fictional-sync';
  @override
  Future<Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) async => Profile(userId: userId);
  @override
  Future<void> logout() async => logouts++;
}

class _Matrix extends MatrixState {
  _Matrix(this.active);
  final Client active;
  @override
  Client get client => active;
}

class _Harness extends Settings {
  const _Harness({super.key});
  @override
  SettingsController createState() => _Controller();
}

class _Controller extends SettingsController {
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return const Scaffold(body: SizedBox.shrink());
  }
}

Future<GlobalKey<SettingsController>> _mount(
  WidgetTester tester,
  Client client,
) async {
  final key = GlobalKey<SettingsController>();
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<MatrixState>.value(
        value: _Matrix(client),
        child: _Harness(key: key),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

void main() {
  testWidgets(
    'connected recovery logs out without the backup warning (CS-08)',
    (tester) async {
      final account = _Account();
      final key = await _mount(tester, account);
      key.currentState!
        ..cryptoIdentityConnected = true
        ..recoveryInitialized = true;
      final action = key.currentState!.logoutAction();
      await tester.pumpAndSettle();
      expect(find.text('Log out?'), findsOneWidget);
      expect(find.textContaining('recovery key restores'), findsOneWidget);
      expect(find.textContaining('lose access'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await action;
      expect(account.logouts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('recovery not connected warns and offers setup (CS-08)', (
    tester,
  ) async {
    final account = _Account();
    final key = await _mount(tester, account);
    key.currentState!.cryptoIdentityConnected = false;
    final action = key.currentState!.logoutAction();
    await tester.pumpAndSettle();
    expect(find.text('Log out without a recovery key?'), findsOneWidget);
    expect(find.text('Set up recovery'), findsOneWidget);
    expect(find.text('Log out anyway'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await action;
    expect(account.logouts, 0);
  });

  testWidgets('recovery status reflects connected and initialized (CS-27)', (
    tester,
  ) async {
    final key = await _mount(tester, _Account());
    final controller = key.currentState!;
    controller
      ..cryptoIdentityConnected = false
      ..recoveryInitialized = true;
    expect(controller.recoveryStatus.name, 'notConnected');
    controller.cryptoIdentityConnected = true;
    expect(controller.recoveryStatus.name, 'connected');
  });
}
